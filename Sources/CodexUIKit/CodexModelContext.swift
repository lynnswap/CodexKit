import CodexAppServerKit
import Foundation

public enum CodexModelContextError: Error, Equatable, Sendable {
    case unsupportedModelType(String)
    case modelIsDetached
}

@MainActor
public final class CodexModelContainer: @unchecked Sendable {
    public let appServer: CodexAppServer
    public var mainContext: CodexModelContext {
        _mainContext
    }

    private lazy var _mainContext = CodexModelContext(container: self)

    public init(appServer: CodexAppServer) {
        self.appServer = appServer
    }

    public convenience init(
        configuration: CodexAppServer.Configuration = .init()
    ) async throws {
        let appServer = try await CodexAppServer(configuration: configuration)
        self.init(appServer: appServer)
    }
}

@MainActor
public final class CodexModelContext: @unchecked Sendable {
    private static let localCursorPrefix = "codexkit-ui-offset:"

    public private(set) weak var container: CodexModelContainer?
    public let appServer: CodexAppServer

    private var workspaceGroupsByID: [CodexWorkspaceGroupID: CodexWorkspaceGroup] = [:]
    private var workspacesByID: [CodexWorkspaceID: CodexWorkspace] = [:]
    private var chatsByID: [CodexThreadID: CodexChat] = [:]
    private var fetchedResults: [WeakFetchedResultsRegistration] = []

    package init(container: CodexModelContainer) {
        self.container = container
        self.appServer = container.appServer
    }

    public func fetch<Model: CodexObservableModel>(
        _ request: CodexFetchRequest<Model>
    ) async throws -> [Model] {
        let items = try await fetchPage(request).items
        syncLoadedRelationships(items, request: request)
        return items
    }

    public func fetchedResults<Model: CodexObservableModel>(
        for request: CodexFetchRequest<Model>
    ) -> CodexFetchedResults<Model> {
        let results = CodexFetchedResults(modelContext: self, request: request)
        register(results)
        return results
    }

    public func model(for id: CodexThreadID) -> CodexChat {
        chat(for: id)
    }

    public func model(for id: CodexWorkspaceID) -> CodexWorkspace? {
        workspacesByID[id]
    }

    public func model(for id: CodexWorkspaceGroupID) -> CodexWorkspaceGroup? {
        workspaceGroupsByID[id]
    }

    public func refresh(_ group: CodexWorkspaceGroup) async throws {
        let request = CodexFetchRequest<CodexWorkspace>(
            sortDescriptors: [.name()],
            sectionDescriptor: .workspaceGroup
        )
        let workspaces = try await fetch(request)
        group.setWorkspaces(workspaces.filter { $0.workspaceGroup?.id == group.id })
    }

    public func refresh(_ workspace: CodexWorkspace) async throws {
        let request = CodexFetchRequest<CodexChat>.chats(in: workspace)
        let chats = try await fetch(request)
        workspace.setChats(chats)
    }

    public func refresh(_ chat: CodexChat, includeTurns: Bool = true) async throws {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let thread = try await appServer.resumeThread(chat.id)
        let snapshot = try await thread.read(includeTurns: includeTurns)
        let refreshedChat = apply(snapshot)
        revalidateChatInRegisteredResults(
            refreshedChat,
            previousWorkspace: previousWorkspace,
            previousGroup: previousGroup,
            archived: false
        )
    }

    @discardableResult
    public func startChat(
        in workspace: CodexWorkspace,
        input: CodexChatInput = .init()
    ) async throws -> CodexChat {
        let thread = try await appServer.startThread(
            in: workspace.url,
            instructions: input.instructions,
            options: input.options
        )
        let now = Date()
        let snapshot = CodexThreadSnapshot(
            id: thread.id,
            workspace: thread.workspace,
            modelProvider: input.options.modelProvider,
            createdAt: now,
            updatedAt: now
        )
        let chat = apply(snapshot)
        workspace.moveChatToFront(chat)
        insertChatIntoRegisteredResults(chat, archived: false)
        return chat
    }

