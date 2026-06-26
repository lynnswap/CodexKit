import CodexAppServerKit
import Foundation
import Observation

public enum CodexSortOrder: Sendable, Hashable, Codable {
    case forward
    case reverse

    package var threadSortDirection: CodexSortDirection {
        switch self {
        case .forward:
            .ascending
        case .reverse:
            .descending
        }
    }
}

package enum CodexSortKey: Sendable, Hashable {
    case name
    case createdAt
    case updatedAt
    case recencyAt
}

public struct CodexSortDescriptor<Model: CodexObservableModel>: Sendable, Hashable {
    package var key: CodexSortKey
    public var order: CodexSortOrder

    package init(key: CodexSortKey, order: CodexSortOrder) {
        self.key = key
        self.order = order
    }
}

extension CodexSortDescriptor where Model == CodexWorkspaceGroup {
    public static func name(_ order: CodexSortOrder = .forward) -> Self {
        .init(key: .name, order: order)
    }
}

extension CodexSortDescriptor where Model == CodexWorkspace {
    public static func name(_ order: CodexSortOrder = .forward) -> Self {
        .init(key: .name, order: order)
    }
}

extension CodexSortDescriptor where Model == CodexChat {
    public static func name(_ order: CodexSortOrder = .forward) -> Self {
        .init(key: .name, order: order)
    }

    public static func createdAt(_ order: CodexSortOrder = .reverse) -> Self {
        .init(key: .createdAt, order: order)
    }

    public static func updatedAt(_ order: CodexSortOrder = .reverse) -> Self {
        .init(key: .updatedAt, order: order)
    }

    public static func recencyAt(_ order: CodexSortOrder = .reverse) -> Self {
        .init(key: .recencyAt, order: order)
    }
}

package enum CodexSectionKey: Sendable, Hashable {
    case workspaceGroup
    case workspace
}

public struct CodexSectionDescriptor<Model: CodexObservableModel>: Sendable, Hashable {
    package var key: CodexSectionKey

    package init(key: CodexSectionKey) {
        self.key = key
    }
}

extension CodexSectionDescriptor where Model == CodexWorkspace {
    public static var workspaceGroup: Self {
        .init(key: .workspaceGroup)
    }
}

extension CodexSectionDescriptor where Model == CodexChat {
    public static var workspaceGroup: Self {
        .init(key: .workspaceGroup)
    }

    public static var workspace: Self {
        .init(key: .workspace)
    }
}

public struct CodexFetchFilter<Model: CodexObservableModel>: Sendable, Hashable {
    public var archived: Bool?
    public var workspace: URL?
    public var searchTerm: String?
    public var modelProviders: [String]?
    public var sourceKinds: [CodexThreadSourceKind]?
    public var useStateDBOnly: Bool?

    public init(
        archived: Bool? = nil,
        workspace: URL? = nil,
        searchTerm: String? = nil,
        modelProviders: [String]? = nil,
        sourceKinds: [CodexThreadSourceKind]? = nil,
        useStateDBOnly: Bool? = nil
    ) {
        self.archived = archived
        self.workspace = workspace
        self.searchTerm = searchTerm
        self.modelProviders = modelProviders
        self.sourceKinds = sourceKinds
        self.useStateDBOnly = useStateDBOnly
    }
}

public struct CodexFetchRequest<Model: CodexObservableModel>: Sendable, Hashable {
    public var filter: CodexFetchFilter<Model>
    public var sortDescriptors: [CodexSortDescriptor<Model>]
    public var sectionDescriptor: CodexSectionDescriptor<Model>?
    public var fetchLimit: Int?
    public var cursor: String?

    public init(
        filter: CodexFetchFilter<Model> = .init(),
        sortDescriptors: [CodexSortDescriptor<Model>] = [],
        sectionDescriptor: CodexSectionDescriptor<Model>? = nil,
        fetchLimit: Int? = nil,
        cursor: String? = nil
    ) {
        self.filter = filter
        self.sortDescriptors = sortDescriptors
        self.sectionDescriptor = sectionDescriptor
        self.fetchLimit = fetchLimit
        self.cursor = cursor
    }
}

extension CodexFetchRequest where Model == CodexWorkspaceGroup {
    public static var workspaceGroups: Self {
        .init(sortDescriptors: [.name()])
    }
}

