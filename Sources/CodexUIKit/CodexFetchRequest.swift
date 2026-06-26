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
    func remove(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    )
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
            modelContext.syncLoadedRelationships(newItems, request: request)
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
        if let model = archivedChatModel(for: chat) {
            upsert(model)
        } else {
            remove(chat, workspace: workspace, group: group)
        }
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

    private func archivedChatModel(for chat: CodexChat) -> Model? {
        guard Model.self == CodexChat.self,
              shouldInclude(chat, archived: true)
        else {
            return nil
        }
        return chat as? Model
    }

    private func insertionModel(for chat: CodexChat, archived: Bool) -> Model? {
        guard shouldInclude(chat, archived: archived) else {
            return nil
        }
        if let chat = chat as? Model {
            return chat
        }
        guard archived == false else {
            return nil
        }
        if let workspace = chat.workspace as? Model {
            return workspace
        }
        if let workspaceGroup = chat.workspace?.workspaceGroup,
           let group = workspaceGroup as? Model
        {
            return group
        }
        return nil
    }

    private func upsert(_ model: Model) {
        var nextItems = items
        if let index = nextItems.firstIndex(where: { $0.id == model.id }) {
            nextItems[index] = model
        } else {
            nextItems.insert(model, at: 0)
        }
        items = modelContext.sortedItems(nextItems, for: request)
        sections = modelContext.sections(for: items, descriptor: request.sectionDescriptor)
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
            guard searchableText.contains(where: { text in
                text?.localizedCaseInsensitiveContains(searchTerm) == true
            }) else {
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

        if request.filter.sourceKinds != nil || request.filter.useStateDBOnly != nil {
            return false
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
            return item.id != workspace.id || workspace.chats.isEmpty == false
        }
        if let item = item as? CodexWorkspaceGroup, let group {
            return item.id != group.id || group.workspaces.isEmpty == false
        }
        return true
    }

    private static func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