    @discardableResult
    public func send(
        _ input: CodexChatMessageInput,
        in chat: CodexChat
    ) async throws -> CodexResponse {
        let thread = try await appServer.resumeThread(chat.id)
        return try await thread.respond(to: input.prompt, options: input.options)
    }

    public func cancelActiveTurn(in chat: CodexChat) async throws {
        let thread = try await appServer.resumeThread(chat.id)
        _ = try await thread.cancelActiveTurn()
    }

    public func archive(_ chat: CodexChat) async throws {
        try await appServer.archiveThread(chat.id)
        let workspace = chat.workspace
        let group = workspace?.workspaceGroup
        if let workspace {
            detach(chat, from: workspace)
        }
        archiveChatInRegisteredResults(chat, workspace: workspace, group: group)
    }

    public func delete(_ chat: CodexChat) async throws {
        try await appServer.deleteThread(chat.id)
        remove(chat)
    }

    package func fetchPage<Model: CodexObservableModel>(
        _ request: CodexFetchRequest<Model>
    ) async throws -> CodexFetchPage<Model> {
        if Model.self == CodexChat.self {
            let page = try await fetchChatPage(request as! CodexFetchRequest<CodexChat>)
            return CodexFetchPage(
                items: page.items.map { $0 as! Model },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor
            )
        }
        if Model.self == CodexWorkspace.self {
            let page = try await fetchWorkspacePage(request as! CodexFetchRequest<CodexWorkspace>)
            return CodexFetchPage(
                items: page.items.map { $0 as! Model },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor
            )
        }
        if Model.self == CodexWorkspaceGroup.self {
            let page = try await fetchWorkspaceGroupPage(
                request as! CodexFetchRequest<CodexWorkspaceGroup>)
            return CodexFetchPage(
                items: page.items.map { $0 as! Model },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor
            )
        }
        throw CodexModelContextError.unsupportedModelType(String(describing: Model.self))
    }

    package func sections<Model: CodexObservableModel>(
        for items: [Model],
        descriptor: CodexSectionDescriptor<Model>?
    ) -> [CodexFetchSection<Model>] {
        guard items.isEmpty == false else {
            return []
        }
        guard let descriptor else {
            return [CodexFetchSection(id: "default", title: nil, items: items)]
        }

        var grouped: [(id: String, title: String, items: [Model])] = []
        for item in items {
            let section = sectionIdentity(for: item, descriptor: descriptor)
            if let index = grouped.firstIndex(where: { $0.id == section.id }) {
                grouped[index].items.append(item)
            } else {
                grouped.append((id: section.id, title: section.title, items: [item]))
            }
        }
        return grouped.map {
            CodexFetchSection(id: $0.id, title: $0.title, items: $0.items)
        }
    }

    package func sortedItems<Model: CodexObservableModel>(
        _ items: [Model],
        for request: CodexFetchRequest<Model>
    ) -> [Model] {
        if Model.self == CodexChat.self {
            let request = request as! CodexFetchRequest<CodexChat>
            return sort(items as! [CodexChat], using: request.sortDescriptors).map { $0 as! Model }
        }
        if Model.self == CodexWorkspace.self {
            let request = request as! CodexFetchRequest<CodexWorkspace>
            return sort(items as! [CodexWorkspace], using: request.sortDescriptors).map {
                $0 as! Model
            }
        }
        if Model.self == CodexWorkspaceGroup.self {
            let request = request as! CodexFetchRequest<CodexWorkspaceGroup>
            return sort(items as! [CodexWorkspaceGroup], using: request.sortDescriptors).map {
                $0 as! Model
            }
        }
        return items
    }