extension CodexFetchRequest where Model == CodexWorkspace {
    public static var workspaces: Self {
        .init(sortDescriptors: [.name()])
    }

    public static func workspaces(
        sectionedBy sectionDescriptor: CodexSectionDescriptor<CodexWorkspace>? = nil,
        sortDescriptors: [CodexSortDescriptor<CodexWorkspace>] = [.name()]
    ) -> Self {
        .init(sortDescriptors: sortDescriptors, sectionDescriptor: sectionDescriptor)
    }
}

extension CodexFetchRequest where Model == CodexChat {
    public static var recentChats: Self {
        .init(sortDescriptors: [.updatedAt(.reverse)])
    }

    @MainActor
    public static func chats(
        in workspace: CodexWorkspace,
        sortDescriptors: [CodexSortDescriptor<CodexChat>] = [.updatedAt(.reverse)],
        sectionDescriptor: CodexSectionDescriptor<CodexChat>? = nil,
        fetchLimit: Int? = nil
    ) -> Self {
        .init(
            filter: .init(workspace: workspace.url),
            sortDescriptors: sortDescriptors,
            sectionDescriptor: sectionDescriptor,
            fetchLimit: fetchLimit
        )
    }
}

public struct CodexFetchSection<Model: CodexObservableModel>: Identifiable {
    public var id: String
    public var title: String?
    public var items: [Model]

