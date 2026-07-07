import CodexAppServerKit
import Foundation
import Observation

package enum CodexSortKey: Sendable, Hashable {
    case name
    case createdAt
    case updatedAt
    case recencyAt
}

package enum CodexSortPath: Sendable, Hashable {
    case workspaceGroupName
    case workspaceName
    case chatTitle
    case chatName
    case chatCreatedAt
    case chatUpdatedAt
    case chatRecencyAt

    package var sortKey: CodexSortKey {
        switch self {
        case .workspaceGroupName, .workspaceName, .chatTitle, .chatName:
            return .name
        case .chatCreatedAt:
            return .createdAt
        case .chatUpdatedAt:
            return .updatedAt
        case .chatRecencyAt:
            return .recencyAt
        }
    }
}

package struct CodexSortPlan<Model: CodexPersistentModel>: Sendable, Hashable {
    package var path: CodexSortPath
    package var key: CodexSortKey {
        path.sortKey
    }
    package var order: SortOrder
    package var comparisonSignature: String?

    package init(descriptor: SortDescriptor<Model>) {
        guard let keyPath = descriptor.keyPath,
            let path = CodexKnownKeyPaths.sortPath(for: Model.self, keyPath: keyPath)
        else {
            preconditionFailure(
                "CodexFetchDescriptor does not support sorting \(Model.self) by descriptor \(descriptor)."
            )
        }
        self.path = path
        self.order = descriptor.order
        self.comparisonSignature = Self.comparisonSignature(for: descriptor)
    }

    package var threadSortDirection: CodexSortDirection {
        switch order {
        case .forward:
            .ascending
        case .reverse:
            .descending
        }
    }

    package var threadSortKey: CodexThreadSortKey? {
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

    private static func comparisonSignature(for descriptor: SortDescriptor<Model>) -> String? {
        Mirror(reflecting: descriptor).children.first { child in
            child.label == "comparison"
        }.map { child in
            String(describing: child.value)
        }
    }
}

package enum CodexSectionKey: Sendable, Hashable {
    case workspaceGroup
    case workspace
}

public struct CodexSectionDescriptor<Model: CodexPersistentModel>: Sendable, Hashable {
    package var key: CodexSectionKey

    package init(key: CodexSectionKey) {
        self.key = key
    }

    public init<SectionIdentifier: Hashable & Sendable>(
        _ keyPath: KeyPath<Model, SectionIdentifier>
    ) {
        self.init(key: Self.requireKnownSectionKey(for: keyPath))
    }

    public init<SectionIdentifier: Hashable & Sendable>(
        _ keyPath: KeyPath<Model, SectionIdentifier?>
    ) {
        self.init(key: Self.requireKnownSectionKey(for: keyPath))
    }

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

public struct CodexFetchDescriptor<Model: CodexPersistentModel>: Sendable {
    public var predicate: Predicate<Model>? {
        didSet {
            Self.validate(predicate: predicate)
        }
    }
    public var sortBy: [SortDescriptor<Model>]
    public var fetchLimit: Int? {
        didSet {
            Self.validate(fetchLimit: fetchLimit)
        }
    }
    public var fetchOffset: Int? {
        didSet {
            Self.validate(fetchOffset: fetchOffset)
        }
    }
    public var includePendingChanges: Bool

    public init(
        predicate: Predicate<Model>? = nil,
        sortBy: [SortDescriptor<Model>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int? = nil,
        includePendingChanges: Bool = true
    ) {
        Self.validate(predicate: predicate)
        Self.validate(fetchLimit: fetchLimit)
        Self.validate(fetchOffset: fetchOffset)
        self.predicate = predicate
        self.sortBy = sortBy
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
        self.includePendingChanges = includePendingChanges
    }

    package var normalizedFetchOffset: Int {
        fetchOffset ?? 0
    }

    package var sortPlans: [CodexSortPlan<Model>] {
        sortBy.map(CodexSortPlan.init(descriptor:))
    }

    private static func validate(fetchLimit: Int?) {
        if let fetchLimit {
            precondition(fetchLimit >= 0, "CodexFetchDescriptor fetchLimit must be non-negative.")
        }
    }

    private static func validate(fetchOffset: Int?) {
        if let fetchOffset {
            precondition(fetchOffset >= 0, "CodexFetchDescriptor fetchOffset must be non-negative.")
        }
    }

    private static func validate(predicate: Predicate<Model>?) {
        guard predicate != nil, Model.self != CodexChat.self else {
            return
        }
        preconditionFailure("CodexFetchDescriptor does not support predicates for \(Model.self).")
    }
}

package enum CodexKnownKeyPaths {
    static func sortPath<Model: CodexPersistentModel>(
        for _: Model.Type,
        keyPath: AnyKeyPath
    ) -> CodexSortPath? {
        if Model.self == CodexWorkspaceGroup.self {
            return sortPathForWorkspaceGroup(keyPath)
        }
        if Model.self == CodexWorkspace.self {
            return sortPathForWorkspace(keyPath)
        }
        if Model.self == CodexChat.self {
            return sortPathForChat(keyPath)
        }
        return nil
    }

    static func sortKey<Model: CodexPersistentModel>(
        for _: Model.Type,
        keyPath: AnyKeyPath
    ) -> CodexSortKey? {
        sortPath(for: Model.self, keyPath: keyPath)?.sortKey
    }

    static func sectionKey<Model: CodexPersistentModel>(
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

    private static func sortPathForWorkspaceGroup(_ keyPath: AnyKeyPath) -> CodexSortPath? {
        keyPath == (\CodexWorkspaceGroup.name as AnyKeyPath) ? .workspaceGroupName : nil
    }

    private static func sortPathForWorkspace(_ keyPath: AnyKeyPath) -> CodexSortPath? {
        keyPath == (\CodexWorkspace.name as AnyKeyPath) ? .workspaceName : nil
    }

    private static func sortPathForChat(_ keyPath: AnyKeyPath) -> CodexSortPath? {
        if keyPath == (\CodexChat.title as AnyKeyPath) {
            return .chatTitle
        }
        if keyPath == (\CodexChat.name as AnyKeyPath) {
            return .chatName
        }
        if keyPath == (\CodexChat.createdAt as AnyKeyPath) {
            return .chatCreatedAt
        }
        if keyPath == (\CodexChat.updatedAt as AnyKeyPath) {
            return .chatUpdatedAt
        }
        if keyPath == (\CodexChat.recencyAt as AnyKeyPath) {
            return .chatRecencyAt
        }
        return nil
    }
}

public final class CodexFetchRequest<Model: CodexPersistentModel> {
    public var predicate: Predicate<Model>? {
        didSet {
            Self.validate(predicate: predicate)
        }
    }
    public var sortDescriptors: [SortDescriptor<Model>]
    public var fetchLimit: Int? {
        didSet {
            Self.validate(fetchLimit: fetchLimit)
        }
    }
    public var fetchOffset: Int? {
        didSet {
            Self.validate(fetchOffset: fetchOffset)
        }
    }
    public var includePendingChanges: Bool

    public var fetchDescriptor: CodexFetchDescriptor<Model> {
        get {
            CodexFetchDescriptor(
                predicate: predicate,
                sortBy: sortDescriptors,
                fetchLimit: fetchLimit,
                fetchOffset: fetchOffset,
                includePendingChanges: includePendingChanges
            )
        }
        set {
            predicate = newValue.predicate
            sortDescriptors = newValue.sortBy
            fetchLimit = newValue.fetchLimit
            fetchOffset = newValue.fetchOffset
            includePendingChanges = newValue.includePendingChanges
        }
    }

    public init(
        predicate: Predicate<Model>? = nil,
        sortDescriptors: [SortDescriptor<Model>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int? = nil,
        includePendingChanges: Bool = true
    ) {
        Self.validate(predicate: predicate)
        Self.validate(fetchLimit: fetchLimit)
        Self.validate(fetchOffset: fetchOffset)
        self.predicate = predicate
        self.sortDescriptors = sortDescriptors
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
        self.includePendingChanges = includePendingChanges
    }

    public convenience init(_ descriptor: CodexFetchDescriptor<Model>) {
        self.init(
            predicate: descriptor.predicate,
            sortDescriptors: descriptor.sortBy,
            fetchLimit: descriptor.fetchLimit,
            fetchOffset: descriptor.fetchOffset,
            includePendingChanges: descriptor.includePendingChanges
        )
    }

    package func copy() -> CodexFetchRequest<Model> {
        CodexFetchRequest(fetchDescriptor)
    }

    private static func validate(fetchLimit: Int?) {
        if let fetchLimit {
            precondition(fetchLimit >= 0, "CodexFetchRequest fetchLimit must be non-negative.")
        }
    }

    private static func validate(fetchOffset: Int?) {
        if let fetchOffset {
            precondition(fetchOffset >= 0, "CodexFetchRequest fetchOffset must be non-negative.")
        }
    }

    private static func validate(predicate: Predicate<Model>?) {
        guard predicate != nil, Model.self != CodexChat.self else {
            return
        }
        preconditionFailure("CodexFetchRequest does not support predicates for \(Model.self).")
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
        sortBy: [SortDescriptor<CodexWorkspace>] = codexDefaultWorkspaceSortDescriptors()
    ) -> Self {
        .init(sortBy: sortBy)
    }
}

extension CodexFetchDescriptor where Model == CodexChat {
    public static var recentChats: Self {
        .init(
            predicate: #Predicate<CodexChat> { $0.isArchived == false },
            sortBy: codexDefaultChatSortDescriptors()
        )
    }

    public static func chats(
        in workspace: CodexWorkspace,
        fetchLimit: Int? = nil
    ) -> Self {
        chats(in: workspace, sortBy: codexDefaultChatSortDescriptors(), fetchLimit: fetchLimit)
    }

    public static func chats(
        in workspace: CodexWorkspace,
        sortBy: [SortDescriptor<CodexChat>],
        fetchLimit: Int? = nil
    ) -> Self {
        let scopedWorkspaceID: CodexWorkspaceID? = workspace.id
        return .init(
            predicate: #Predicate<CodexChat> { chat in
                chat.workspaceID == scopedWorkspaceID && chat.isArchived == false
            },
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
        sortDescriptors: [SortDescriptor<CodexWorkspace>] =
            codexDefaultWorkspaceSortDescriptors()
    ) -> Self {
        Self(.workspaces(sortBy: sortDescriptors))
    }
}

extension CodexFetchRequest where Model == CodexChat {
    public static var recentChats: Self {
        Self(.recentChats)
    }

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

    public static func chats(
        in workspace: CodexWorkspace,
        sortDescriptors: [SortDescriptor<CodexChat>],
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
    -> [SortDescriptor<CodexWorkspaceGroup>]
{
    [SortDescriptor(\.name)]
}

@usableFromInline
func codexDefaultWorkspaceSortDescriptors() -> [SortDescriptor<CodexWorkspace>] {
    [SortDescriptor(\.name)]
}

@usableFromInline
func codexDefaultChatSortDescriptors() -> [SortDescriptor<CodexChat>] {
    [SortDescriptor(\.updatedAt, order: .reverse)]
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

public struct CodexFetchSection<Model: CodexPersistentModel>: Identifiable {
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

    public var workspaceGroup: CodexWorkspaceGroup? {
        codexOnlyWorkspaceGroup(items.map { $0.workspace?.workspaceGroup })
    }

    public var workspaces: [CodexWorkspace] {
        codexUniqueWorkspaces(items.compactMap(\.workspace))
    }

    public var uncategorizedChats: [CodexChat] {
        items.filter { $0.workspace == nil }
    }

    public func chats(in workspaceID: CodexWorkspaceID) -> [CodexChat] {
        items.filter { $0.workspace?.id == workspaceID }
    }

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

    public var workspaceGroup: CodexWorkspaceGroup? {
        codexOnlyWorkspaceGroup(items.map(\.workspaceGroup))
    }

    public var workspaces: [CodexWorkspace] {
        codexUniqueWorkspaces(items)
    }
}

private func codexUniqueWorkspaces(_ workspaces: [CodexWorkspace]) -> [CodexWorkspace] {
    var seen: Set<CodexWorkspaceID> = []
    var result: [CodexWorkspace] = []
    for workspace in workspaces where seen.insert(workspace.id).inserted {
        result.append(workspace)
    }
    return result
}

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

package struct CodexFetchPage<Model: CodexPersistentModel> {
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

@Observable
public final class CodexFetchedResults<Model: CodexPersistentModel> {
    public let modelContext: CodexModelContext
    public private(set) var fetchDescriptor: CodexFetchDescriptor<Model>
    package let querySignature: CodexFetchDescriptorSignature
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
        self.querySignature = fetchDescriptor.querySignature
        self.sectionBy = sectionBy
    }

    deinit {
        transactionRelay.finish()
    }

    package func makeTransactionStream()
        -> AsyncStream<CodexFetchedResultsTransaction<Model>>
    {
        transactionRelay.makeStream()
    }

    public nonisolated(nonsending) func performFetch() async throws {
        let reason: CodexFetchedResultsTransactionReason =
            hasPerformedFetch ? .refresh : .initialFetch
        try await load(fetchDescriptor, appending: false, reason: reason)
    }

    public nonisolated(nonsending) func refresh() async throws {
        try await performFetch()
    }

    public nonisolated(nonsending) func loadNextPage() async throws {
        guard let nextCursor else {
            return
        }
        try await load(
            fetchDescriptor,
            cursor: nextCursor,
            appending: true,
            reason: .pageAppend
        )
    }

    private func load(
        _ descriptor: CodexFetchDescriptor<Model>,
        cursor: String? = nil,
        appending: Bool,
        reason: CodexFetchedResultsTransactionReason
    ) async throws {
        phase = .loading
        lastErrorDescription = nil
        let previousBackwardsCursor = backwardsCursor
        do {
            let page = try await modelContext.fetchPage(
                descriptor,
                cursor: cursor,
                excluding: self
            )
            let newItems = loadedItems(from: page, appending: appending)
            let relationshipDescriptor = appending ? fetchDescriptor : descriptor
            await modelContext.syncLoadedRelationships(
                from: page,
                descriptor: relationshipDescriptor,
                loadedItems: newItems,
                cursor: cursor,
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
            return replacingItems(from: page)
        }
        if page.relationshipIsComplete == true, let authoritativeItems = page.relationshipItems {
            let start = min(
                fetchDescriptor.normalizedFetchOffset,
                authoritativeItems.count
            )
            let end = min(start + items.count + page.items.count, authoritativeItems.count)
            let windowPage = CodexFetchPage(
                items: Array(authoritativeItems[start..<end]),
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: page.relationshipItems,
                relationshipIsComplete: page.relationshipIsComplete
            )
            return modelContext.fetchedItemsIncludingPendingChanges(
                from: windowPage,
                descriptor: fetchDescriptor,
                existingItems: items
            )
        }
        return append(page.items, to: items)
    }

    private func replacingItems(from page: CodexFetchPage<Model>) -> [Model] {
        modelContext.fetchedItemsIncludingPendingChanges(
            from: page,
            descriptor: fetchDescriptor,
            existingItems: items
        )
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
        if membershipRequiresServerRefresh {
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
        if fetchDescriptor.normalizedFetchOffset > 0 {
            await refreshAfterMutation(reason: reason)
            return
        }
        if requiresServerRefreshAfterMutation {
            await refreshAfterMutation(reason: reason)
            return
        }
        guard items.count != originalCount else {
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
        if let chatModel = chat as? Model {
            return chatModel
        }
        if let workspace = chat.workspace as? Model {
            return workspace
        }
        if let workspace = chat.workspace,
            let workspaceGroup = workspace.workspaceGroup,
            let group = workspaceGroup as? Model
        {
            if workspaceGroup.workspaces.contains(where: { $0 === workspace }) == false {
                workspaceGroup.replaceContextWorkspaces(workspaceGroup.workspaces + [workspace])
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
            let cursorOffset = fetchDescriptor.normalizedFetchOffset + windowItems.count
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
            && fetchDescriptor.includePendingChanges
            && fetchDescriptor.normalizedFetchOffset == 0
            && (nextCursor == nil || fetchDescriptor.fetchLimit == nil)
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
        chatQueryPlan?.membershipRequiresServerRefresh ?? false
    }

    private var usesServerOwnedOrdering: Bool {
        chatQueryPlan?.usesServerOwnedOrdering ?? false
    }

    private var chatQueryPlan: CodexThreadQueryPlan? {
        guard Model.self == CodexChat.self else {
            return nil
        }
        return CodexThreadQueryPlan(descriptor: fetchDescriptor as! CodexFetchDescriptor<CodexChat>)
    }

    private func backfillAfterLocalRemovalIfNeeded(
        originalCount: Int,
        reason: CodexFetchedResultsTransactionReason
    ) async {
        let missingCount = originalCount - items.count
        guard missingCount > 0, shouldRefreshAfterLocalRemoval else {
            return
        }
        let backfillOffset = fetchDescriptor.normalizedFetchOffset + items.count
        var descriptor = fetchDescriptor
        descriptor.fetchLimit = missingCount
        do {
            try await load(
                descriptor,
                cursor: modelContext.backfillCursor(after: backfillOffset, currentCursor: nextCursor),
                appending: true,
                reason: reason
            )
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
            (nextCursor != nil || fetchDescriptor.normalizedFetchOffset > 0),
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
        guard let chatQueryPlan else {
            return archived == false
        }
        var record = CodexChatRecord(chat: chat)
        record.isArchived = archived
        return chatQueryPlan.matches(record)
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
        let updatedItemIDs = updatedItemIDsAfterRemoval(
            of: chat,
            workspace: workspace,
            group: group
        )
        if filteredItems.count != items.count || updatedItemIDs.isEmpty == false {
            updateItemsAndSections(
                items: filteredItems,
                sections: modelContext.sections(for: filteredItems, sectionBy: sectionBy),
                reason: reason,
                updatedItemIDs: updatedItemIDs
            )
        }
        return originalCount
    }

    private func updatedItemIDsAfterRemoval(
        of chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) -> Set<Model.ID> {
        var ids: Set<Model.ID> = []
        insertUpdatedItemID(chat, into: &ids)
        insertUpdatedItemID(workspace, into: &ids)
        insertUpdatedItemID(group, into: &ids)
        return ids
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
        _ model: (any CodexPersistentModel)?,
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
            workspace.replaceContextChats([chat] + workspace.chats)
        }
        if let group = workspace.workspaceGroup,
            group.workspaces.contains(where: { $0 === workspace }) == false
        {
            group.replaceContextWorkspaces(group.workspaces + [workspace])
        }
    }

    private func requestMatchesArchiveScope(_ archived: Bool) -> Bool {
        chatQueryPlan?.matchesArchiveScope(archived) ?? (archived == false)
    }

    private func requestIsScoped(to workspace: CodexWorkspace) -> Bool {
        guard let filterWorkspaces = chatQueryPlan?.workspaces else {
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