    private func fetchChatPage(_ request: CodexFetchRequest<CodexChat>) async throws
        -> CodexFetchPage<CodexChat>
    {
        if canUseServerOrderedPages(for: request) == false {
            let chats = sort(
                try await fetchAllThreadSnapshots(matching: request)
                    .map(apply),
                using: request.sortDescriptors
            )
            return localPage(chats, for: request)
        }

        let page = try await appServer.listThreads(threadQuery(from: request))
        let chats = sort(
            page.threads.map(apply),
            using: request.sortDescriptors
        )
        return CodexFetchPage(
            items: chats,
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    private func fetchWorkspacePage(
        _ request: CodexFetchRequest<CodexWorkspace>
    ) async throws -> CodexFetchPage<CodexWorkspace> {
        let chats = try await fetchAllThreadSnapshots(matching: request)
            .map(apply)
        let workspaces = unique(chats.compactMap(\.workspace))
        syncWorkspaceChats(
            chats,
            preservingExisting: shouldPreserveExistingWorkspaceChats(for: request),
            workspaceFilter: request.filter.workspace
        )
        return localPage(sort(workspaces, using: request.sortDescriptors), for: request)
    }

    private func fetchWorkspaceGroupPage(
        _ request: CodexFetchRequest<CodexWorkspaceGroup>
    ) async throws -> CodexFetchPage<CodexWorkspaceGroup> {
        let chats = try await fetchAllThreadSnapshots(matching: request)
            .map(apply)
        let workspaces = unique(chats.compactMap(\.workspace))
        let groups = unique(workspaces.compactMap(\.workspaceGroup))
        syncWorkspaceChats(
            chats,
            preservingExisting: shouldPreserveExistingWorkspaceChats(for: request),
            workspaceFilter: request.filter.workspace
        )
        syncGroupWorkspaces(
            workspaces,
            preservingExisting: shouldPreserveExistingWorkspaceChats(for: request)
        )
        return localPage(sort(groups, using: request.sortDescriptors), for: request)
    }

    @discardableResult
    private func apply(_ snapshot: CodexThreadSnapshot) -> CodexChat {
        let workspace = snapshot.workspace.map(workspace(for:))
        let chat = chat(for: snapshot.id)
        if let previousWorkspace = chat.workspace {
            let movedToDifferentWorkspace = workspace.map { $0 !== previousWorkspace } ?? true
            if movedToDifferentWorkspace {
                detach(chat, from: previousWorkspace)
            }
        }
        chat.apply(snapshot, workspace: workspace)
        workspace?.addChatIfNeeded(chat)
        return chat
    }

    private func chat(for id: CodexThreadID) -> CodexChat {
        if let chat = chatsByID[id] {
            return chat
        }
        let chat = CodexChat(id: id, modelContext: self)
        chatsByID[id] = chat
        return chat
    }

    private func workspace(for url: URL) -> CodexWorkspace {
        let standardizedURL = Self.standardizedDirectoryURL(url)
        let id = CodexWorkspaceID(rawValue: standardizedURL.path)
        let groupIdentity = CodexWorkspaceGroupIdentity.identity(for: standardizedURL)
        let group = workspaceGroup(for: groupIdentity)
        let name = Self.displayName(for: standardizedURL)
        let workspace: CodexWorkspace
        if let existing = workspacesByID[id] {
            workspace = existing
            workspace.update(url: standardizedURL, name: name, workspaceGroup: group)
        } else {
            workspace = CodexWorkspace(
                id: id,
                url: standardizedURL,
                name: name,
                workspaceGroup: group,
                modelContext: self
            )
            workspacesByID[id] = workspace
        }
        if group.workspaces.contains(where: { $0 === workspace }) == false {
            group.setWorkspaces(sort(group.workspaces + [workspace], using: [.name()]))
        }
        return workspace
    }

    private func workspaceGroup(for identity: CodexWorkspaceGroupIdentity) -> CodexWorkspaceGroup {
        if let group = workspaceGroupsByID[identity.id] {
            group.update(name: identity.title)
            return group
        }
        let group = CodexWorkspaceGroup(
            id: identity.id,
            name: identity.title,
            modelContext: self
        )
        workspaceGroupsByID[identity.id] = group
        return group
    }

    private func remove(_ chat: CodexChat) {
        let workspace = chat.workspace
        let group = workspace?.workspaceGroup
        chatsByID.removeValue(forKey: chat.id)
        if let workspace {
            detach(chat, from: workspace)
        }
        chat.detachFromContext()
        removeChatFromRegisteredResults(chat, workspace: workspace, group: group)
    }

    package func syncLoadedRelationships<Model: CodexObservableModel>(
        _ items: [Model],
        request: CodexFetchRequest<Model>
    ) {
        if let chats = items as? [CodexChat] {
            syncWorkspaceChats(
                chats,
                preservingExisting: shouldPreserveExistingWorkspaceChats(for: request),
                workspaceFilter: request.filter.workspace
            )
        }
    }

    private func syncWorkspaceChats(
        _ chats: [CodexChat],
        preservingExisting: Bool,
        workspaceFilter: URL?
    ) {
        let fetchedWorkspaces = unique(chats.compactMap(\.workspace))
        let workspaces: [CodexWorkspace]
        if preservingExisting {
            workspaces = fetchedWorkspaces
        } else if let workspaceFilter {
            let filteredWorkspace = workspaceIfLoaded(for: workspaceFilter)
            workspaces = unique((filteredWorkspace.map { [$0] } ?? []) + fetchedWorkspaces)
        } else {
            workspaces = Array(workspacesByID.values)
        }
        for workspace in workspaces {
            let fetchedChats = chats.filter { $0.workspace === workspace }
            if preservingExisting {
                let fetchedIDs = Set(fetchedChats.map(\.id))
                let remainingChats = workspace.chats.filter { fetchedIDs.contains($0.id) == false }
                workspace.setChats(fetchedChats + remainingChats)
            } else {
                workspace.setChats(fetchedChats)
                pruneWorkspaceIfEmpty(workspace)
            }
        }
    }

    private func syncGroupWorkspaces(
        _ workspaces: [CodexWorkspace],
        preservingExisting: Bool
    ) {
        let fetchedGroups = unique(workspaces.compactMap(\.workspaceGroup))
        let groups = preservingExisting ? fetchedGroups : Array(workspaceGroupsByID.values)
        for group in groups {
            let fetchedWorkspaces = workspaces.filter { $0.workspaceGroup === group }
            if preservingExisting {
                let fetchedIDs = Set(fetchedWorkspaces.map(\.id))
                let remainingWorkspaces = group.workspaces.filter {
                    fetchedIDs.contains($0.id) == false
                }
                group.setWorkspaces(sort(fetchedWorkspaces + remainingWorkspaces, using: [.name()]))
            } else {
                group.setWorkspaces(sort(fetchedWorkspaces, using: [.name()]))
            }
        }
    }

    private func detach(_ chat: CodexChat, from workspace: CodexWorkspace) {
        workspace.setChats(workspace.chats.filter { $0 !== chat })
        pruneWorkspaceIfEmpty(workspace)
    }

    private func pruneWorkspaceIfEmpty(_ workspace: CodexWorkspace) {
        guard workspace.chats.isEmpty, let group = workspace.workspaceGroup else {
            return
        }
        group.setWorkspaces(group.workspaces.filter { $0 !== workspace })
    }

    private func shouldPreserveExistingWorkspaceChats<Model: CodexObservableModel>(
        for request: CodexFetchRequest<Model>
    ) -> Bool {
        request.cursor != nil
            || request.fetchLimit != nil
            || request.filter.archived == true
            || request.filter.searchTerm != nil
            || request.filter.modelProviders != nil
            || request.filter.sourceKinds != nil
            || request.filter.useStateDBOnly != nil
    }

    private func workspaceIfLoaded(for url: URL) -> CodexWorkspace? {
        let id = CodexWorkspaceID(rawValue: Self.standardizedDirectoryURL(url).path)
        return workspacesByID[id]
    }

    private func register(_ results: any CodexFetchedResultsRegistration) {
        fetchedResults.removeAll { $0.value == nil }
        fetchedResults.append(WeakFetchedResultsRegistration(results))
    }

    private func insertChatIntoRegisteredResults(_ chat: CodexChat, archived: Bool) {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            registration.value?.insert(chat, archived: archived)
        }
    }

    private func archiveChatInRegisteredResults(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            registration.value?.archive(chat, workspace: workspace, group: group)
        }
    }

