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
    public let container: CodexModelContainer
    public var appServer: CodexAppServer {
        container.appServer
    }

    private var workspaceGroupsByID: [CodexWorkspaceGroupID: CodexWorkspaceGroup] = [:]
    private var workspacesByID: [CodexWorkspaceID: CodexWorkspace] = [:]
    private var chatsByID: [CodexThreadID: CodexChat] = [:]

    package init(container: CodexModelContainer) {
        self.container = container
    }

    public func fetch<Model: CodexModel>(
        _ request: CodexFetchRequest<Model>
    ) async throws -> [Model] {
        try await fetchPage(request).items
    }

    public func fetchedResults<Model: CodexModel>(
        for request: CodexFetchRequest<Model>
    ) -> CodexFetchedResults<Model> {
        CodexFetchedResults(modelContext: self, request: request)
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
        _ = try await fetch(request)
        if let latest = workspaceGroupsByID[group.id] {
            group.setWorkspaces(latest.workspaces)
        }
    }

    public func refresh(_ workspace: CodexWorkspace) async throws {
        let request = CodexFetchRequest<CodexChat>.chats(in: workspace)
        let chats = try await fetch(request)
        workspace.setChats(chats)
    }

    public func refresh(_ chat: CodexChat, includeTurns: Bool = true) async throws {
        let thread = try await appServer.resumeThread(chat.id)
        let snapshot = try await thread.read(includeTurns: includeTurns)
        apply(snapshot, shouldReplaceTurns: includeTurns)
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
        let snapshot = CodexThreadSnapshot(
            id: thread.id,
            workspace: thread.workspace
        )
        let chat = apply(snapshot, shouldReplaceTurns: false)
        workspace.addChatIfNeeded(chat)
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
        remove(chat)
    }

    public func delete(_ chat: CodexChat) async throws {
        try await appServer.deleteThread(chat.id)
        remove(chat)
    }

    package func fetchPage<Model: CodexModel>(
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

    package func sections<Model: CodexModel>(
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

    private func fetchChatPage(_ request: CodexFetchRequest<CodexChat>) async throws
        -> CodexFetchPage<CodexChat>
    {
        let page = try await appServer.listThreads(threadQuery(from: request))
        let chats = sort(
            page.threads.map { apply($0, shouldReplaceTurns: $0.turns.isEmpty == false) },
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
        let page = try await appServer.listThreads(threadQuery(from: request))
        let chats = page.threads.map { apply($0, shouldReplaceTurns: $0.turns.isEmpty == false) }
        let workspaces = unique(chats.compactMap(\.workspace))
        for workspace in workspaces {
            workspace.setChats(chats.filter { $0.workspace === workspace })
        }
        return CodexFetchPage(
            items: sort(workspaces, using: request.sortDescriptors),
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    private func fetchWorkspaceGroupPage(
        _ request: CodexFetchRequest<CodexWorkspaceGroup>
    ) async throws -> CodexFetchPage<CodexWorkspaceGroup> {
        let page = try await appServer.listThreads(threadQuery(from: request))
        let chats = page.threads.map { apply($0, shouldReplaceTurns: $0.turns.isEmpty == false) }
        let workspaces = unique(chats.compactMap(\.workspace))
        let groups = unique(workspaces.compactMap(\.workspaceGroup))
        for group in groups {
            group.setWorkspaces(workspaces.filter { $0.workspaceGroup === group })
        }
        return CodexFetchPage(
            items: sort(groups, using: request.sortDescriptors),
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    @discardableResult
    private func apply(_ snapshot: CodexThreadSnapshot, shouldReplaceTurns: Bool) -> CodexChat {
        let workspace = snapshot.workspace.map(workspace(for:))
        let chat = chat(for: snapshot.id)
        chat.apply(snapshot, workspace: workspace, shouldReplaceTurns: shouldReplaceTurns)
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
        chatsByID.removeValue(forKey: chat.id)
        if let workspace = chat.workspace {
            workspace.setChats(workspace.chats.filter { $0 !== chat })
        }
    }

    private func threadQuery<Model: CodexModel>(from request: CodexFetchRequest<Model>)
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
            cursor: request.cursor,
            workspace: request.filter.workspace,
            limit: request.fetchLimit,
            searchTerm: request.filter.searchTerm,
            modelProviders: request.filter.modelProviders,
            sortDirection: serverSort?.order.threadSortDirection,
            sortKey: serverSort?.threadSortKey,
            sourceKinds: request.filter.sourceKinds,
            useStateDBOnly: request.filter.useStateDBOnly
        )
    }

    private func sectionIdentity<Model: CodexModel>(
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
        sortModels(chats, using: descriptors) { descriptor, lhs, rhs in
            switch descriptor.key {
            case .name:
                compare(lhs.title, rhs.title, order: descriptor.order)
            case .createdAt:
                compare(lhs.createdAt, rhs.createdAt, order: descriptor.order)
            case .updatedAt, .recencyAt:
                compare(lhs.updatedAt, rhs.updatedAt, order: descriptor.order)
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
            return order == .forward ? .orderedAscending : .orderedDescending
        case (.none, .some):
            return order == .forward ? .orderedDescending : .orderedAscending
        case (.none, .none):
            return .orderedSame
        }
    }

    private func unique<Model: CodexModel>(_ models: [Model]) -> [Model] {
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