    public init(id: String, title: String?, items: [Model]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

package struct CodexFetchPage<Model: CodexObservableModel> {
    package var items: [Model]
    package var nextCursor: String?
    package var backwardsCursor: String?
}

@MainActor
package protocol CodexFetchedResultsRegistration: AnyObject {
    func insert(_ chat: CodexChat, archived: Bool)
    func archive(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    )
    func revalidate(
        _ chat: CodexChat,
        previousWorkspace: CodexWorkspace?,
        previousGroup: CodexWorkspaceGroup?,
        archived: Bool
    )
    func remove(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    )
    func refresh(_ workspace: CodexWorkspace, archived: Bool)
    func refresh(_ group: CodexWorkspaceGroup, archived: Bool)
}

@MainActor
@Observable
public final class CodexFetchedResults<Model: CodexObservableModel> {
    public let modelContext: CodexModelContext
    public private(set) var request: CodexFetchRequest<Model>
    public private(set) var items: [Model] = []
    public private(set) var sections: [CodexFetchSection<Model>] = []
    public private(set) var nextCursor: String?
    public private(set) var backwardsCursor: String?
    public var phase: CodexUIPhase = .idle
    public var lastErrorDescription: String?

    package init(
        modelContext: CodexModelContext,
        request: CodexFetchRequest<Model>
    ) {
        self.modelContext = modelContext
        self.request = request
    }

    public func performFetch() async throws {
        try await load(request, appending: false)
    }

    public func refresh() async throws {
        try await performFetch()
    }

    public func loadNextPage() async throws {
        guard let nextCursor else {
            return
        }
        var request = request
        request.cursor = nextCursor
        try await load(request, appending: true)
    }

    private func load(_ request: CodexFetchRequest<Model>, appending: Bool) async throws {
        phase = .loading
        lastErrorDescription = nil
        do {
            let page = try await modelContext.fetchPage(request)
            let newItems = appending ? append(page.items, to: items) : page.items
            items = newItems
            let relationshipRequest = appending ? self.request : request
            modelContext.syncLoadedRelationships(
                newItems,
                request: relationshipRequest,
                relationshipIsComplete: page.nextCursor == nil
                    && (appending || request.cursor == nil)
            )
            sections = modelContext.sections(for: newItems, descriptor: request.sectionDescriptor)
            nextCursor = page.nextCursor
            backwardsCursor = page.backwardsCursor
            phase = .loaded
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    private func append(_ incoming: [Model], to existing: [Model]) -> [Model] {
        var result = existing
        for item in incoming {
            if let index = result.firstIndex(where: { $0.id == item.id }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }
}

extension CodexFetchedResults: CodexFetchedResultsRegistration {
    package func insert(_ chat: CodexChat, archived: Bool) {
        guard let model = insertionModel(for: chat, archived: archived) else {
            return
        }
        upsert(model)
    }

    package func archive(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) {
        if let model = insertionModel(for: chat, archived: true) {
            upsert(model)
        } else {
            remove(chat, workspace: workspace, group: group)
        }
    }

    package func revalidate(
        _ chat: CodexChat,
        previousWorkspace: CodexWorkspace?,
        previousGroup: CodexWorkspaceGroup?,
        archived: Bool
    ) {
        guard canEvaluateFilterLocally else {
            sections = modelContext.sections(for: items, descriptor: request.sectionDescriptor)
            return
        }
        let filteredItems = items.filter {
            shouldKeep(
                $0,
                afterRevalidating: chat,
                previousWorkspace: previousWorkspace,
                previousGroup: previousGroup,
                archived: archived
            )
        }
        items = filteredItems
        sections = modelContext.sections(for: filteredItems, descriptor: request.sectionDescriptor)
        guard let model = insertionModel(for: chat, archived: archived) else {
            return
        }
        upsert(model)
    }

    package func remove(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) {
        let filteredItems = items.filter {
            shouldKeep($0, afterRemoving: chat, workspace: workspace, group: group)
        }
        guard filteredItems.count != items.count else {
            return
        }
        items = filteredItems
        sections = modelContext.sections(for: filteredItems, descriptor: request.sectionDescriptor)
    }

    package func refresh(_ workspace: CodexWorkspace, archived: Bool) {
        refreshItems(archived: archived) {
            shouldKeep($0, afterRefreshing: workspace)
        }
    }

    package func refresh(_ group: CodexWorkspaceGroup, archived: Bool) {
        refreshItems(archived: archived) {
            shouldKeep($0, afterRefreshing: group)
        }
    }

    private func insertionModel(for chat: CodexChat, archived: Bool) -> Model? {
        guard canEvaluateFilterLocally else {
            return nil
        }
        guard shouldInclude(chat, archived: archived) else {
            return nil
        }
        if archived {
            restoreArchivedRelationships(for: chat)
        }
        if let chat = chat as? Model {
            return chat
        }
        if let workspace = chat.workspace as? Model {
            return workspace
        }
        if let workspace = chat.workspace,
            let workspaceGroup = workspace.workspaceGroup,
            let group = workspaceGroup as? Model
        {
            if workspaceGroup.workspaces.contains(where: { $0 === workspace }) == false {
                workspaceGroup.setWorkspaces(workspaceGroup.workspaces + [workspace])
            }
            return group
        }
        return nil
    }

    private func upsert(_ model: Model) {
        var nextItems = items
        if let index = nextItems.firstIndex(where: { $0.id == model.id }) {
            nextItems[index] = model
        } else {
            guard canInsertLiveModel else {
                return
            }
            nextItems.insert(model, at: 0)
        }
        items = modelContext.sortedItems(nextItems, for: request)
        sections = modelContext.sections(for: items, descriptor: request.sectionDescriptor)
    }

    private var canInsertLiveModel: Bool {
        canEvaluateFilterLocally
            && request.cursor == nil
            && request.fetchLimit == nil
            && nextCursor == nil
            && backwardsCursor == nil
    }

    private var canEvaluateFilterLocally: Bool {
        request.filter.sourceKinds == nil && request.filter.useStateDBOnly == nil
    }

    private func shouldInclude(_ chat: CodexChat, archived: Bool) -> Bool {
        switch request.filter.archived {
        case .some(let expectedArchived):
            guard expectedArchived == archived else {
                return false
            }
        case .none:
            guard archived == false else {
                return false
            }
        }

        if let workspace = request.filter.workspace {
            guard let chatWorkspace = chat.workspace,
                Self.standardizedPath(chatWorkspace.url) == Self.standardizedPath(workspace)
            else {
                return false
            }
        }

        if let searchTerm = request.filter.searchTerm, searchTerm.isEmpty == false {
            let searchableText = [
                chat.name,
                chat.preview,
                chat.workspace?.name,
                chat.title,
            ]
            guard
                searchableText.contains(where: { text in
                    text?.localizedCaseInsensitiveContains(searchTerm) == true
                })
            else {
                return false
            }
        }

        if let modelProviders = request.filter.modelProviders {
            guard let modelProvider = chat.modelProvider,
                modelProviders.contains(modelProvider)
            else {
                return false
            }
        }

        return true
    }

    private func shouldKeep(
        _ item: Model,
        afterRemoving chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) -> Bool {
        if let item = item as? CodexChat {
            return item.id != chat.id
        }
        if let item = item as? CodexWorkspace, let workspace {
            guard canEvaluateFilterLocally else {
                return true
            }
            return item.id != workspace.id || containsIncludedChat(in: item)
        }
        if let item = item as? CodexWorkspaceGroup, let group {
            guard canEvaluateFilterLocally else {
                return true
            }
            return item.id != group.id || containsIncludedWorkspace(in: item)
        }
        return true
    }

    private func shouldKeep(
        _ item: Model,
        afterRevalidating chat: CodexChat,
        previousWorkspace: CodexWorkspace?,
        previousGroup: CodexWorkspaceGroup?,
        archived: Bool
    ) -> Bool {
        if let item = item as? CodexChat, item.id == chat.id {
            return shouldInclude(chat, archived: archived)
        }
        if let item = item as? CodexWorkspace,
            item.id == previousWorkspace?.id || item.id == chat.workspace?.id
        {
            return containsIncludedChat(in: item)
        }
        if let item = item as? CodexWorkspaceGroup,
            item.id == previousGroup?.id || item.id == chat.workspace?.workspaceGroup?.id
        {
            return containsIncludedWorkspace(in: item)
        }
        return true
    }

    private func shouldKeep(
        _ item: Model,
        afterRefreshing workspace: CodexWorkspace
    ) -> Bool {
        if let item = item as? CodexChat,
            requestIsScoped(to: workspace)
        {
            return workspace.chats.contains { $0 === item }
                && shouldInclude(
                    item,
                    archived: item.isArchived
                )
        }
        if let item = item as? CodexWorkspace,
            item.id == workspace.id
        {
            guard canEvaluateFilterLocally else {
                return true
            }
            return containsIncludedChat(in: item)
        }
        if let item = item as? CodexWorkspaceGroup,
            let group = workspace.workspaceGroup,
            item.id == group.id
        {
            guard canEvaluateFilterLocally else {
                return true
            }
            return containsIncludedWorkspace(in: item)
        }
        return true
    }

    private func shouldKeep(
        _ item: Model,
        afterRefreshing group: CodexWorkspaceGroup
    ) -> Bool {
        if let item = item as? CodexWorkspace,
            item.workspaceGroup?.id == group.id
        {
            guard canEvaluateFilterLocally else {
                return true
            }
            return group.workspaces.contains { $0 === item } && containsIncludedChat(in: item)
        }
        if let item = item as? CodexWorkspaceGroup,
            item.id == group.id
        {
            guard canEvaluateFilterLocally else {
                return true
            }
            return containsIncludedWorkspace(in: item)
        }
        return true
    }

    private func refreshItems(
        archived: Bool,
        keeping shouldKeep: (Model) -> Bool
    ) {
        guard requestMatchesArchiveScope(archived) else {
            sections = modelContext.sections(for: items, descriptor: request.sectionDescriptor)
            return
        }
        let filteredItems = items.filter(shouldKeep)
        items = filteredItems
        sections = modelContext.sections(for: filteredItems, descriptor: request.sectionDescriptor)
    }

    private func restoreArchivedRelationships(for chat: CodexChat) {
        guard let workspace = chat.workspace else {
            return
        }
        if workspace.chats.contains(where: { $0 === chat }) == false {
            workspace.setChats([chat] + workspace.chats)
        }
        if let group = workspace.workspaceGroup,
            group.workspaces.contains(where: { $0 === workspace }) == false
        {
            group.setWorkspaces(group.workspaces + [workspace])
        }
    }

    private func requestMatchesArchiveScope(_ archived: Bool) -> Bool {
        (request.filter.archived ?? false) == archived
    }

    private func requestIsScoped(to workspace: CodexWorkspace) -> Bool {
        guard let filterWorkspace = request.filter.workspace else {
            return false
        }
        return Self.standardizedPath(filterWorkspace) == Self.standardizedPath(workspace.url)
    }

    private func containsIncludedWorkspace(in group: CodexWorkspaceGroup) -> Bool {
        group.workspaces.contains { containsIncludedChat(in: $0) }
    }

    private func containsIncludedChat(in workspace: CodexWorkspace) -> Bool {
        workspace.chats.contains { shouldInclude($0, archived: $0.isArchived) }
    }

    private static func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