    private func revalidateChatInRegisteredResults(
        _ chat: CodexChat,
        previousWorkspace: CodexWorkspace?,
        previousGroup: CodexWorkspaceGroup?,
        archived: Bool
    ) {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            registration.value?.revalidate(
                chat,
                previousWorkspace: previousWorkspace,
                previousGroup: previousGroup,
                archived: archived
            )
        }
    }

    private func removeChatFromRegisteredResults(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            registration.value?.remove(chat, workspace: workspace, group: group)
        }
    }

    private func fetchAllThreadSnapshots<Model: CodexObservableModel>(
        matching request: CodexFetchRequest<Model>
    ) async throws -> [CodexThreadSnapshot] {
        var query = threadQuery(from: request, includePaging: false)
        var threads: [CodexThreadSnapshot] = []
        var cursor: String?

        repeat {
            query.cursor = cursor
            let page = try await appServer.listThreads(query)
            threads.append(contentsOf: page.threads)
            cursor = page.nextCursor
        } while cursor != nil

        return threads
    }

    private func localPage<Model: CodexObservableModel>(
        _ items: [Model],
        for request: CodexFetchRequest<Model>
    ) -> CodexFetchPage<Model> {
        let start = min(localCursorOffset(from: request.cursor), items.count)
        guard let limit = request.fetchLimit else {
            return CodexFetchPage(
                items: Array(items[start..<items.endIndex]),
                nextCursor: nil,
                backwardsCursor: start > 0 ? localCursor(for: 0) : nil
            )
        }
        guard limit > 0 else {
            return CodexFetchPage(items: [], nextCursor: nil, backwardsCursor: nil)
        }

        let end = min(start + limit, items.count)
        let previousStart = max(0, start - limit)
        return CodexFetchPage(
            items: Array(items[start..<end]),
            nextCursor: end < items.count ? localCursor(for: end) : nil,
            backwardsCursor: start > 0 ? localCursor(for: previousStart) : nil
        )
    }

    private func canUseServerOrderedPages<Model: CodexObservableModel>(
        for request: CodexFetchRequest<Model>
    ) -> Bool {
        guard let primarySort = request.sortDescriptors.first else {
            return true
        }
        if primarySort.key == .recencyAt {
            return true
        }
        return request.sortDescriptors.count == 1 && primarySort.threadSortKey != nil
    }

    private func localCursor(for offset: Int) -> String {
        "\(Self.localCursorPrefix)\(offset)"
    }

    private func localCursorOffset(from cursor: String?) -> Int {
        guard let cursor,
              cursor.hasPrefix(Self.localCursorPrefix)
        else {
            return 0
        }

        let rawOffset = cursor.dropFirst(Self.localCursorPrefix.count)
        guard let offset = Int(rawOffset), offset > 0 else {
            return 0
        }
        return offset
    }

    private func threadQuery<Model: CodexObservableModel>(
        from request: CodexFetchRequest<Model>,
        includePaging: Bool = true
    )
        -> CodexThreadQuery
    {
        let serverSort = request.sortDescriptors.first { descriptor in
            switch descriptor.key {
            case .createdAt, .updatedAt, .recencyAt:
                return true
            case .name:
                return false
            }
        }
        return CodexThreadQuery(
            archived: request.filter.archived,
            cursor: includePaging ? request.cursor : nil,
            workspace: request.filter.workspace,
            limit: includePaging ? request.fetchLimit : nil,
            searchTerm: request.filter.searchTerm,
            modelProviders: request.filter.modelProviders,
            sortDirection: serverSort?.order.threadSortDirection,
            sortKey: serverSort?.threadSortKey,
            sourceKinds: request.filter.sourceKinds,
            useStateDBOnly: request.filter.useStateDBOnly
        )
    }

    private func sectionIdentity<Model: CodexObservableModel>(
        for item: Model,
        descriptor: CodexSectionDescriptor<Model>
    ) -> (id: String, title: String) {
        switch descriptor.key {
        case .workspace:
            if let chat = item as? CodexChat, let workspace = chat.workspace {
                return (workspace.id.rawValue, workspace.name)
            }
        case .workspaceGroup:
            if let workspace = item as? CodexWorkspace, let group = workspace.workspaceGroup {
                return (group.id.rawValue, group.name)
            }
            if let chat = item as? CodexChat, let group = chat.workspace?.workspaceGroup {
                return (group.id.rawValue, group.name)
            }
        }
        return ("unknown", "Unknown")
    }

    private func sort(_ chats: [CodexChat], using descriptors: [CodexSortDescriptor<CodexChat>])
        -> [CodexChat]
    {
        guard descriptors.first?.key != .recencyAt else {
            return chats
        }
        let localDescriptors = descriptors.filter { $0.key != .recencyAt }
        guard localDescriptors.isEmpty == false else {
            return chats
        }
        return sortModels(chats, using: localDescriptors) { descriptor, lhs, rhs in
            switch descriptor.key {
            case .name:
                compare(lhs.title, rhs.title, order: descriptor.order)
            case .createdAt:
                compare(lhs.createdAt, rhs.createdAt, order: descriptor.order)
            case .updatedAt:
                compare(lhs.updatedAt, rhs.updatedAt, order: descriptor.order)
            case .recencyAt:
                .orderedSame
            }
        }
    }

    private func sort(
        _ workspaces: [CodexWorkspace],
        using descriptors: [CodexSortDescriptor<CodexWorkspace>]
    ) -> [CodexWorkspace] {
        sortModels(workspaces, using: descriptors) { descriptor, lhs, rhs in
            switch descriptor.key {
            case .name, .createdAt, .updatedAt, .recencyAt:
                compare(lhs.name, rhs.name, order: descriptor.order)
            }
        }
    }

    private func sort(
        _ groups: [CodexWorkspaceGroup],
        using descriptors: [CodexSortDescriptor<CodexWorkspaceGroup>]
    ) -> [CodexWorkspaceGroup] {
        sortModels(groups, using: descriptors) { descriptor, lhs, rhs in
            switch descriptor.key {
            case .name, .createdAt, .updatedAt, .recencyAt:
                compare(lhs.name, rhs.name, order: descriptor.order)
            }
        }
    }

    private func sortModels<Model, Descriptor>(
        _ models: [Model],
        using descriptors: [Descriptor],
        compare: (Descriptor, Model, Model) -> ComparisonResult
    ) -> [Model] {
        guard descriptors.isEmpty == false else {
            return models
        }
        return models.sorted { lhs, rhs in
            for descriptor in descriptors {
                switch compare(descriptor, lhs, rhs) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    continue
                }
            }
            return false
        }
    }

    private func compare(_ lhs: String, _ rhs: String, order: CodexSortOrder) -> ComparisonResult {
        let result = lhs.localizedStandardCompare(rhs)
        return order == .forward ? result : result.reversed
    }

    private func compare(_ lhs: Date?, _ rhs: Date?, order: CodexSortOrder) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            if lhs == rhs {
                return .orderedSame
            }
            let result: ComparisonResult = lhs < rhs ? .orderedAscending : .orderedDescending
            return order == .forward ? result : result.reversed
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        case (.none, .none):
            return .orderedSame
        }
    }

    private func unique<Model: CodexObservableModel>(_ models: [Model]) -> [Model] {
        var seen: Set<Model.ID> = []
        var result: [Model] = []
        for model in models where seen.insert(model.id).inserted {
            result.append(model)
        }
        return result
    }

    private static func standardizedDirectoryURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

