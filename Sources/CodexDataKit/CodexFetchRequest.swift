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

    @MainActor
    public init<Value: Comparable>(
        _ keyPath: KeyPath<Model, Value>,
        order: CodexSortOrder = .forward
    ) {
        self.init(
            key: Self.requireKnownSortKey(for: keyPath),
            order: order
        )
    }

    @MainActor
    public init<Value: Comparable>(
        _ keyPath: KeyPath<Model, Value?>,
        order: CodexSortOrder = .forward
    ) {
        self.init(
            key: Self.requireKnownSortKey(for: keyPath),
            order: order
        )
    }

    @MainActor
    private static func requireKnownSortKey(for keyPath: AnyKeyPath) -> CodexSortKey {
        guard let key = CodexKnownKeyPaths.sortKey(for: Model.self, keyPath: keyPath) else {
            preconditionFailure(
                "CodexSortDescriptor does not support sorting \(Model.self) by key path \(keyPath)."
            )
        }
        return key
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

    @MainActor
    public init<SectionIdentifier: Hashable & Sendable>(
        _ keyPath: KeyPath<Model, SectionIdentifier>
    ) {
        self.init(key: Self.requireKnownSectionKey(for: keyPath))
    }

    @MainActor
    public init<SectionIdentifier: Hashable & Sendable>(
        _ keyPath: KeyPath<Model, SectionIdentifier?>
    ) {
        self.init(key: Self.requireKnownSectionKey(for: keyPath))
    }

    @MainActor
    private static func requireKnownSectionKey(for keyPath: AnyKeyPath) -> CodexSectionKey {
        guard let key = CodexKnownKeyPaths.sectionKey(for: Model.self, keyPath: keyPath) else {
            preconditionFailure(
                "CodexSectionDescriptor does not support sectioning \(Model.self) by key path \(keyPath)."
            )
        }
        return key
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

public struct CodexFetchPredicate<Model: CodexObservableModel>: Sendable, Hashable {
    public var archived: Bool?
    public var workspaces: [URL]? {
        didSet {
            if workspaces?.isEmpty == true {
                workspaces = nil
            }
        }
    }
    public var workspace: URL? {
        get {
            workspaces?.first
        }
        set {
            workspaces = newValue.map { [$0] }
        }
    }
    public var searchTerm: String? {
        didSet {
            if searchTerm?.isEmpty == true {
                searchTerm = nil
            }
        }
    }
    public var modelProviders: [String]? {
        didSet {
            if modelProviders?.isEmpty == true {
                modelProviders = nil
            }
        }
    }
    public var sourceKinds: [CodexThreadSourceKind]? {
        didSet {
            if sourceKinds?.isEmpty == true {
                sourceKinds = nil
            }
        }
    }
    public var useStateDBOnly: Bool?

    public init(
        archived: Bool? = nil,
        workspace: URL? = nil,
        workspaces: [URL]? = nil,
        searchTerm: String? = nil,
        modelProviders: [String]? = nil,
        sourceKinds: [CodexThreadSourceKind]? = nil,
        useStateDBOnly: Bool? = nil
    ) {
        self.archived = archived
        let workspaceList = workspaces ?? workspace.map { [$0] }
        self.workspaces = workspaceList?.isEmpty == true ? nil : workspaceList
        self.searchTerm = searchTerm?.isEmpty == true ? nil : searchTerm
        self.modelProviders = modelProviders?.isEmpty == true ? nil : modelProviders
        self.sourceKinds = sourceKinds?.isEmpty == true ? nil : sourceKinds
        self.useStateDBOnly = useStateDBOnly
    }
}

public struct CodexFetchDescriptor<Model: CodexObservableModel>: Sendable, Hashable {
    public var predicate: CodexFetchPredicate<Model>
    public var sortBy: [CodexSortDescriptor<Model>]
    public var fetchLimit: Int?
    public var fetchOffset: Int
    package var cursor: String?

    public init(
        predicate: CodexFetchPredicate<Model> = .init(),
        sortBy: [CodexSortDescriptor<Model>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int = 0
    ) {
        self.predicate = predicate
        self.sortBy = sortBy
        self.fetchLimit = fetchLimit
        self.fetchOffset = max(0, fetchOffset)
        self.cursor = nil
    }

}

private enum CodexKnownKeyPaths {
    @MainActor
    static func sortKey<Model: CodexObservableModel>(
        for _: Model.Type,
        keyPath: AnyKeyPath
    ) -> CodexSortKey? {
        if Model.self == CodexWorkspaceGroup.self {
            return sortKeyForWorkspaceGroup(keyPath)
        }
        if Model.self == CodexWorkspace.self {
            return sortKeyForWorkspace(keyPath)
        }
        if Model.self == CodexChat.self {
            return sortKeyForChat(keyPath)
        }
        return nil
    }

    @MainActor
    static func sectionKey<Model: CodexObservableModel>(
        for _: Model.Type,
        keyPath: AnyKeyPath
    ) -> CodexSectionKey? {
        if Model.self == CodexWorkspace.self {
            return keyPath == (\CodexWorkspace.workspaceGroupID as AnyKeyPath)
                ? .workspaceGroup
                : nil
        }
        if Model.self == CodexChat.self {
            if keyPath == (\CodexChat.workspaceGroupID as AnyKeyPath) {
                return .workspaceGroup
            }
            if keyPath == (\CodexChat.workspaceID as AnyKeyPath) {
                return .workspace
            }
        }
        return nil
    }

    @MainActor
    private static func sortKeyForWorkspaceGroup(_ keyPath: AnyKeyPath) -> CodexSortKey? {
        keyPath == (\CodexWorkspaceGroup.name as AnyKeyPath) ? .name : nil
    }

    @MainActor
    private static func sortKeyForWorkspace(_ keyPath: AnyKeyPath) -> CodexSortKey? {
        keyPath == (\CodexWorkspace.name as AnyKeyPath) ? .name : nil
    }

    @MainActor
    private static func sortKeyForChat(_ keyPath: AnyKeyPath) -> CodexSortKey? {
        if keyPath == (\CodexChat.title as AnyKeyPath)
            || keyPath == (\CodexChat.name as AnyKeyPath)
        {
            return .name
        }
        if keyPath == (\CodexChat.createdAt as AnyKeyPath) {
            return .createdAt
        }
        if keyPath == (\CodexChat.updatedAt as AnyKeyPath) {
            return .updatedAt
        }
        if keyPath == (\CodexChat.recencyAt as AnyKeyPath) {
            return .recencyAt
        }
        return nil
    }
}

public final class CodexFetchRequest<Model: CodexObservableModel>: @unchecked Sendable {
    public var predicate: CodexFetchPredicate<Model>
    public var sortDescriptors: [CodexSortDescriptor<Model>]
    public var fetchLimit: Int?
    public var fetchOffset: Int
    package var cursor: String?

    public var fetchDescriptor: CodexFetchDescriptor<Model> {
        get {
            var descriptor = CodexFetchDescriptor(
                predicate: predicate,
                sortBy: sortDescriptors,
                fetchLimit: fetchLimit,
                fetchOffset: fetchOffset
            )
            descriptor.cursor = cursor
            return descriptor
        }
        set {
            predicate = newValue.predicate
            sortDescriptors = newValue.sortBy
            fetchLimit = newValue.fetchLimit
            fetchOffset = newValue.fetchOffset
            cursor = newValue.cursor
        }
    }

    public init(
        predicate: CodexFetchPredicate<Model> = .init(),
        sortDescriptors: [CodexSortDescriptor<Model>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int = 0
    ) {
        self.predicate = predicate
        self.sortDescriptors = sortDescriptors
        self.fetchLimit = fetchLimit
        self.fetchOffset = max(0, fetchOffset)
        self.cursor = nil
    }

    public convenience init(_ descriptor: CodexFetchDescriptor<Model>) {
        self.init(
            predicate: descriptor.predicate,
            sortDescriptors: descriptor.sortBy,
            fetchLimit: descriptor.fetchLimit,
            fetchOffset: descriptor.fetchOffset
        )
        self.cursor = descriptor.cursor
    }

    package func copy() -> CodexFetchRequest<Model> {
        CodexFetchRequest(fetchDescriptor)
    }
}

extension CodexFetchDescriptor where Model == CodexWorkspaceGroup {
    public static var workspaceGroups: Self {
        .init(sortBy: codexDefaultWorkspaceGroupSortDescriptors())
    }
}

extension CodexFetchDescriptor where Model == CodexWorkspace {
    public static var workspaces: Self {
        .init(sortBy: codexDefaultWorkspaceSortDescriptors())
    }

    public static func workspaces(
        sortBy: [CodexSortDescriptor<CodexWorkspace>] = codexDefaultWorkspaceSortDescriptors()
    ) -> Self {
        .init(sortBy: sortBy)
    }
}

extension CodexFetchDescriptor where Model == CodexChat {
    public static var recentChats: Self {
        .init(sortBy: codexDefaultChatSortDescriptors())
    }

    @MainActor
    public static func chats(
        in workspace: CodexWorkspace,
        fetchLimit: Int? = nil
    ) -> Self {
        chats(in: workspace, sortBy: codexDefaultChatSortDescriptors(), fetchLimit: fetchLimit)
    }

    @MainActor
    public static func chats(
        in workspace: CodexWorkspace,
        sortBy: [CodexSortDescriptor<CodexChat>],
        fetchLimit: Int? = nil
    ) -> Self {
        .init(
            predicate: .init(workspace: workspace.url),
            sortBy: sortBy,
            fetchLimit: fetchLimit
        )
    }
}

extension CodexFetchRequest where Model == CodexWorkspaceGroup {
    public static var workspaceGroups: Self {
        Self(.workspaceGroups)
    }
}

extension CodexFetchRequest where Model == CodexWorkspace {
    public static var workspaces: Self {
        Self(.workspaces)
    }

    public static func workspaces(
        sortDescriptors: [CodexSortDescriptor<CodexWorkspace>] =
            codexDefaultWorkspaceSortDescriptors()
    ) -> Self {
        Self(.workspaces(sortBy: sortDescriptors))
    }
}

extension CodexFetchRequest where Model == CodexChat {
    public static var recentChats: Self {
        Self(.recentChats)
    }

    @MainActor
    public static func chats(
        in workspace: CodexWorkspace,
        fetchLimit: Int? = nil
    ) -> Self {
        chats(
            in: workspace,
            sortDescriptors: codexDefaultChatSortDescriptors(),
            fetchLimit: fetchLimit
        )
    }

    @MainActor
    public static func chats(
        in workspace: CodexWorkspace,
        sortDescriptors: [CodexSortDescriptor<CodexChat>],
        fetchLimit: Int? = nil
    ) -> Self {
        Self(.chats(
            in: workspace,
            sortBy: sortDescriptors,
            fetchLimit: fetchLimit
        ))
    }
}

@usableFromInline
func codexDefaultWorkspaceGroupSortDescriptors()
    -> [CodexSortDescriptor<CodexWorkspaceGroup>]
{
    [CodexSortDescriptor(key: .name, order: .forward)]
}

@usableFromInline
func codexDefaultWorkspaceSortDescriptors() -> [CodexSortDescriptor<CodexWorkspace>] {
    [CodexSortDescriptor(key: .name, order: .forward)]
}

@usableFromInline
func codexDefaultChatSortDescriptors() -> [CodexSortDescriptor<CodexChat>] {
    [CodexSortDescriptor(key: .updatedAt, order: .reverse)]
}

public enum CodexFetchSectionID: Sendable, Hashable, CustomStringConvertible {
    case `default`
    case workspaceGroup(CodexWorkspaceGroupID)
    case workspace(CodexWorkspaceID)
    case unknown(String)

    public var description: String {
        switch self {
        case .default:
            "default"
        case .workspaceGroup(let id):
            id.rawValue
        case .workspace(let id):
            id.rawValue
        case .unknown(let rawValue):
            rawValue
        }
    }
}

public struct CodexFetchSection<Model: CodexObservableModel>: Identifiable {
    public var id: CodexFetchSectionID
    public var title: String?
    public var items: [Model]

    public init(id: CodexFetchSectionID, title: String?, items: [Model]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

extension CodexFetchSection where Model == CodexChat {
    public var workspaceGroupID: CodexWorkspaceGroupID? {
        guard case .workspaceGroup(let id) = id else {
            return nil
        }
        return id
    }

    public var workspaceID: CodexWorkspaceID? {
        guard case .workspace(let id) = id else {
            return nil
        }
        return id
    }

    @MainActor
    public var workspaceGroup: CodexWorkspaceGroup? {
        codexOnlyWorkspaceGroup(items.map { $0.workspace?.workspaceGroup })
    }

    @MainActor
    public var workspaces: [CodexWorkspace] {
        codexUniqueWorkspaces(items.compactMap(\.workspace))
    }

    @MainActor
    public var uncategorizedChats: [CodexChat] {
        items.filter { $0.workspace == nil }
    }

    @MainActor
    public func chats(in workspaceID: CodexWorkspaceID) -> [CodexChat] {
        items.filter { $0.workspace?.id == workspaceID }
    }

    @MainActor
    public func chat(id: CodexThreadID) -> CodexChat? {
        items.first { $0.id == id }
    }
}

extension CodexFetchSection where Model == CodexWorkspace {
    public var workspaceGroupID: CodexWorkspaceGroupID? {
        guard case .workspaceGroup(let id) = id else {
            return nil
        }
        return id
    }

    @MainActor
    public var workspaceGroup: CodexWorkspaceGroup? {
        codexOnlyWorkspaceGroup(items.map(\.workspaceGroup))
    }

    @MainActor
    public var workspaces: [CodexWorkspace] {
        codexUniqueWorkspaces(items)
    }
}

@MainActor
private func codexUniqueWorkspaces(_ workspaces: [CodexWorkspace]) -> [CodexWorkspace] {
    var seen: Set<CodexWorkspaceID> = []
    var result: [CodexWorkspace] = []
    for workspace in workspaces where seen.insert(workspace.id).inserted {
        result.append(workspace)
    }
    return result
}

@MainActor
private func codexOnlyWorkspaceGroup(_ groups: [CodexWorkspaceGroup?]) -> CodexWorkspaceGroup? {
    var result: CodexWorkspaceGroup?
    var hasMissingGroup = false
    for group in groups {
        guard let group else {
            hasMissingGroup = true
            continue
        }
        guard let existing = result else {
            result = group
            continue
        }
        guard existing.id == group.id else {
            return nil
        }
    }
    return hasMissingGroup && result != nil ? nil : result
}

package struct CodexFetchPage<Model: CodexObservableModel> {
    package var items: [Model]
    package var nextCursor: String?
    package var backwardsCursor: String?
    package var relationshipItems: [Model]? = nil
    package var relationshipIsComplete: Bool? = nil
}

package struct CodexFetchedChatRevalidation {
    package var chat: CodexChat
    package var previousWorkspace: CodexWorkspace?
    package var previousGroup: CodexWorkspaceGroup?
    package var archived: Bool
}

@MainActor
package protocol CodexFetchedResultsRegistration: AnyObject {
    func insert(_ chat: CodexChat, archived: Bool) async
    func archive(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) async
    func revalidate(_ changes: [CodexFetchedChatRevalidation]) async
    func remove(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) async
    func refresh(_ workspace: CodexWorkspace, archived: Bool, removedChats: [CodexChat]) async
    func refresh(_ group: CodexWorkspaceGroup, archived: Bool, removedChats: [CodexChat]) async
}

@MainActor
@Observable
public final class CodexFetchedResults<Model: CodexObservableModel> {
    public let modelContext: CodexModelContext
    public private(set) var fetchDescriptor: CodexFetchDescriptor<Model>
    public private(set) var sectionBy: CodexSectionDescriptor<Model>?
    public private(set) var items: [Model] = []
    public private(set) var sections: [CodexFetchSection<Model>] = []
    public private(set) var nextCursor: String?
    public private(set) var backwardsCursor: String?
    public var phase: CodexDataPhase = .idle
    public var lastErrorDescription: String?

    @ObservationIgnored
    private var hasPerformedFetch = false

    @ObservationIgnored
    private let transactionRelay = CodexAsyncStreamRelay<CodexFetchedResultsTransaction<Model>>()

    package init(
        modelContext: CodexModelContext,
        fetchDescriptor: CodexFetchDescriptor<Model>,
        sectionBy: CodexSectionDescriptor<Model>?
    ) {
        self.modelContext = modelContext
        self.fetchDescriptor = fetchDescriptor
        self.sectionBy = sectionBy
    }

    isolated deinit {
        transactionRelay.finish()
    }

    package func makeTransactionStream()
        -> AsyncStream<CodexFetchedResultsTransaction<Model>>
    {
        transactionRelay.makeStream()
    }

    public func performFetch() async throws {
        let reason: CodexFetchedResultsTransactionReason =
            hasPerformedFetch ? .refresh : .initialFetch
        try await load(fetchDescriptor, appending: false, reason: reason)
    }

    public func refresh() async throws {
        try await performFetch()
    }

    public func loadNextPage() async throws {
        guard let nextCursor else {
            return
        }
        var descriptor = fetchDescriptor
        descriptor.cursor = nextCursor
        try await load(descriptor, appending: true, reason: .pageAppend)
    }

    private func load(
        _ descriptor: CodexFetchDescriptor<Model>,
        appending: Bool,
        reason: CodexFetchedResultsTransactionReason
    ) async throws {
        phase = .loading
        lastErrorDescription = nil
        let previousBackwardsCursor = backwardsCursor
        do {
            let page = try await modelContext.fetchPage(descriptor, excluding: self)
            let newItems = loadedItems(from: page, appending: appending)
            let relationshipDescriptor = appending ? fetchDescriptor : descriptor
            await modelContext.syncLoadedRelationships(
                from: page,
                descriptor: relationshipDescriptor,
                loadedItems: newItems,
                excluding: self
            )
            nextCursor = page.nextCursor
            backwardsCursor = appending ? previousBackwardsCursor : page.backwardsCursor
            phase = .loaded
            hasPerformedFetch = true
            updateItemsAndSections(
                items: newItems,
                sections: modelContext.sections(for: newItems, sectionBy: sectionBy),
                reason: reason
            )
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    private func loadedItems(
        from page: CodexFetchPage<Model>,
        appending: Bool
    ) -> [Model] {
        guard appending else {
            return page.items
        }
        if page.relationshipIsComplete == true, let authoritativeItems = page.relationshipItems {
            let start = min(
                modelContext.localCursorOffset(from: fetchDescriptor.cursor)
                    + fetchDescriptor.fetchOffset,
                authoritativeItems.count
            )
            let end = min(start + items.count + page.items.count, authoritativeItems.count)
            return Array(authoritativeItems[start..<end])
        }
        return append(page.items, to: items)
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

    private var currentSnapshot: CodexFetchedResultsSnapshot<Model.ID> {
        CodexFetchedResultsSnapshot(sections: sections)
    }

    private func updateItemsAndSections(
        items newItems: [Model],
        sections newSections: [CodexFetchSection<Model>],
        reason: CodexFetchedResultsTransactionReason,
        updatedItemIDs: Set<Model.ID> = []
    ) {
        let oldSnapshot = currentSnapshot
        items = newItems
        sections = newSections
        yieldTransaction(
            reason: reason,
            oldSnapshot: oldSnapshot,
            updatedItemIDs: updatedItemIDs
        )
    }

    private func yieldTransaction(
        reason: CodexFetchedResultsTransactionReason,
        oldSnapshot: CodexFetchedResultsSnapshot<Model.ID>,
        updatedItemIDs: Set<Model.ID>
    ) {
        guard transactionRelay.hasContinuations else {
            return
        }
        let transaction = CodexFetchedResultsTransaction<Model>(
            reason: reason,
            oldSnapshot: oldSnapshot,
            newSnapshot: currentSnapshot,
            updatedItemIDs: updatedItemIDs
        )
        guard transaction.hasChanges
            || reason == .initialFetch
            || reason == .refresh
        else {
            return
        }
        transactionRelay.yield(transaction)
    }
}

extension CodexFetchedResults: CodexFetchedResultsRegistration {
    package func insert(_ chat: CodexChat, archived: Bool) async {
        if requiresServerRefreshAfterMutation {
            await refreshAfterMutation(reason: .insert)
            return
        }
        guard let model = insertionModel(for: chat, archived: archived) else {
            return
        }
        await upsertOrRefresh(model, reason: .insert)
    }

    package func archive(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) async {
        if requiresServerRefreshAfterMutation {
            _ = applyLocalRevalidation([
                CodexFetchedChatRevalidation(
                    chat: chat,
                    previousWorkspace: workspace,
                    previousGroup: group,
                    archived: true
                )
            ], reason: .archive)
            await refreshAfterMutation(reason: .archive)
            return
        }
        if let model = insertionModel(for: chat, archived: true) {
            await upsertOrRefresh(model, reason: .archive)
        } else {
            await remove(chat, workspace: workspace, group: group, reason: .archive)
        }
    }

    package func revalidate(_ changes: [CodexFetchedChatRevalidation]) async {
        guard changes.isEmpty == false else {
            return
        }
        if requiresServerRefreshAfterMutation {
            _ = applyLocalRevalidation(changes, reason: .revalidate)
            await refreshAfterMutation(reason: .revalidate)
            return
        }
        let originalCount = applyLocalRevalidation(changes, reason: .revalidate)
        if await refreshAfterPagedRevalidationIfNeeded(changes) {
            return
        }
        if canEvaluateFilterLocally {
            for change in changes {
                guard let model = insertionModel(for: change.chat, archived: change.archived) else {
                    continue
                }
                guard await upsertOrRefresh(model, reason: .revalidate) else {
                    return
                }
            }
        }
        await backfillAfterLocalRemovalIfNeeded(originalCount: originalCount, reason: .revalidate)
    }

    package func remove(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) async {
        await remove(chat, workspace: workspace, group: group, reason: .remove)
    }

    private func remove(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?,
        reason: CodexFetchedResultsTransactionReason
    ) async {
        let originalCount = applyLocalRemoval(
            of: chat,
            workspace: workspace,
            group: group,
            reason: reason
        )
        if fetchDescriptor.fetchOffset > 0 {
            await refreshAfterMutation(reason: reason)
            return
        }
        if requiresServerRefreshAfterMutation {
            await refreshAfterMutation(reason: reason)
            return
        }
        guard items.count != originalCount else {
            if modelContext.localCursorOffset(from: fetchDescriptor.cursor) > 0
                || fetchDescriptor.fetchOffset > 0
            {
                await refreshAfterMutation(reason: reason)
            }
            return
        }
        await backfillAfterLocalRemovalIfNeeded(originalCount: originalCount, reason: reason)
    }

    package func refresh(
        _ workspace: CodexWorkspace,
        archived: Bool,
        removedChats: [CodexChat]
    ) async {
        let originalCount = items.count
        let refreshed = refreshItems(archived: archived, keeping: {
            shouldKeep($0, afterRefreshing: workspace, removedChats: removedChats)
        }, reason: .refresh)
        if requiresServerRefreshAfterMutation {
            await refreshAfterMutation(reason: .refresh)
            return
        }
        guard refreshed else {
            return
        }
        guard upsertLoadedModels(from: workspace) else {
            await refreshAfterMutation(reason: .refresh)
            return
        }
        await backfillAfterLocalRemovalIfNeeded(originalCount: originalCount, reason: .refresh)
    }

    package func refresh(
        _ group: CodexWorkspaceGroup,
        archived: Bool,
        removedChats: [CodexChat]
    ) async {
        let originalCount = items.count
        let refreshed = refreshItems(archived: archived, keeping: {
            shouldKeep($0, afterRefreshing: group, removedChats: removedChats)
        }, reason: .refresh)
        if requiresServerRefreshAfterMutation {
            await refreshAfterMutation(reason: .refresh)
            return
        }
        guard refreshed else {
            return
        }
        guard upsertLoadedModels(from: group) else {
            await refreshAfterMutation(reason: .refresh)
            return
        }
        await backfillAfterLocalRemovalIfNeeded(originalCount: originalCount, reason: .refresh)
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

    @discardableResult
    private func upsertOrRefresh(
        _ model: Model,
        reason: CodexFetchedResultsTransactionReason
    ) async -> Bool {
        guard upsert(model, reason: reason) else {
            await refreshAfterMutation(reason: reason)
            return false
        }
        return true
    }

    @discardableResult
    private func upsert(
        _ model: Model,
        reason: CodexFetchedResultsTransactionReason
    ) -> Bool {
        var nextItems = items
        let insertedModel: Bool
        if let index = nextItems.firstIndex(where: { $0.id == model.id }) {
            nextItems[index] = model
            insertedModel = false
        } else {
            guard canInsertLiveModel else {
                return false
            }
            nextItems.insert(model, at: 0)
            insertedModel = true
        }
        let sortedItems = modelContext.sortedItems(nextItems, for: fetchDescriptor)
        let windowItems = loadedWindowItems(
            sortedItems,
            insertedModel: insertedModel
        )
        if insertedModel,
            nextCursor == nil,
            sortedItems.count > windowItems.count
        {
            let cursorOffset =
                modelContext.localCursorOffset(from: fetchDescriptor.cursor) + windowItems.count
            nextCursor = modelContext.localCursor(for: cursorOffset)
        }
        updateItemsAndSections(
            items: windowItems,
            sections: modelContext.sections(for: windowItems, sectionBy: sectionBy),
            reason: reason,
            updatedItemIDs: insertedModel ? [] : [model.id]
        )
        return true
    }

    private var canInsertLiveModel: Bool {
        canEvaluateFilterLocally
            && fetchDescriptor.cursor == nil
            && nextCursor == nil
    }

    private func loadedWindowItems(_ models: [Model], insertedModel: Bool) -> [Model] {
        guard let fetchLimit = fetchDescriptor.fetchLimit else {
            return models
        }
        let loadedCount = items.count
        let targetCount: Int
        if insertedModel && (loadedCount < fetchLimit || loadedCount > fetchLimit) {
            targetCount = loadedCount + 1
        } else {
            targetCount = loadedCount
        }
        return Array(models.prefix(max(targetCount, 0)))
    }

    private var shouldRefreshAfterLocalRemoval: Bool {
        nextCursor != nil
    }

    private var canEvaluateFilterLocally: Bool {
        membershipRequiresServerRefresh == false
    }

    private var requiresServerRefreshAfterMutation: Bool {
        membershipRequiresServerRefresh || usesServerOwnedOrdering
    }

    private var membershipRequiresServerRefresh: Bool {
        fetchDescriptor.predicate.searchTerm?.isEmpty == false
            || fetchDescriptor.predicate.modelProviders?.isEmpty == false
            || fetchDescriptor.predicate.sourceKinds != nil
            || fetchDescriptor.predicate.useStateDBOnly != nil
    }

    private var usesServerOwnedOrdering: Bool {
        fetchDescriptor.sortBy.first?.key == .recencyAt
            || (Model.self == CodexChat.self && fetchDescriptor.sortBy.isEmpty)
    }

    private func backfillAfterLocalRemovalIfNeeded(
        originalCount: Int,
        reason: CodexFetchedResultsTransactionReason
    ) async {
        let missingCount = originalCount - items.count
        guard missingCount > 0, shouldRefreshAfterLocalRemoval else {
            return
        }
        let backfillOffset = modelContext.localCursorOffset(from: fetchDescriptor.cursor) + items.count
        var descriptor = fetchDescriptor
        descriptor.cursor = modelContext.backfillCursor(after: backfillOffset, currentCursor: nextCursor)
        descriptor.fetchLimit = missingCount
        do {
            try await load(descriptor, appending: true, reason: reason)
        } catch {
            // load records the failed phase; the server mutation has already succeeded.
        }
    }

    private func refreshAfterMutation(reason: CodexFetchedResultsTransactionReason) async {
        do {
            try await load(fetchDescriptor, appending: false, reason: reason)
        } catch {
            // performFetch records the failed phase; the server mutation has already succeeded.
        }
    }

    private func refreshAfterPagedRevalidationIfNeeded(
        _ changes: [CodexFetchedChatRevalidation]
    ) async -> Bool {
        guard Model.self == CodexChat.self,
            (nextCursor != nil || fetchDescriptor.cursor != nil || fetchDescriptor.fetchOffset > 0),
            changes.contains(where: { shouldInclude($0.chat, archived: $0.archived) })
        else {
            return false
        }
        do {
            try await load(fetchDescriptor, appending: false, reason: .revalidate)
            return true
        } catch {
            // performFetch records the failed phase; the server mutation has already succeeded.
            return false
        }
    }

    private func shouldInclude(_ chat: CodexChat, archived: Bool) -> Bool {
        switch fetchDescriptor.predicate.archived {
        case .some(let expectedArchived):
            guard expectedArchived == archived else {
                return false
            }
        case .none:
            guard archived == false else {
                return false
            }
        }

        if let workspaces = fetchDescriptor.predicate.workspaces {
            guard let chatWorkspace = chat.workspace,
                workspaces.contains(where: {
                    Self.standardizedPath(chatWorkspace.url) == Self.standardizedPath($0)
                })
            else {
                return false
            }
        }

        if let searchTerm = fetchDescriptor.predicate.searchTerm, searchTerm.isEmpty == false {
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

        if let modelProviders = fetchDescriptor.predicate.modelProviders,
            modelProviders.isEmpty == false
        {
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
        afterRefreshing workspace: CodexWorkspace,
        removedChats: [CodexChat]
    ) -> Bool {
        if let item = item as? CodexChat {
            if removedChats.contains(where: { $0 === item }) {
                return false
            }
            if workspace.chats.contains(where: { $0 === item }) {
                return shouldInclude(item, archived: item.isArchived)
            }
            if requestIsScoped(to: workspace) {
                return false
            }
            return true
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
        afterRefreshing group: CodexWorkspaceGroup,
        removedChats: [CodexChat]
    ) -> Bool {
        if let item = item as? CodexChat {
            if removedChats.contains(where: { $0 === item }) {
                return false
            }
            guard canEvaluateFilterLocally else {
                return true
            }
            guard let workspace = item.workspace,
                group.workspaces.contains(where: { $0 === workspace })
            else {
                return true
            }
            return workspace.chats.contains { $0 === item }
                && shouldInclude(item, archived: item.isArchived)
        }
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

    @discardableResult
    private func applyLocalRemoval(
        of chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?,
        reason: CodexFetchedResultsTransactionReason
    ) -> Int {
        let originalCount = items.count
        let filteredItems = items.filter {
            shouldKeep($0, afterRemoving: chat, workspace: workspace, group: group)
        }
        if filteredItems.count != items.count {
            updateItemsAndSections(
                items: filteredItems,
                sections: modelContext.sections(for: filteredItems, sectionBy: sectionBy),
                reason: reason
            )
        }
        return originalCount
    }

    @discardableResult
    private func applyLocalRevalidation(
        _ changes: [CodexFetchedChatRevalidation],
        reason: CodexFetchedResultsTransactionReason
    ) -> Int {
        let originalCount = items.count
        var filteredItems = items
        for change in changes {
            filteredItems = filteredItems.filter {
                shouldKeep(
                    $0,
                    afterRevalidating: change.chat,
                    previousWorkspace: change.previousWorkspace,
                    previousGroup: change.previousGroup,
                    archived: change.archived
                )
            }
        }
        let sortedItems = modelContext.sortedItems(filteredItems, for: fetchDescriptor)
        updateItemsAndSections(
            items: sortedItems,
            sections: modelContext.sections(for: sortedItems, sectionBy: sectionBy),
            reason: reason,
            updatedItemIDs: updatedItemIDs(for: changes)
        )
        return originalCount
    }

    private func updatedItemIDs(for changes: [CodexFetchedChatRevalidation]) -> Set<Model.ID> {
        var ids: Set<Model.ID> = []
        for change in changes {
            insertUpdatedItemID(change.chat, into: &ids)
            insertUpdatedItemID(change.previousWorkspace, into: &ids)
            insertUpdatedItemID(change.chat.workspace, into: &ids)
            insertUpdatedItemID(change.previousGroup, into: &ids)
            insertUpdatedItemID(change.chat.workspace?.workspaceGroup, into: &ids)
        }
        return ids
    }

    private func insertUpdatedItemID(
        _ model: (any CodexObservableModel)?,
        into ids: inout Set<Model.ID>
    ) {
        guard let item = model as? Model else {
            return
        }
        ids.insert(item.id)
    }

    @discardableResult
    private func refreshItems(
        archived: Bool,
        keeping shouldKeep: (Model) -> Bool,
        reason: CodexFetchedResultsTransactionReason
    ) -> Bool {
        guard requestMatchesArchiveScope(archived) else {
            updateItemsAndSections(
                items: items,
                sections: modelContext.sections(for: items, sectionBy: sectionBy),
                reason: reason
            )
            return false
        }
        let filteredItems = items.filter(shouldKeep)
        updateItemsAndSections(
            items: filteredItems,
            sections: modelContext.sections(for: filteredItems, sectionBy: sectionBy),
            reason: reason
        )
        return true
    }

    private func upsertLoadedModels(from workspace: CodexWorkspace) -> Bool {
        for chat in workspace.chats {
            guard let model = insertionModel(for: chat, archived: chat.isArchived) else {
                continue
            }
            guard upsert(model, reason: .refresh) else {
                return false
            }
        }
        return true
    }

    private func upsertLoadedModels(from group: CodexWorkspaceGroup) -> Bool {
        for workspace in group.workspaces {
            guard upsertLoadedModels(from: workspace) else {
                return false
            }
        }
        return true
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
        (fetchDescriptor.predicate.archived ?? false) == archived
    }

    private func requestIsScoped(to workspace: CodexWorkspace) -> Bool {
        guard let filterWorkspaces = fetchDescriptor.predicate.workspaces else {
            return false
        }
        return filterWorkspaces.contains {
            Self.standardizedPath($0) == Self.standardizedPath(workspace.url)
        }
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

@MainActor
private final class CodexAsyncStreamRelay<Element: Sendable>: @unchecked Sendable {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    var hasContinuations: Bool {
        continuations.isEmpty == false
    }

    func makeStream() -> AsyncStream<Element> {
        let id = UUID()
        let pair = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        continuations[id] = pair.continuation
        let owner = CodexAsyncStreamRelayWeakBox(self)
        pair.continuation.onTermination = codexAsyncStreamRelayTermination(owner: owner, id: id)
        return pair.stream
    }

    func yield(_ element: Element) {
        for continuation in continuations.values {
            continuation.yield(element)
        }
    }

    fileprivate func removeStream(_ id: UUID) {
        continuations.removeValue(forKey: id)?.finish()
    }

    func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }

    isolated deinit {
        finish()
    }
}

private final class CodexAsyncStreamRelayWeakBox<Element: Sendable>: @unchecked Sendable {
    @MainActor
    weak var value: CodexAsyncStreamRelay<Element>?

    @MainActor
    init(_ value: CodexAsyncStreamRelay<Element>) {
        self.value = value
    }
}

private func codexAsyncStreamRelayTermination<Element: Sendable>(
    owner: CodexAsyncStreamRelayWeakBox<Element>,
    id: UUID
) -> @Sendable (AsyncStream<Element>.Continuation.Termination) -> Void {
    { @Sendable _ in
        Task { @MainActor in
            owner.value?.removeStream(id)
        }
    }
}