extension CodexSortDescriptor {
    fileprivate var threadSortKey: CodexThreadSortKey? {
        switch key {
        case .createdAt:
            return .createdAt
        case .updatedAt:
            return .updatedAt
        case .recencyAt:
            return .recencyAt
        case .name:
            return nil
        }
    }
}

extension ComparisonResult {
    fileprivate var reversed: ComparisonResult {
        switch self {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }
}

@MainActor
private final class WeakFetchedResultsRegistration {
    weak var value: (any CodexFetchedResultsRegistration)?

    init(_ value: any CodexFetchedResultsRegistration) {
        self.value = value
    }
}

private struct CodexWorkspaceGroupIdentity: Sendable {
    var id: CodexWorkspaceGroupID
    var title: String

    static func identity(
        for workspaceURL: URL,
        fileManager: FileManager = .default
    ) -> CodexWorkspaceGroupIdentity {
        guard
            let gitMetadataURL = enclosingGitMetadataURL(
                startingAt: workspaceURL, fileManager: fileManager)
        else {
            return .cwd(workspaceURL)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitMetadataURL.path, isDirectory: &isDirectory) else {
            return .cwd(workspaceURL)
        }

        let gitRootURL = gitMetadataURL.deletingLastPathComponent()
        let commonDirURL: URL?
        if isDirectory.boolValue {
            commonDirURL = gitMetadataURL
        } else if let gitDirURL = linkedGitDirURL(from: gitMetadataURL) {
            commonDirURL = linkedCommonDirURL(for: gitDirURL) ?? gitDirURL
        } else {
            commonDirURL = nil
        }

        guard let commonDirURL else {
            return .cwd(workspaceURL)
        }

        let standardizedCommonDirURL = commonDirURL.standardizedFileURL.resolvingSymlinksInPath()
        return CodexWorkspaceGroupIdentity(
            id: .init(rawValue: "git-common:\(standardizedCommonDirURL.path)"),
            title: sectionTitle(
                commonDirURL: standardizedCommonDirURL,
                gitRootURL: gitRootURL,
                fallbackURL: workspaceURL
            )
        )
    }

    private static func cwd(_ url: URL) -> CodexWorkspaceGroupIdentity {
        CodexWorkspaceGroupIdentity(
            id: .init(rawValue: "cwd:\(url.path)"),
            title: displayName(for: url)
        )
    }

    private static func enclosingGitMetadataURL(startingAt url: URL, fileManager: FileManager)
        -> URL?
    {
        var directoryURL = url
        while true {
            let gitURL = directoryURL.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitURL.path) {
                return gitURL
            }

            let parentURL = directoryURL.deletingLastPathComponent()
            guard parentURL.path != directoryURL.path else {
                return nil
            }
            directoryURL = parentURL
        }
    }

    private static func linkedGitDirURL(from gitFileURL: URL) -> URL? {
        guard let contents = try? String(contentsOf: gitFileURL, encoding: .utf8),
            let firstLine = contents.split(whereSeparator: \.isNewline).first
        else {
            return nil
        }

        let prefix = "gitdir:"
        let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.lowercased().hasPrefix(prefix) else {
            return nil
        }

        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            return nil
        }
        return resolvedURL(path: path, relativeTo: gitFileURL.deletingLastPathComponent())
    }

    private static func linkedCommonDirURL(for gitDirURL: URL) -> URL? {
        let commonDirFileURL = gitDirURL.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commonDirFileURL, encoding: .utf8),
            let firstLine = contents.split(whereSeparator: \.isNewline).first
        else {
            return nil
        }

        let path = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            return nil
        }
        return resolvedURL(path: path, relativeTo: gitDirURL)
    }

    private static func resolvedURL(path: String, relativeTo baseURL: URL) -> URL {
        let url =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : baseURL.appendingPathComponent(path, isDirectory: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func sectionTitle(
        commonDirURL: URL,
        gitRootURL: URL,
        fallbackURL: URL
    ) -> String {
        if commonDirURL.lastPathComponent == ".git" {
            let title = commonDirURL.deletingLastPathComponent().lastPathComponent
            if title.isEmpty == false {
                return title
            }
        }

        let commonDirName = commonDirURL.lastPathComponent
        if commonDirName.hasSuffix(".git"), commonDirName.count > ".git".count {
            return String(commonDirName.dropLast(".git".count))
        }

        let rootTitle = gitRootURL.lastPathComponent
        return rootTitle.isEmpty ? displayName(for: fallbackURL) : rootTitle
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}
