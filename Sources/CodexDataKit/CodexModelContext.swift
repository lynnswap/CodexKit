import AsyncAlgorithms
import CodexAppServerKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "CodexDataKit", category: "model-context")

public enum CodexModelContextError: Error, Equatable, Sendable {
    case unsupportedModelType(String)
    case modelIsDetached
    case chatObservationAlreadyActive(CodexThreadID)
}

package struct CodexModelContextID: Hashable, Sendable {
    private let rawValue: UUID

    package init() {
        self.rawValue = UUID()
    }
}

package struct CodexStartedReviewContextChange: Sendable {
    package var snapshot: CodexThreadSnapshot
    package var eventThread: CodexThread
    package var archived: Bool
    package var provisionalSeedTurnID: CodexTurnID?

    package init(
        snapshot: CodexThreadSnapshot,
        eventThread: CodexThread,
        archived: Bool,
        provisionalSeedTurnID: CodexTurnID?
    ) {
        self.snapshot = snapshot
        self.eventThread = eventThread
        self.archived = archived
        self.provisionalSeedTurnID = provisionalSeedTurnID
    }
}

package struct CodexModelContextTransaction: Sendable {
    package var startedReviews: [CodexStartedReviewContextChange] = []

    package init(startedReviews: [CodexStartedReviewContextChange] = []) {
        self.startedReviews = startedReviews
    }

    package var isEmpty: Bool {
        startedReviews.isEmpty
    }
}

public final class CodexModelContainer: @unchecked Sendable {
    public let appServer: CodexAppServer

    @MainActor
    public var mainContext: CodexModelContext {
        if let context = _mainContext {
            return context
        }
        let context = CodexModelContext(self)
        _mainContext = context
        if pendingMainContextTransactions.isEmpty == false {
            Task { @MainActor in
                await self.deliverPendingMainContextTransactions(to: context)
            }
        }
        return context
    }

    @MainActor
    private var _mainContext: CodexModelContext?

    private struct PendingMainContextTransaction {
        var transaction: CodexModelContextTransaction
        var sourceContextID: CodexModelContextID
    }

    // Transactions multicast before the main context is materialized; replayed
    // once it exists so early actor-side changes are not dropped.
    @MainActor
    private var pendingMainContextTransactions: [PendingMainContextTransaction] = []

    public init(appServer: CodexAppServer) {
        self.appServer = appServer
    }

    public convenience init(
        configuration: CodexAppServer.Configuration = .init()
    ) async throws {
        let appServer = try await CodexAppServer(configuration: configuration)
        self.init(appServer: appServer)
    }

    @MainActor
    package func multicast(
        _ transaction: CodexModelContextTransaction,
        from sourceContextID: CodexModelContextID
    ) async {
        guard transaction.isEmpty == false else {
            return
        }
        pendingMainContextTransactions.append(.init(
            transaction: transaction,
            sourceContextID: sourceContextID
        ))
        guard let context = _mainContext else {
            return
        }
        await deliverPendingMainContextTransactions(to: context)
    }

    @MainActor
    private func deliverPendingMainContextTransactions(to context: CodexModelContext) async {
        while pendingMainContextTransactions.isEmpty == false {
            let pending = pendingMainContextTransactions.removeFirst()
            guard pending.sourceContextID != context.contextID else {
                continue
            }
            await context.merge(pending.transaction)
        }
    }
}

public final class CodexModelContext {
    private static let localCursorPrefix = "codexkit-ui-offset:"

    private struct ChatFetchedResultState: Equatable {
        var name: String?
        var preview: String?
        var modelProvider: String?
        var sourceKind: CodexThreadSourceKind?
        var isArchived: Bool
        var createdAt: Date?
        var updatedAt: Date?
        var recencyAt: Date?
        var status: CodexThreadStatus?
        var ephemeral: Bool?
        var workspaceID: CodexWorkspaceID?
        var workspaceGroupID: CodexWorkspaceGroupID?
    }

    private struct RefreshedThreadSnapshot {
        var snapshot: CodexThreadSnapshot
        var metadataReadCompleted: Bool
    }

    private final class ActiveChatObservation {
        var eventThread: CodexThread?
        var eventStream: CodexThreadEventSequence?
        var includesTurns = false
        var isFinished = false
        var isBufferingEvents = false
        var bufferedEvents: [CodexThreadEvent] = []
        let updateRelay = CodexAsyncStreamRelay<CodexChatUpdate>()
        var hasAppliedLiveUpdates = false

        func cancel() {
            isFinished = true
            eventPump?.cancel()
            discardBufferedEvents()
            updateRelay.finish()
            eventStream = nil
        }

        var eventPump: ThreadEventPump?

        func beginBufferingEvents() {
            isBufferingEvents = true
        }

        func appendBufferedEvent(_ event: CodexThreadEvent) {
            bufferedEvents.append(event)
        }

        var hasBufferedEvents: Bool {
            bufferedEvents.isEmpty == false
        }

        var shouldPreserveLiveTurnItems: Bool {
            hasAppliedLiveUpdates || hasBufferedEvents
        }

        func markAppliedLiveUpdates() {
            hasAppliedLiveUpdates = true
        }

        func finishBufferingEvents() -> [CodexThreadEvent] {
            isBufferingEvents = false
            defer {
                bufferedEvents.removeAll(keepingCapacity: true)
            }
            return bufferedEvents
        }

        func discardBufferedEvents() {
            isBufferingEvents = false
            bufferedEvents.removeAll(keepingCapacity: true)
        }

        func yield(_ updates: [CodexChatUpdate]) {
            guard updates.isEmpty == false else {
                return
            }
            for update in updates {
                updateRelay.yield(update)
            }
        }
    }

    private final class ThreadEventPump {
        private let task: Task<Void, Never>

        init(
            context: CodexModelContext,
            chatID: CodexThreadID,
            observation: ActiveChatObservation,
            stream: CodexThreadEventSequence,
            isolation: (any Actor)?
        ) {
            let target = ThreadEventPumpTarget(
                context: context,
                chatID: chatID,
                observation: observation
            )
            task = Task {
                do {
                    for try await event in stream {
                        await target.process(event, isolation: isolation)
                    }
                    await target.finish(isolation: isolation)
                } catch is CancellationError {
                    await target.discard(isolation: isolation)
                } catch {
                    await target.fail(with: error, isolation: isolation)
                }
            }
        }

        func cancel() {
            task.cancel()
        }
    }

    // The raw event stream is consumed off-actor; model mutation hops to the
    // isolation the observation was started from, which is the context owner's
    // isolation (MainActor for the main context, the model executor for
    // model-actor contexts).
    private final class ThreadEventPumpTarget: @unchecked Sendable {
        private weak var context: CodexModelContext?
        private let chatID: CodexThreadID
        private let observation: ActiveChatObservation

        init(
            context: CodexModelContext,
            chatID: CodexThreadID,
            observation: ActiveChatObservation
        ) {
            self.context = context
            self.chatID = chatID
            self.observation = observation
        }

        func process(_ event: CodexThreadEvent, isolation: isolated (any Actor)?) async {
            await context?.processObservedEvent(event, chatID: chatID, observation: observation)
        }

        func finish(isolation: isolated (any Actor)?) {
            context?.finishChatObservationIfIdle(chatID, observation: observation)
        }

        func discard(isolation: isolated (any Actor)?) {
            context?.discardChatObservation(chatID, observation: observation)
        }

        func fail(with error: Error, isolation: isolated (any Actor)?) async {
            await context?.failChatObservation(chatID, observation: observation, error: error)
        }
    }

    private struct ObservationUpdates: AsyncSequence, Sendable {
        typealias Element = CodexChatUpdate
        typealias Failure = Never

        let relay: CodexAsyncStreamRelay<CodexChatUpdate>

        func makeAsyncIterator() -> AsyncStream<CodexChatUpdate>.Iterator {
            relay.makeStream().makeAsyncIterator()
        }
    }

    public private(set) weak var container: CodexModelContainer?
    public let appServer: CodexAppServer
    package let contextID = CodexModelContextID()

    private var workspaceGroupsByID: [CodexWorkspaceGroupID: CodexWorkspaceGroup] = [:]
    private var workspacesByID: [CodexWorkspaceID: CodexWorkspace] = [:]
    private var chatsByID: [CodexThreadID: CodexChat] = [:]
    private var turnsByID: [CodexTurnID: CodexTurn] = [:]
    private var itemsByID: [CodexChatItemID: CodexItem] = [:]
    private var fetchedResults: [WeakFetchedResultsRegistration] = []
    private var activeChatObservationsByID: [CodexThreadID: ActiveChatObservation] = [:]
    private var preparedEventThreadsByID: [CodexThreadID: CodexThread] = [:]

    public init(_ container: CodexModelContainer) {
        self.container = container
        self.appServer = container.appServer
    }

    public nonisolated(nonsending) func fetch<Model: CodexPersistentModel>(
        _ descriptor: CodexFetchDescriptor<Model>
    ) async throws -> [Model] {
        let page = try await fetchPage(descriptor)
        let items = fetchedItemsIncludingPendingChanges(from: page, descriptor: descriptor)
        await syncLoadedRelationships(from: page, descriptor: descriptor, loadedItems: items)
        return items
    }

    public nonisolated(nonsending) func fetch<Model: CodexPersistentModel>(
        _ request: CodexFetchRequest<Model>
    ) async throws -> [Model] {
        try await fetch(request.fetchDescriptor)
    }

    public func fetchedResults<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>,
        sectionedBy sectionBy: CodexSectionDescriptor<Model>? = nil
    ) -> CodexFetchedResults<Model> {
        let results = CodexFetchedResults(
            modelContext: self,
            fetchDescriptor: descriptor,
            sectionBy: sectionBy
        )
        register(results)
        return results
    }

    public func fetchedResults<Model: CodexPersistentModel>(
        for request: CodexFetchRequest<Model>,
        sectionedBy sectionBy: CodexSectionDescriptor<Model>? = nil
    ) -> CodexFetchedResults<Model> {
        fetchedResults(for: request.fetchDescriptor, sectionedBy: sectionBy)
    }

    public func fetchedResultsController<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>,
        sectionedBy sectionBy: CodexSectionDescriptor<Model>? = nil
    ) -> CodexFetchedResultsController<Model> {
        CodexFetchedResultsController(
            fetchedResults: fetchedResults(for: descriptor, sectionedBy: sectionBy)
        )
    }

    public func fetchedResultsController<Model: CodexPersistentModel>(
        for request: CodexFetchRequest<Model>,
        sectionedBy sectionBy: CodexSectionDescriptor<Model>? = nil
    ) -> CodexFetchedResultsController<Model> {
        fetchedResultsController(for: request.fetchDescriptor, sectionedBy: sectionBy)
    }

    public func model(for id: CodexThreadID) -> CodexChat {
        chat(for: id)
    }

    public func registeredModel(for id: CodexThreadID) -> CodexChat? {
        chatsByID[id]
    }

    public func model(for id: CodexWorkspaceID) -> CodexWorkspace? {
        workspacesByID[id]
    }

    public func registeredModel(for id: CodexWorkspaceID) -> CodexWorkspace? {
        workspacesByID[id]
    }

    public func model(for id: CodexWorkspaceGroupID) -> CodexWorkspaceGroup? {
        workspaceGroupsByID[id]
    }

    public func registeredModel(for id: CodexWorkspaceGroupID) -> CodexWorkspaceGroup? {
        workspaceGroupsByID[id]
    }

    package func turn(
        id: CodexTurnID,
        in chat: CodexChat,
        state: CodexTurnSnapshot.State? = nil,
        itemsLoadState: CodexTurnItemsLoadState? = nil,
        usage: CodexTokenUsage? = nil
    ) -> CodexTurn {
        if let turn = turnsByID[id] {
            turn.applyContextChat(chat)
            return turn
        }
        let turn = CodexTurn(
            id: id,
            chat: chat,
            modelContext: self,
            state: state,
            itemsLoadState: itemsLoadState,
            usage: usage
        )
        turnsByID[id] = turn
        return turn
    }

    package func item(
        threadItem: CodexThreadItem,
        turnID: CodexTurnID?,
        in chat: CodexChat,
        itemsLoadState: CodexTurnItemsLoadState
    ) -> CodexItem {
        let itemTurn: CodexTurn?
        if let turnID {
            itemTurn = turn(id: turnID, in: chat)
        } else {
            itemTurn = nil
        }
        let id = CodexChatItemKey(threadItem: threadItem, turnID: turnID).modelID(in: chat.id)
        if let item = itemsByID[id] {
            item.applyContextOwners(chat: chat, turn: itemTurn)
            return item
        }
        let item = CodexItem(
            threadItem: threadItem,
            chat: chat,
            turn: itemTurn,
            modelContext: self,
            itemsLoadState: itemsLoadState
        )
        itemsByID[id] = item
        return item
    }

    package func unregisterContextItem(_ item: CodexItem) {
        itemsByID = itemsByID.filter { $0.value !== item }
    }

    package func rekeyContextItem(
        _ item: CodexItem,
        from oldID: CodexChatItemID,
        to newID: CodexChatItemID
    ) {
        if itemsByID[oldID] === item {
            itemsByID.removeValue(forKey: oldID)
        }
        itemsByID[newID] = item
    }

    public nonisolated(nonsending) func refresh(_ group: CodexWorkspaceGroup) async throws {
        guard group.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }

        let descriptor = CodexFetchDescriptor<CodexWorkspace>(
            sortBy: [SortDescriptor(\.name)]
        )
        let previousWorkspaces = group.workspaces
        let previousChats = group.workspaces.flatMap(\.chats)
        let snapshots = try await fetchAllThreadSnapshots(matching: descriptor)
        let fetchedChats = await applyFetchedSnapshots(
            snapshots,
            archived: archivedScope(for: descriptor) == true,
            scopedWorkspaceURL: singleWorkspaceScope(for: descriptor)
        )
        let fetchedChatIDs = Set(fetchedChats.map(\.id))
        let chats = fetchedChats.filter { $0.workspace?.workspaceGroup?.id == group.id }
        let workspaces = unique(chats.compactMap(\.workspace))
        for workspace in unique(previousWorkspaces + workspaces) {
            let previousWorkspaceChats = workspace.chats
            let fetchedWorkspaceChats = fetchedChats.filter { $0.workspace === workspace }
            let fetchedIDs = Set(fetchedWorkspaceChats.map(\.id))
            let preservedChats = previousWorkspaceChats.filter {
                fetchedIDs.contains($0.id) == false
                    && shouldPreserveMissingRefreshChat($0, archivedScope: archivedScope(for: descriptor))
            }
            let currentChats = fetchedWorkspaceChats + preservedChats
            workspace.replaceContextChats(currentChats)
            pruneWorkspaceIfEmpty(workspace)
            _ = detachStaleChats(
                previousWorkspaceChats,
                from: workspace,
                keeping: currentChats,
                archivedScope: archivedScope(for: descriptor)
            )
        }
        let previousWorkspacesStillInGroup = previousWorkspaces.filter {
            $0.workspaceGroup?.id == group.id
        }
        let refreshedWorkspaces = workspaces.filter { $0.workspaceGroup?.id == group.id }
        let refreshedWorkspaceIDs = Set(refreshedWorkspaces.map(\.id))
        let preservedWorkspaces = previousWorkspacesStillInGroup.filter {
            refreshedWorkspaceIDs.contains($0.id) == false
                && containsPreservedMissingRefreshChat(in: $0, archivedScope: archivedScope(for: descriptor))
        }
        group.replaceContextWorkspaces(sort(refreshedWorkspaces + preservedWorkspaces, using: descriptor.sortBy))
        let currentChatIDs = Set(group.workspaces.flatMap(\.chats).map(\.id))
        let removedChats = previousChats.filter {
            currentChatIDs.contains($0.id) == false
                && fetchedChatIDs.contains($0.id) == false
                && isInRefreshedScope($0, archivedScope: archivedScope(for: descriptor))
        }
        await refreshWorkspaceGroupInRegisteredResults(
            group,
            archived: archivedScope(for: descriptor) == true,
            removedChats: removedChats
        )
    }

    public nonisolated(nonsending) func refresh(_ workspace: CodexWorkspace) async throws {
        guard workspace.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }

        let descriptor = CodexFetchDescriptor<CodexChat>.chats(in: workspace)
        let previousChats = workspace.chats
        let snapshots = try await fetchAllThreadSnapshots(matching: descriptor)
        let fetchedChats = await applyFetchedSnapshots(
            snapshots,
            archived: archivedScope(for: descriptor) == true,
            scopedWorkspaceURL: singleWorkspaceScope(for: descriptor)
        )
        let chats = sort(
            fetchedChats,
            using: descriptor.sortBy
        )
        let refreshedIDs = Set(chats.map(\.id))
        let preservedChats = previousChats.filter {
            refreshedIDs.contains($0.id) == false
                && shouldPreserveMissingRefreshChat($0, archivedScope: archivedScope(for: descriptor))
        }
        let currentChats = chats + preservedChats
        workspace.replaceContextChats(currentChats)
        pruneWorkspaceIfEmpty(workspace)
        let removedChats = detachStaleChats(
            previousChats,
            from: workspace,
            keeping: currentChats,
            archivedScope: archivedScope(for: descriptor)
        )
        await refreshWorkspaceInRegisteredResults(
            workspace,
            archived: archivedScope(for: descriptor) == true,
            removedChats: removedChats
        )
    }

    public nonisolated(nonsending) func refresh(
        _ chat: CodexChat,
        includeTurns: Bool = true
    ) async throws {
        guard chat.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }

        chat.phase = .loading
        chat.lastErrorDescription = nil
        do {
            let thread = try await eventThread(for: chat)
            try await refresh(chat, using: thread, includeTurns: includeTurns)
        } catch {
            chat.fail(with: error)
            throw error
        }
    }

    private func refresh(
        _ chat: CodexChat,
        using thread: CodexThread,
        includeTurns: Bool,
        replaysBufferedEvents: Bool = true,
        emitsResynchronization: Bool = true
    ) async throws {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let observation = activeChatObservationsByID[chat.id]
        observation?.beginBufferingEvents()
        let refreshedSnapshot: RefreshedThreadSnapshot
        do {
            refreshedSnapshot = try await refreshedThreadSnapshot(for: thread, includeTurns: includeTurns)
        } catch {
            if replaysBufferedEvents {
                await flushBufferedEvents(from: observation, to: chat)
            } else {
                observation?.discardBufferedEvents()
            }
            throw error
        }
        let snapshot = refreshedSnapshot.snapshot
        let snapshotCanLagBehindLiveEvents = snapshotCanLagBehindLiveEvents(refreshedSnapshot)
        let chatShouldPreserveTurnItems = snapshotCanLagBehindLiveEvents
            && chat.shouldPreserveTurnItemsWhenReconcilingSnapshot
        let observationShouldPreserveTurnItems = snapshotCanLagBehindLiveEvents
            && observation?.shouldPreserveLiveTurnItems == true
        let preservesExistingTurnItems = replaysBufferedEvents
            && (chatShouldPreserveTurnItems || observationShouldPreserveTurnItems)
        if preservesExistingTurnItems {
            logger.debug(
                "Preserving live chat turn items during snapshot refresh chatID=\(chat.id.rawValue, privacy: .public) includeTurns=\(includeTurns, privacy: .public) chatHasLiveUpdates=\(chatShouldPreserveTurnItems, privacy: .public) observationHasLiveUpdates=\(observationShouldPreserveTurnItems, privacy: .public)"
            )
        }
        let refreshedChat = apply(
            snapshot,
            preservesExistingTurnItems: preservesExistingTurnItems
        )
        if includeTurns {
            refreshedChat.resetLiveMergeStateFromCurrentItems()
        }
        refreshedChat.syncPhaseAfterRefresh(includeTurns: includeTurns)
        if emitsResynchronization {
            yield([
                .resynchronized(reason: .refresh),
            ], to: observation)
        }
        if replaysBufferedEvents {
            await flushBufferedEvents(from: observation, to: refreshedChat)
        } else {
            observation?.discardBufferedEvents()
        }
        await revalidateChatInRegisteredResults(
            refreshedChat,
            previousWorkspace: previousWorkspace,
            previousGroup: previousGroup,
            archived: refreshedChat.isArchived
        )
    }

    private func snapshotCanLagBehindLiveEvents(_ refreshedSnapshot: RefreshedThreadSnapshot) -> Bool {
        guard refreshedSnapshot.metadataReadCompleted,
            refreshedSnapshot.snapshot.hasField(.status),
            let status = refreshedSnapshot.snapshot.status
        else {
            return true
        }
        switch status {
        case .active,
            .unknown:
            return true
        case .idle,
            .notLoaded,
            .systemError:
            return false
        }
    }

    private func refreshedThreadSnapshot(
        for thread: CodexThread,
        includeTurns: Bool
    ) async throws -> RefreshedThreadSnapshot {
        guard includeTurns else {
            return .init(
                snapshot: try await thread.read(includeTurns: false),
                metadataReadCompleted: true
            )
        }

        do {
            let turns = try await fullTurnList(for: thread)
            return try await threadSnapshot(
                for: thread,
                withAuthoritativeTurns: turns
            )
        } catch {
            return .init(
                snapshot: try await thread.read(includeTurns: true),
                metadataReadCompleted: true
            )
        }
    }

    private func fullTurnList(for thread: CodexThread) async throws -> [CodexTurnSnapshot] {
        var cursor: String?
        var turns: [CodexTurnSnapshot] = []
        repeat {
            let page = try await thread.listTurns(.init(
                cursor: cursor,
                sortDirection: .ascending,
                itemsLoadState: .full
            ))
            turns.append(contentsOf: page.turns)
            cursor = page.nextCursor
        } while cursor != nil
        return turns
    }

    private func threadSnapshot(
        for thread: CodexThread,
        withAuthoritativeTurns turns: [CodexTurnSnapshot]
    ) async throws -> RefreshedThreadSnapshot {
        do {
            let metadata = try await thread.read(includeTurns: false)
            var presentFields = metadata.presentFields
            presentFields.insert(.turns)
            return .init(
                snapshot: .init(
                    id: metadata.id,
                    workspace: metadata.workspace,
                    name: metadata.name,
                    preview: metadata.preview,
                    modelProvider: metadata.modelProvider,
                    sourceKind: metadata.sourceKind,
                    createdAt: metadata.createdAt,
                    updatedAt: metadata.updatedAt,
                    recencyAt: metadata.recencyAt,
                    status: metadata.status,
                    ephemeral: metadata.ephemeral,
                    turns: turns,
                    turnItemsAreAuthoritative: true,
                    presentFields: presentFields
                ),
                metadataReadCompleted: true
            )
        } catch {
            if Self.isThreadNotLoadedError(error) {
                var presentFields: Set<CodexThreadSnapshot.Field> = [.status, .turns]
                if thread.workspace != nil {
                    presentFields.insert(.workspace)
                }
                return .init(
                    snapshot: .init(
                        id: thread.id,
                        workspace: thread.workspace,
                        status: .notLoaded,
                        turns: turns,
                        turnItemsAreAuthoritative: true,
                        presentFields: presentFields
                    ),
                    metadataReadCompleted: false
                )
            }
            var presentFields: Set<CodexThreadSnapshot.Field> = [.turns]
            if thread.workspace != nil {
                presentFields.insert(.workspace)
            }
            return .init(
                snapshot: .init(
                    id: thread.id,
                    workspace: thread.workspace,
                    turns: turns,
                    turnItemsAreAuthoritative: true,
                    presentFields: presentFields
                ),
                metadataReadCompleted: false
            )
        }
    }

    private static func isThreadNotLoadedError(_ error: Error) -> Bool {
        let message: String
        if case JSONRPC.Error.responseError(let serverError) = error {
            message = serverError.message
        } else if case CodexAppServerError.request(let failure) = error,
                  case .server(let serverError) = failure.kind {
            message = serverError.message
        } else {
            return false
        }
        return message.lowercased().contains("thread not loaded")
    }

    private func flushBufferedEvents(
        from observation: ActiveChatObservation?,
        to chat: CodexChat
    ) async {
        let bufferedEvents = observation?.finishBufferingEvents() ?? []
        for event in bufferedEvents {
            let changes = await apply(event, to: chat)
            observation?.markAppliedLiveUpdates()
            yield(changes, to: observation)
        }
    }

    private func yield(
        _ updates: [CodexChatUpdate],
        to observation: ActiveChatObservation?
    ) {
        guard let observation else {
            return
        }
        observation.yield(updates)
    }

    public nonisolated(nonsending) func observe(
        _ chat: CodexChat,
        includeTurns: Bool = true
    ) async throws -> CodexChatObservation {
        guard chat.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }

        let activeObservation = try await activeObservation(
            for: chat,
            includeTurns: includeTurns
        )

        return makeChatObservation(chat: chat, activeObservation: activeObservation)
    }

    private func activeObservation(
        for chat: CodexChat,
        includeTurns: Bool,
        resumedThread: CodexThread? = nil
    ) async throws -> ActiveChatObservation {
        if let observation = activeChatObservationsByID[chat.id] {
            if observation.isFinished {
                activeChatObservationsByID.removeValue(forKey: chat.id)
            } else {
                throw CodexModelContextError.chatObservationAlreadyActive(chat.id)
            }
        }

        let chatID = chat.id
        let observation = ActiveChatObservation()
        activeChatObservationsByID[chatID] = observation
        do {
            try await self.startObservation(
                observation,
                for: chat,
                includeTurns: includeTurns,
                resumedThread: resumedThread
            )
            return observation
        } catch {
            discardChatObservation(chatID, observation: observation)
            throw error
        }
    }

    private func startObservation(
        _ observation: ActiveChatObservation,
        for chat: CodexChat,
        includeTurns: Bool,
        resumedThread: CodexThread? = nil
    ) async throws {
        chat.phase = .loading
        chat.lastErrorDescription = nil
        let thread: CodexThread
        let usesPreparedThread: Bool
        do {
            let threadSource: String
            if let resumedThread {
                thread = resumedThread
                threadSource = "resumedThread"
                usesPreparedThread = false
            } else if let preparedThread = takePreparedEventThread(for: chat.id) {
                thread = preparedThread
                threadSource = "preparedEventThread"
                usesPreparedThread = true
            } else {
                thread = try await appServer.resumeThread(chat.id)
                threadSource = "resumeThread"
                usesPreparedThread = false
            }
            logger.debug(
                "Starting chat observation chatID=\(chat.id.rawValue, privacy: .public) includeTurns=\(includeTurns, privacy: .public) source=\(threadSource, privacy: .public) turns=\(chat.turns.count, privacy: .public) items=\(chat.items.count, privacy: .public)"
            )
            observation.eventThread = thread
            try Task.checkCancellation()
            if usesPreparedThread == false {
                await startEventPump(observation, thread: thread)
            }
            do {
                try await refresh(
                    chat,
                    using: thread,
                    includeTurns: includeTurns,
                    emitsResynchronization: false
                )
            } catch {
                guard canObserveSeededSnapshotAfterInitialRefreshFailure(
                    chat,
                    usesPreparedThread: usesPreparedThread,
                    includeTurns: includeTurns
                ) else {
                    throw error
                }
                chat.syncPhaseAfterRefresh(includeTurns: includeTurns)
            }
            if usesPreparedThread {
                if shouldResetPreparedEventGenerationBeforeObserving(chat, includeTurns: includeTurns) {
                    thread.beginEventGeneration()
                }
                await startEventPump(observation, thread: thread)
            }
            try Task.checkCancellation()
            observation.includesTurns = includeTurns
        } catch {
            chat.fail(with: error)
            discardChatObservation(chat.id, observation: observation)
            throw error
        }
    }

    private func startEventPump(_ observation: ActiveChatObservation, thread: CodexThread) async {
        observation.eventStream = thread.makeCurrentGenerationEventStream()
        if let eventStream = observation.eventStream {
            observation.eventPump = ThreadEventPump(
                context: self,
                chatID: thread.id,
                observation: observation,
                stream: eventStream,
                isolation: #isolation
            )
        }
    }

    private func shouldResetPreparedEventGenerationBeforeObserving(
        _ chat: CodexChat,
        includeTurns: Bool
    ) -> Bool {
        guard includeTurns else {
            return false
        }
        if chat.phase == .loading || chat.status?.isActive == true {
            return false
        }
        return true
    }

    private func applyObservedEvent(
        _ event: CodexThreadEvent,
        to chat: CodexChat,
        observation: ActiveChatObservation
    ) async -> [CodexChatUpdate] {
        if observation.isBufferingEvents {
            observation.appendBufferedEvent(event)
            return []
        }
        let changes = await apply(event, to: chat)
        observation.markAppliedLiveUpdates()
        return changes
    }

    private func processObservedEvent(
        _ event: CodexThreadEvent,
        chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) async {
        guard observation.isFinished == false else {
            return
        }
        guard let chat = registeredModel(for: chatID) else {
            finishChatObservationIfIdle(chatID, observation: observation)
            return
        }
        let changes = await applyObservedEvent(event, to: chat, observation: observation)
        yield(changes, to: observation)
    }

    private func failChatObservation(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation,
        error: Error
    ) async {
        if let chat = registeredModel(for: chatID) {
            chat.fail(with: error)
            yield([.phaseChanged(chat.phase)], to: observation)
        }
        finishChatObservationIfIdle(chatID, observation: observation)
    }

    private func canObserveSeededSnapshotAfterInitialRefreshFailure(
        _ chat: CodexChat,
        usesPreparedThread: Bool,
        includeTurns: Bool
    ) -> Bool {
        includeTurns
            && usesPreparedThread
            && chat.turns.isEmpty == false
    }

    private func releaseChatObservation(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) {
        guard activeChatObservationsByID[chatID] === observation else {
            return
        }
        observation.cancel()
        activeChatObservationsByID.removeValue(forKey: chatID)
    }

    private func finishChatObservationIfIdle(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) {
        guard activeChatObservationsByID[chatID] === observation else {
            return
        }
        observation.isFinished = true
        observation.updateRelay.finish()
        activeChatObservationsByID.removeValue(forKey: chatID)
    }

    private func discardChatObservation(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) {
        guard activeChatObservationsByID[chatID] === observation else {
            return
        }
        observation.cancel()
        activeChatObservationsByID.removeValue(forKey: chatID)
    }

    private func makeChatObservation(
        chat: CodexChat,
        activeObservation: ActiveChatObservation
    ) -> CodexChatObservation {
        let chatID = chat.id
        let updates: CodexChatUpdates = ObservationUpdates(relay: activeObservation.updateRelay)
        return CodexChatObservation(chat: chat, updates: updates) {
            [weak self, weak activeObservation] in
            guard let activeObservation else {
                return
            }
            self?.releaseChatObservation(chatID, observation: activeObservation)
        }
    }

    private func prepareEventThread(_ thread: CodexThread, for chatID: CodexThreadID) {
        if let observation = activeChatObservationsByID[chatID],
            observation.isFinished == false
        {
            observation.eventThread = observation.eventThread ?? thread
            preparedEventThreadsByID.removeValue(forKey: chatID)
        } else {
            preparedEventThreadsByID[chatID] = thread
        }
    }

    private func preparedEventThread(for chatID: CodexThreadID) -> CodexThread? {
        preparedEventThreadsByID[chatID]
    }

    private func takePreparedEventThread(for chatID: CodexThreadID) -> CodexThread? {
        preparedEventThreadsByID.removeValue(forKey: chatID)
    }

    private func eventThread(for chat: CodexChat) async throws -> CodexThread {
        guard chat.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }
        if let thread = activeChatObservationsByID[chat.id]?.eventThread {
            return thread
        }
        if let thread = takePreparedEventThread(for: chat.id) {
            return thread
        }
        let thread = try await appServer.resumeThread(chat.id)
        return thread
    }

    @discardableResult
    public nonisolated(nonsending) func startChat(
        in workspace: CodexWorkspace,
        input: CodexChatInput = .init()
    ) async throws -> CodexChat {
        guard workspace.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }
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
            sourceKind: .appServer,
            createdAt: now,
            updatedAt: now,
            ephemeral: input.options.ephemeral
        )
        let chat = apply(snapshot)
        chat.preserveSeededMetadataUntilAuthoritativeSnapshot()
        chat.applyContextArchived(false)
        prepareEventThread(thread, for: chat.id)
        workspace.moveContextChatToFront(chat)
        await insertChatIntoRegisteredResults(chat, archived: false)
        return chat
    }

    @discardableResult
    public nonisolated(nonsending) func startReview(
        in workspace: URL,
        input: CodexReviewInput
    ) async throws -> CodexStartedReview {
        let review = try await appServer.startReview(
            in: workspace,
            target: input.target,
            instructions: input.instructions,
            options: input.options,
            delivery: input.delivery
        )
        return await applyStartedReview(
            review,
            workspaceURL: workspace,
            input: input
        )
    }

    @discardableResult
    public nonisolated(nonsending) func startReview(
        in workspace: CodexWorkspace,
        input: CodexReviewInput
    ) async throws -> CodexStartedReview {
        guard workspace.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await startReview(in: workspace.url, input: input)
    }

    private func applyStartedReview(
        _ review: CodexReviewSession,
        workspaceURL: URL,
        input: CodexReviewInput
    ) async -> CodexStartedReview {
        let eventThread = await appServer.reviewEventThread(
            for: review,
            workspace: workspaceURL
        )
        let isExistingChat = chatsByID[review.activeTurnThreadID] != nil
        let now = Date()
        let change = CodexStartedReviewContextChange(
            snapshot: CodexThreadSnapshot(
                id: review.activeTurnThreadID,
                workspace: eventThread.workspace ?? workspaceURL,
                preview: input.target.dataKitPreview,
                modelProvider: input.options.modelProvider,
                sourceKind: .subAgentReview,
                createdAt: now,
                updatedAt: now,
                recencyAt: now,
                status: .active(activeFlags: []),
                ephemeral: input.options.ephemeral,
                turns: [review.initialTurn],
                turnItemsAreAuthoritative: false
            ),
            eventThread: eventThread,
            archived: false,
            provisionalSeedTurnID: review.initialTurn.id
        )
        let chat = await applyStartedReview(change)
        if let container {
            await container.multicast(
                CodexModelContextTransaction(startedReviews: [change]),
                from: contextID
            )
        }
        logger.debug(
            "Started review chat chatID=\(chat.id.rawValue, privacy: .public) reusedExistingChat=\(isExistingChat, privacy: .public) initialTurns=\(chat.turns.count, privacy: .public) initialItems=\(chat.items.count, privacy: .public)"
        )
        return CodexStartedReview(chat: chat, session: review)
    }

    @discardableResult
    private func applyStartedReview(_ change: CodexStartedReviewContextChange) async -> CodexChat {
        let chat = apply(change.snapshot)
        chat.preserveSeededMetadataUntilAuthoritativeSnapshot()
        if let provisionalSeedTurnID = change.provisionalSeedTurnID {
            chat.markProvisionalSeedTurn(provisionalSeedTurnID)
        }
        chat.applyContextArchived(change.archived)
        chat.syncPhaseAfterRefresh(includeTurns: change.snapshot.hasField(.turns))
        prepareEventThread(change.eventThread, for: chat.id)
        chat.workspace?.moveContextChatToFront(chat)
        await insertChatIntoRegisteredResults(chat, archived: change.archived)
        return chat
    }

    package func merge(_ transaction: CodexModelContextTransaction) async {
        for change in transaction.startedReviews {
            await applyStartedReview(change)
        }
    }

    @discardableResult
    public nonisolated(nonsending) func send(
        _ input: CodexChatMessageInput,
        in chat: CodexChat
    ) async throws -> CodexTurnOutcome {
        let thread = try await eventThread(for: chat)
        let response = try await thread.respond(to: input.prompt, options: input.options)
        await apply(response, to: chat)
        return response
    }

    @discardableResult
    package func apply(_ outcome: CodexTurnOutcome, to chat: CodexChat) async -> [CodexChatUpdate] {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let previousUpdatedAt = chat.updatedAt
        let changes = chat.apply(outcome)
        if let workspace = chat.workspace,
            let updatedAt = chat.updatedAt,
            previousUpdatedAt.map({ updatedAt > $0 }) ?? true
        {
            workspace.moveContextChatToFront(chat)
        }
        await revalidateChatInRegisteredResults(
            chat,
            previousWorkspace: previousWorkspace,
            previousGroup: previousGroup,
            archived: chat.isArchived
        )
        let observation = activeChatObservationsByID[chat.id]
        observation?.markAppliedLiveUpdates()
        yield(changes, to: observation)
        return changes
    }

    package func syncPhaseAfterSend(in chat: CodexChat) async {
        guard let change = chat.syncPhaseWithTurnsAfterRefresh() else {
            return
        }
        yield([change], to: activeChatObservationsByID[chat.id])
    }

    @discardableResult
    package func apply(_ event: CodexThreadEvent, to chat: CodexChat) async -> [CodexChatUpdate] {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let previousState = fetchedResultState(for: chat)
        let previousUpdatedAt = chat.updatedAt
        let changes = chat.apply(event)
        if let workspace = chat.workspace,
            let updatedAt = chat.updatedAt,
            previousUpdatedAt.map({ updatedAt > $0 }) ?? true
        {
            workspace.moveContextChatToFront(chat)
        }
        if previousState != fetchedResultState(for: chat) {
            await revalidateChatInRegisteredResults(
                chat,
                previousWorkspace: previousWorkspace,
                previousGroup: previousGroup,
                archived: chat.isArchived
            )
        }
        return changes
    }

    public nonisolated(nonsending) func cancelActiveTurn(in chat: CodexChat) async throws {
        let thread = try await eventThread(for: chat)
        _ = try await thread.cancelActiveTurn()
    }

    public nonisolated(nonsending) func archive(_ chat: CodexChat) async throws {
        try await appServer.archiveThread(chat.id)
        let workspace = chat.workspace
        let group = workspace?.workspaceGroup
        preparedEventThreadsByID.removeValue(forKey: chat.id)
        if let workspace {
            detach(chat, from: workspace)
        }
        chat.applyContextArchived(true)
        await archiveChatInRegisteredResults(chat, workspace: workspace, group: group)
    }

    public nonisolated(nonsending) func unarchive(_ chat: CodexChat) async throws {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        var snapshot = try await appServer.unarchiveThreadSnapshot(chat.id)
        if snapshot.hasField(.workspace) == false,
            let previousWorkspace
        {
            snapshot = snapshotForApply(snapshot, scopedWorkspaceURL: previousWorkspace.url)
        }
        let restoredChat = apply(snapshot, archived: false)
        await revalidateChatInRegisteredResults(
            restoredChat,
            previousWorkspace: previousWorkspace,
            previousGroup: previousGroup,
            archived: false
        )
    }

    public nonisolated(nonsending) func delete(_ chat: CodexChat) async throws {
        try await appServer.deleteThread(chat.id)
        await remove(chat)
    }

    package func fetchPage<Model: CodexPersistentModel>(
        _ descriptor: CodexFetchDescriptor<Model>,
        cursor: String? = nil,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> CodexFetchPage<Model> {
        if Model.self == CodexChat.self {
            let page = try await fetchChatPage(
                descriptor as! CodexFetchDescriptor<CodexChat>,
                cursor: cursor,
                excluding: excludedRegistration
            )
            return CodexFetchPage(
                items: page.items.map { $0 as! Model },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: page.relationshipItems?.map { $0 as! Model },
                relationshipIsComplete: page.relationshipIsComplete
            )
        }
        if Model.self == CodexWorkspace.self {
            let page = try await fetchWorkspacePage(
                descriptor as! CodexFetchDescriptor<CodexWorkspace>,
                cursor: cursor,
                excluding: excludedRegistration
            )
            return CodexFetchPage(
                items: page.items.map { $0 as! Model },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: page.relationshipItems?.map { $0 as! Model },
                relationshipIsComplete: page.relationshipIsComplete
            )
        }
        if Model.self == CodexWorkspaceGroup.self {
            let page = try await fetchWorkspaceGroupPage(
                descriptor as! CodexFetchDescriptor<CodexWorkspaceGroup>,
                cursor: cursor,
                excluding: excludedRegistration
            )
            return CodexFetchPage(
                items: page.items.map { $0 as! Model },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: page.relationshipItems?.map { $0 as! Model },
                relationshipIsComplete: page.relationshipIsComplete
            )
        }
        throw CodexModelContextError.unsupportedModelType(String(describing: Model.self))
    }

    package func sections<Model: CodexPersistentModel>(
        for items: [Model],
        sectionBy: CodexSectionDescriptor<Model>?
    ) -> [CodexFetchSection<Model>] {
        guard items.isEmpty == false else {
            return []
        }
        guard let sectionBy else {
            return [CodexFetchSection(id: .default, title: nil, items: items)]
        }

        var grouped: [(id: CodexFetchSectionID, title: String, items: [Model])] = []
        for item in items {
            let section = sectionIdentity(for: item, descriptor: sectionBy)
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

    package func sortedItems<Model: CodexPersistentModel>(
        _ items: [Model],
        for descriptor: CodexFetchDescriptor<Model>
    ) -> [Model] {
        if Model.self == CodexChat.self {
            let descriptor = descriptor as! CodexFetchDescriptor<CodexChat>
            return sort(items as! [CodexChat], using: descriptor.sortBy).map { $0 as! Model }
        }
        if Model.self == CodexWorkspace.self {
            let descriptor = descriptor as! CodexFetchDescriptor<CodexWorkspace>
            return sort(items as! [CodexWorkspace], using: descriptor.sortBy).map {
                $0 as! Model
            }
        }
        if Model.self == CodexWorkspaceGroup.self {
            let descriptor = descriptor as! CodexFetchDescriptor<CodexWorkspaceGroup>
            return sort(items as! [CodexWorkspaceGroup], using: descriptor.sortBy).map {
                $0 as! Model
            }
        }
        return items
    }

    package func fetchedItemsIncludingPendingChanges<Model: CodexPersistentModel>(
        from page: CodexFetchPage<Model>,
        descriptor: CodexFetchDescriptor<Model>,
        existingItems: [Model] = []
    ) -> [Model] {
        guard Model.self == CodexChat.self else {
            return page.items
        }
        let preservedChats = preservedLiveChats(
            omittedFrom: page.items,
            descriptor: descriptor
        )
        guard preservedChats.isEmpty == false else {
            return page.items
        }
        logger.debug(
            "Keeping live chats omitted from fetched page preservedCount=\(preservedChats.count, privacy: .public) pageCount=\(page.items.count, privacy: .public)"
        )
        let chatDescriptor = descriptor as! CodexFetchDescriptor<CodexChat>
        let mergedChats = mergePreservedLiveChats(
            preservedChats,
            into: page.items as! [CodexChat],
            existingChats: existingItems as? [CodexChat] ?? [],
            descriptor: chatDescriptor
        )
        return mergedChats.map { $0 as! Model }
    }

    private func mergePreservedLiveChats(
        _ preservedChats: [CodexChat],
        into pageChats: [CodexChat],
        existingChats: [CodexChat],
        descriptor: CodexFetchDescriptor<CodexChat>
    ) -> [CodexChat] {
        var result = pageChats
        let existingIndexes = Dictionary(
            uniqueKeysWithValues: existingChats.enumerated().map { ($0.element.id, $0.offset) }
        )
        let orderedPreservedChats = preservedChats.sorted { lhs, rhs in
            switch (existingIndexes[lhs.id], existingIndexes[rhs.id]) {
            case (.some(let lhsIndex), .some(let rhsIndex)):
                return lhsIndex < rhsIndex
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return liveChatShouldSortBefore(lhs, rhs, descriptor: descriptor)
            }
        }
        for chat in orderedPreservedChats {
            let insertionIndex = min(
                existingIndexes[chat.id]
                    ?? liveChatInsertionIndex(for: chat, in: result, descriptor: descriptor),
                result.count
            )
            result.insert(chat, at: insertionIndex)
        }
        return result
    }

    private func liveChatInsertionIndex(
        for chat: CodexChat,
        in chats: [CodexChat],
        descriptor: CodexFetchDescriptor<CodexChat>
    ) -> Int {
        chats.firstIndex { existing in
            liveChatShouldSortBefore(chat, existing, descriptor: descriptor)
        } ?? chats.count
    }

    private func liveChatShouldSortBefore(
        _ lhs: CodexChat,
        _ rhs: CodexChat,
        descriptor: CodexFetchDescriptor<CodexChat>
    ) -> Bool {
        guard let sortDescriptor = descriptor.sortBy.first else {
            return compare(lhs.recencyAt, rhs.recencyAt, order: .reverse)
        }
        return sortDescriptor.compare(lhs, rhs) == .orderedAscending
    }

    private func compare<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        order: SortOrder
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            order == .forward ? lhs < rhs : lhs > rhs
        case (.some, .none):
            true
        case (.none, .some):
            false
        case (.none, .none):
            false
        }
    }

    package func backfillCursor(after itemCount: Int, currentCursor: String?) -> String? {
        guard currentCursor?.hasPrefix(Self.localCursorPrefix) == true else {
            return currentCursor
        }
        return localCursor(for: itemCount)
    }

    private func fetchChatPage(
        _ descriptor: CodexFetchDescriptor<CodexChat>,
        cursor: String?,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws
        -> CodexFetchPage<CodexChat>
    {
        let plan = CodexThreadQueryPlan(descriptor: descriptor)
        if canUseServerOrderedPages(for: descriptor, cursor: cursor) == false {
            let fetchedChats = filter(
                try await fetchAllChats(
                    matching: descriptor,
                    plan: plan,
                    excluding: excludedRegistration
                ),
                using: plan
            )
            let chats = sort(
                fetchedChats,
                using: descriptor.sortBy
            )
            let page = localPage(chats, for: descriptor, cursor: cursor)
            return CodexFetchPage(
                items: page.items,
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: chats,
                relationshipIsComplete: true
            )
        }

        let page = try await appServer.listThreads(plan.threadQuery(cursor: cursor, includePaging: true))
        let fetchedChats = filter(
            await applyFetchedSnapshots(
                page.threads,
                archived: plan.archived == true,
                scopedWorkspaceURL: plan.singleWorkspace,
                excluding: excludedRegistration
            ),
            using: plan
        )
        let chats = sort(
            fetchedChats,
            using: descriptor.sortBy
        )
        return CodexFetchPage(
            items: chats,
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    private func fetchAllChats(
        matching descriptor: CodexFetchDescriptor<CodexChat>,
        plan: CodexThreadQueryPlan,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> [CodexChat] {
        var chats: [CodexChat] = []
        for archived in plan.archiveScopes {
            chats.append(contentsOf: await applyFetchedSnapshots(
                try await fetchAllThreadSnapshots(
                    matching: descriptor,
                    archived: archived
                ),
                archived: archived,
                scopedWorkspaceURL: plan.singleWorkspace,
                excluding: excludedRegistration
            ))
        }
        return unique(chats)
    }

    private func fetchWorkspacePage(
        _ descriptor: CodexFetchDescriptor<CodexWorkspace>,
        cursor: String?,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> CodexFetchPage<CodexWorkspace> {
        let chats = await applyFetchedSnapshots(
            try await fetchAllThreadSnapshots(matching: descriptor),
            archived: archivedScope(for: descriptor) == true,
            scopedWorkspaceURL: singleWorkspaceScope(for: descriptor),
            excluding: excludedRegistration
        )
        let relationshipChats = chats + preservedLiveChatsForFetchedRelationships(
            omittedFrom: chats,
            descriptor: descriptor,
            requiresIncludePendingChanges: true
        )
        let removedChats = syncWorkspaceChats(
            chats,
            preservingExisting: shouldPreserveExistingWorkspaceChats(
                for: descriptor,
                relationshipIsComplete: true
            ),
            workspaceFilters: workspaceFilters(for: descriptor),
            archivedScope: archivedScope(for: descriptor)
        )
        await removeChatsFromRegisteredResults(removedChats, excluding: excludedRegistration)
        let workspaces = unique(relationshipChats.compactMap(\.workspace))
        let sortedWorkspaces = sort(workspaces, using: descriptor.sortBy)
        let page = localPage(sortedWorkspaces, for: descriptor, cursor: cursor)
        return CodexFetchPage(
            items: page.items,
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor,
            relationshipItems: sortedWorkspaces,
            relationshipIsComplete: true
        )
    }

    private func fetchWorkspaceGroupPage(
        _ descriptor: CodexFetchDescriptor<CodexWorkspaceGroup>,
        cursor: String?,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> CodexFetchPage<CodexWorkspaceGroup> {
        let chats = await applyFetchedSnapshots(
            try await fetchAllThreadSnapshots(matching: descriptor),
            archived: archivedScope(for: descriptor) == true,
            scopedWorkspaceURL: singleWorkspaceScope(for: descriptor),
            excluding: excludedRegistration
        )
        let relationshipChats = chats + preservedLiveChatsForFetchedRelationships(
            omittedFrom: chats,
            descriptor: descriptor,
            requiresIncludePendingChanges: true
        )
        let preservingGroupWorkspaces = workspaceFilters(for: descriptor) != nil
            || shouldPreserveExistingWorkspaceChats(
                for: descriptor,
                relationshipIsComplete: true
            )
        let removedChats = syncWorkspaceChats(
            chats,
            preservingExisting: shouldPreserveExistingWorkspaceChats(
                for: descriptor,
                relationshipIsComplete: true
            ),
            workspaceFilters: workspaceFilters(for: descriptor),
            archivedScope: archivedScope(for: descriptor)
        )
        await removeChatsFromRegisteredResults(removedChats, excluding: excludedRegistration)
        let workspaces = unique(relationshipChats.compactMap(\.workspace))
        syncGroupWorkspaces(
            workspaces,
            preservingExisting: preservingGroupWorkspaces,
            archivedScope: archivedScope(for: descriptor)
        )
        let groups = unique(workspaces.compactMap(\.workspaceGroup))
        let sortedGroups = sort(groups, using: descriptor.sortBy)
        let page = localPage(sortedGroups, for: descriptor, cursor: cursor)
        return CodexFetchPage(
            items: page.items,
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor,
            relationshipItems: sortedGroups,
            relationshipIsComplete: true
        )
    }

    private func applyFetchedSnapshots(
        _ snapshots: [CodexThreadSnapshot],
        archived: Bool,
        scopedWorkspaceURL: URL? = nil,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async -> [CodexChat] {
        var revalidations: [CodexFetchedChatRevalidation] = []
        let chats = snapshots.map { snapshot in
            let snapshot = snapshotForApply(snapshot, scopedWorkspaceURL: scopedWorkspaceURL)
            let existingChat = chatsByID[snapshot.id]
            let previousState = existingChat.map(fetchedResultState(for:))
            let previousWorkspace = existingChat?.workspace
            let previousGroup = previousWorkspace?.workspaceGroup
            let chat = apply(snapshot, archived: archived)
            if previousState == nil || previousState != fetchedResultState(for: chat) {
                revalidations.append(CodexFetchedChatRevalidation(
                    chat: chat,
                    previousWorkspace: previousWorkspace,
                    previousGroup: previousGroup,
                    archived: chat.isArchived
                ))
            }
            return chat
        }
        await revalidateChatsInRegisteredResults(revalidations, excluding: excludedRegistration)
        return chats
    }

    private func snapshotForApply(
        _ snapshot: CodexThreadSnapshot,
        scopedWorkspaceURL: URL?
    ) -> CodexThreadSnapshot {
        guard let scopedWorkspaceURL, snapshot.hasField(.workspace) == false else {
            return snapshot
        }
        var presentFields = snapshot.presentFields
        presentFields.insert(.workspace)
        return CodexThreadSnapshot(
            id: snapshot.id,
            workspace: scopedWorkspaceURL,
            name: snapshot.name,
            preview: snapshot.preview,
            modelProvider: snapshot.modelProvider,
            sourceKind: snapshot.sourceKind,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            recencyAt: snapshot.recencyAt,
            status: snapshot.status,
            ephemeral: snapshot.ephemeral,
            turns: snapshot.turns,
            turnItemsAreAuthoritative: snapshot.turnItemsAreAuthoritative,
            presentFields: presentFields
        )
    }

    private func fetchedResultState(for chat: CodexChat) -> ChatFetchedResultState {
        ChatFetchedResultState(
            name: chat.name,
            preview: chat.preview,
            modelProvider: chat.modelProvider,
            sourceKind: chat.sourceKind,
            isArchived: chat.isArchived,
            createdAt: chat.createdAt,
            updatedAt: chat.updatedAt,
            recencyAt: chat.recencyAt,
            status: chat.status,
            ephemeral: chat.ephemeral,
            workspaceID: chat.workspace?.id,
            workspaceGroupID: chat.workspace?.workspaceGroup?.id
        )
    }

    @discardableResult
    private func apply(
        _ snapshot: CodexThreadSnapshot,
        archived: Bool? = nil,
        preservesExistingTurnItems: Bool = false
    ) -> CodexChat {
        let chat = chat(for: snapshot.id)
        let workspace: CodexWorkspace?
        if snapshot.hasField(.workspace) {
            workspace = snapshot.workspace.map(workspace(for:))
            if let previousWorkspace = chat.workspace {
                let movedToDifferentWorkspace = workspace.map { $0 !== previousWorkspace } ?? true
                if movedToDifferentWorkspace {
                    detach(chat, from: previousWorkspace)
                }
            }
        } else {
            workspace = chat.workspace
        }
        chat.apply(
            snapshot,
            workspace: workspace,
            preservesExistingTurnItems: preservesExistingTurnItems
        )
        if let archived {
            chat.applyContextArchived(archived)
        }
        workspace?.attachContextChatIfNeeded(chat)
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
            if let previousGroup = workspace.workspaceGroup,
                previousGroup !== group
            {
                previousGroup.replaceContextWorkspaces(previousGroup.workspaces.filter { $0 !== workspace })
            }
            workspace.applyContextSnapshot(url: standardizedURL, name: name, workspaceGroup: group)
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
            group.replaceContextWorkspaces(sort(
                group.workspaces + [workspace],
                using: [SortDescriptor(\.name)]
            ))
        }
        return workspace
    }

    private func workspaceGroup(for identity: CodexWorkspaceGroupIdentity) -> CodexWorkspaceGroup {
        if let group = workspaceGroupsByID[identity.id] {
            group.applyContextSnapshot(name: identity.title)
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

    private func remove(_ chat: CodexChat) async {
        let workspace = chat.workspace
        let group = workspace?.workspaceGroup
        if let observation = activeChatObservationsByID[chat.id] {
            discardChatObservation(chat.id, observation: observation)
        }
        preparedEventThreadsByID.removeValue(forKey: chat.id)
        chatsByID.removeValue(forKey: chat.id)
        turnsByID = turnsByID.filter { $0.value.chat !== chat }
        itemsByID = itemsByID.filter { $0.value.chat !== chat }
        if let workspace {
            detach(chat, from: workspace)
        }
        chat.detachFromContext()
        await removeChatFromRegisteredResults(chat, workspace: workspace, group: group)
    }

    package func syncLoadedRelationships<Model: CodexPersistentModel>(
        from page: CodexFetchPage<Model>,
        descriptor: CodexFetchDescriptor<Model>,
        loadedItems: [Model]? = nil,
        cursor: String? = nil,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        var relationshipItems = page.relationshipItems ?? loadedItems ?? page.items
        if Model.self == CodexChat.self {
            let preserved = relationshipPreservedLiveChats(
                omittedFrom: relationshipItems,
                descriptor: descriptor
            )
            if preserved.isEmpty == false {
                relationshipItems.append(contentsOf: preserved.map { $0 as! Model })
            }
        }
        let relationshipIsComplete = page.relationshipIsComplete
            ?? (page.nextCursor == nil && descriptor.normalizedFetchOffset == 0)
        await syncLoadedRelationships(
            relationshipItems,
            descriptor: descriptor,
            relationshipIsComplete: relationshipIsComplete,
            excluding: excludedRegistration
        )
    }

    private func syncLoadedRelationships<Model: CodexPersistentModel>(
        _ items: [Model],
        descriptor: CodexFetchDescriptor<Model>,
        relationshipIsComplete: Bool,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        if let chats = items as? [CodexChat] {
            let preservingExisting = shouldPreserveExistingWorkspaceChats(
                for: descriptor,
                relationshipIsComplete: relationshipIsComplete
            )
            let removedChats = syncWorkspaceChats(
                chats,
                preservingExisting: preservingExisting,
                workspaceFilters: workspaceFilters(for: descriptor),
                archivedScope: archivedScope(for: descriptor)
            )
            await removeChatsFromRegisteredResults(removedChats, excluding: excludedRegistration)
        }
    }

    private func syncWorkspaceChats(
        _ chats: [CodexChat],
        preservingExisting: Bool,
        workspaceFilters: [URL]?,
        archivedScope: Bool?
    ) -> [(chat: CodexChat, workspace: CodexWorkspace, group: CodexWorkspaceGroup?)] {
        var removedChats: [(
            chat: CodexChat,
            workspace: CodexWorkspace,
            group: CodexWorkspaceGroup?
        )] = []
        let fetchedWorkspaces = unique(chats.compactMap(\.workspace))
        let workspaces: [CodexWorkspace]
        if preservingExisting {
            workspaces = fetchedWorkspaces
        } else if let workspaceFilters {
            let filteredWorkspaces = workspaceFilters.compactMap(workspaceIfLoaded(for:))
            workspaces = unique(filteredWorkspaces + fetchedWorkspaces)
        } else {
            workspaces = Array(workspacesByID.values)
        }
        for workspace in workspaces {
            let previousChats = workspace.chats
            let fetchedChats = chats.filter { $0.workspace === workspace }
            if preservingExisting {
                let fetchedIDs = Set(fetchedChats.map(\.id))
                let remainingChats = workspace.chats.filter { fetchedIDs.contains($0.id) == false }
                workspace.replaceContextChats(fetchedChats + remainingChats)
            } else {
                let fetchedIDs = Set(fetchedChats.map(\.id))
                let preservedChats = workspace.chats.filter {
                    fetchedIDs.contains($0.id) == false
                        && shouldPreserveMissingRefreshChat($0, archivedScope: archivedScope)
                }
                let currentChats = fetchedChats + preservedChats
                workspace.replaceContextChats(currentChats)
                let staleChats = detachStaleChats(
                    previousChats,
                    from: workspace,
                    keeping: currentChats,
                    archivedScope: archivedScope
                )
                let group = workspace.workspaceGroup
                if staleChats.isEmpty == false {
                }
                removedChats.append(contentsOf: staleChats.map {
                    (chat: $0, workspace: workspace, group: group)
                })
                pruneWorkspaceIfEmpty(workspace)
            }
        }
        return removedChats
    }

    private func shouldPreserve(_ chat: CodexChat, outside archivedScope: Bool?) -> Bool {
        switch archivedScope {
        case .some(true):
            chat.isArchived == false
        case .some(false), .none:
            chat.isArchived
        }
    }

    private func isInRefreshedScope(_ chat: CodexChat, archivedScope: Bool?) -> Bool {
        switch archivedScope {
        case .some(true):
            chat.isArchived
        case .some(false), .none:
            chat.isArchived == false
        }
    }

    private func shouldPreserveMissingRefreshChat(_ chat: CodexChat, archivedScope: Bool?) -> Bool {
        shouldPreserve(chat, outside: archivedScope) || shouldPreserveLiveFetchedChat(chat)
    }

    private func containsPreservedMissingRefreshChat(
        in workspace: CodexWorkspace,
        archivedScope: Bool?
    ) -> Bool {
        workspace.chats.contains {
            shouldPreserveMissingRefreshChat($0, archivedScope: archivedScope)
        }
    }

    private func syncGroupWorkspaces(
        _ workspaces: [CodexWorkspace],
        preservingExisting: Bool,
        archivedScope: Bool?
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
                group.replaceContextWorkspaces(sort(
                    fetchedWorkspaces + remainingWorkspaces,
                    using: [SortDescriptor(\.name)]
                ))
            } else {
                let fetchedIDs = Set(fetchedWorkspaces.map(\.id))
                let preservedWorkspaces = group.workspaces.filter {
                    fetchedIDs.contains($0.id) == false
                        && containsPreservedMissingRefreshChat(in: $0, archivedScope: archivedScope)
                }
                group.replaceContextWorkspaces(sort(
                    fetchedWorkspaces + preservedWorkspaces,
                    using: [SortDescriptor(\.name)]
                ))
            }
        }
    }

    private func detach(_ chat: CodexChat, from workspace: CodexWorkspace) {
        workspace.replaceContextChats(workspace.chats.filter { $0 !== chat })
        pruneWorkspaceIfEmpty(workspace)
    }

    private func detachStaleChats(
        _ previousChats: [CodexChat],
        from workspace: CodexWorkspace,
        keeping refreshedChats: [CodexChat],
        archivedScope: Bool?
    ) -> [CodexChat] {
        let refreshedIDs = Set(refreshedChats.map(\.id))
        let staleChats = previousChats.filter {
            refreshedIDs.contains($0.id) == false
                && isInRefreshedScope($0, archivedScope: archivedScope)
                && shouldPreserveLiveFetchedChat($0) == false
        }
        for chat in staleChats {
            chat.detachFromWorkspace(workspace)
        }
        return staleChats
    }

    private func pruneWorkspaceIfEmpty(_ workspace: CodexWorkspace) {
        guard workspace.chats.isEmpty, let group = workspace.workspaceGroup else {
            return
        }
        group.replaceContextWorkspaces(group.workspaces.filter { $0 !== workspace })
    }

    private func shouldPreserveExistingWorkspaceChats<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>,
        relationshipIsComplete: Bool
    ) -> Bool {
        let plan = chatQueryPlan(for: descriptor)
        return (Model.self == CodexChat.self
            && relationshipIsComplete == false)
            || plan?.membershipRequiresServerRefresh == true
    }

    package func preservedLiveChats<Model: CodexPersistentModel>(
        omittedFrom loadedItems: [Model],
        descriptor: CodexFetchDescriptor<Model>
    ) -> [CodexChat] {
        preservedLiveChats(
            omittedFrom: loadedItems,
            descriptor: descriptor,
            requiresIncludePendingChanges: true
        )
    }

    private func relationshipPreservedLiveChats<Model: CodexPersistentModel>(
        omittedFrom loadedItems: [Model],
        descriptor: CodexFetchDescriptor<Model>
    ) -> [CodexChat] {
        preservedLiveChats(
            omittedFrom: loadedItems,
            descriptor: descriptor,
            requiresIncludePendingChanges: false
        )
    }

    private func preservedLiveChats<Model: CodexPersistentModel>(
        omittedFrom loadedItems: [Model],
        descriptor: CodexFetchDescriptor<Model>,
        requiresIncludePendingChanges: Bool
    ) -> [CodexChat] {
        guard Model.self == CodexChat.self,
            canPreserveLiveChats(
                for: descriptor,
                requiresIncludePendingChanges: requiresIncludePendingChanges
            )
        else {
            return []
        }
        return preservedLiveChatsForFetchedRelationships(
            omittedFrom: loadedItems as? [CodexChat] ?? [],
            descriptor: descriptor,
            requiresIncludePendingChanges: requiresIncludePendingChanges
        )
    }

    private func preservedLiveChatsForFetchedRelationships<Model: CodexPersistentModel>(
        omittedFrom loadedChats: [CodexChat],
        descriptor: CodexFetchDescriptor<Model>,
        requiresIncludePendingChanges: Bool
    ) -> [CodexChat] {
        guard canPreserveLiveChats(
            for: descriptor,
            requiresIncludePendingChanges: requiresIncludePendingChanges
        ) else {
            return []
        }
        let loadedChatIDs = Set(loadedChats.map(\.id))
        return chatsByID.values.filter { chat in
            loadedChatIDs.contains(chat.id) == false
                && shouldPreserveLiveFetchedChat(chat)
                && shouldIncludeLiveFetchedChat(chat, descriptor: descriptor)
        }
    }

    package func shouldPreserveLiveFetchedChat(_ chat: CodexChat) -> Bool {
        guard chatsByID[chat.id] === chat else {
            return false
        }
        if activeChatObservationsByID[chat.id]?.isFinished == false {
            return true
        }
        if chat.status?.isActive == true {
            return true
        }
        if chat.phase == .loading {
            return true
        }
        return false
    }

    private func canPreserveLiveChats<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>,
        requiresIncludePendingChanges: Bool
    ) -> Bool {
        let plan = chatQueryPlan(for: descriptor)
        return (requiresIncludePendingChanges == false || descriptor.includePendingChanges)
            && descriptor.normalizedFetchOffset == 0
            && plan?.membershipRequiresServerRefresh != true
    }

    private func shouldIncludeLiveFetchedChat<Model: CodexPersistentModel>(
        _ chat: CodexChat,
        descriptor: CodexFetchDescriptor<Model>
    ) -> Bool {
        guard let plan = chatQueryPlan(for: descriptor) else {
            return chat.isArchived == false
        }
        return plan.matches(chat)
    }

    private func workspaceIfLoaded(for url: URL) -> CodexWorkspace? {
        let id = CodexWorkspaceID(rawValue: Self.standardizedDirectoryURL(url).path)
        return workspacesByID[id]
    }

    private func register(_ results: any CodexFetchedResultsRegistration) {
        fetchedResults.removeAll { $0.value == nil }
        fetchedResults.append(WeakFetchedResultsRegistration(results))
    }

    private func insertChatIntoRegisteredResults(_ chat: CodexChat, archived: Bool) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            await registration.value?.insert(chat, archived: archived)
        }
    }

    private func archiveChatInRegisteredResults(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            await registration.value?.archive(chat, workspace: workspace, group: group)
        }
    }

    private func revalidateChatInRegisteredResults(
        _ chat: CodexChat,
        previousWorkspace: CodexWorkspace?,
        previousGroup: CodexWorkspaceGroup?,
        archived: Bool,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        await revalidateChatsInRegisteredResults(
            [CodexFetchedChatRevalidation(
                chat: chat,
                previousWorkspace: previousWorkspace,
                previousGroup: previousGroup,
                archived: archived
            )],
            excluding: excludedRegistration
        )
    }

    private func revalidateChatsInRegisteredResults(
        _ changes: [CodexFetchedChatRevalidation],
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        guard changes.isEmpty == false else {
            return
        }
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            guard let value = registration.value else {
                continue
            }
            if let excludedRegistration,
                (value as AnyObject) === (excludedRegistration as AnyObject)
            {
                continue
            }
            await value.revalidate(changes)
        }
    }

    private func removeChatFromRegisteredResults(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            guard let value = registration.value else {
                continue
            }
            if let excludedRegistration,
                (value as AnyObject) === (excludedRegistration as AnyObject)
            {
                continue
            }
            await value.remove(chat, workspace: workspace, group: group)
        }
    }

    private func removeChatsFromRegisteredResults(
        _ removedChats: [(
            chat: CodexChat,
            workspace: CodexWorkspace,
            group: CodexWorkspaceGroup?
        )],
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        for removedChat in removedChats {
            await removeChatFromRegisteredResults(
                removedChat.chat,
                workspace: removedChat.workspace,
                group: removedChat.group,
                excluding: excludedRegistration
            )
        }
    }

    private func refreshWorkspaceInRegisteredResults(
        _ workspace: CodexWorkspace,
        archived: Bool,
        removedChats: [CodexChat]
    ) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            await registration.value?.refresh(workspace, archived: archived, removedChats: removedChats)
        }
    }

    private func refreshWorkspaceGroupInRegisteredResults(
        _ group: CodexWorkspaceGroup,
        archived: Bool,
        removedChats: [CodexChat]
    ) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            await registration.value?.refresh(group, archived: archived, removedChats: removedChats)
        }
    }

    private func fetchAllThreadSnapshots<Model: CodexPersistentModel>(
        matching descriptor: CodexFetchDescriptor<Model>,
        archived archiveScope: Bool? = nil
    ) async throws -> [CodexThreadSnapshot] {
        var query = threadQuery(from: descriptor, includePaging: false, archived: archiveScope)
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

    private func chatQueryPlan<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>
    ) -> CodexThreadQueryPlan? {
        guard Model.self == CodexChat.self else {
            return nil
        }
        return CodexThreadQueryPlan(descriptor: descriptor as! CodexFetchDescriptor<CodexChat>)
    }

    private func archivedScope<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>
    ) -> Bool? {
        chatQueryPlan(for: descriptor)?.archived
    }

    private func workspaceFilters<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>
    ) -> [URL]? {
        chatQueryPlan(for: descriptor)?.workspaces
    }

    private func singleWorkspaceScope<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>
    ) -> URL? {
        chatQueryPlan(for: descriptor)?.singleWorkspace
    }

    private func filter(_ chats: [CodexChat], using plan: CodexThreadQueryPlan) -> [CodexChat] {
        chats.filter { plan.matches($0) }
    }

    private func localPage<Model: CodexPersistentModel>(
        _ items: [Model],
        for descriptor: CodexFetchDescriptor<Model>,
        cursor: String?
    ) -> CodexFetchPage<Model> {
        let offset =
            cursor == nil
            ? descriptor.normalizedFetchOffset
            : localCursorOffset(from: cursor)
        let start = min(offset, items.count)
        guard let limit = descriptor.fetchLimit else {
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

    private func canUseServerOrderedPages<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>,
        cursor: String?
    ) -> Bool {
        if descriptor.normalizedFetchOffset > 0 {
            return false
        }
        if cursor?.hasPrefix(Self.localCursorPrefix) == true {
            return false
        }
        guard let plan = chatQueryPlan(for: descriptor) else {
            return true
        }
        guard plan.serverPredicateIsComplete else {
            return false
        }
        guard let primarySort = plan.sortPlans.first else {
            return true
        }
        if primarySort.key == .recencyAt {
            return true
        }
        return plan.sortPlans.count == 1 && primarySort.threadSortKey != nil
    }

    package func localCursor(for offset: Int) -> String {
        "\(Self.localCursorPrefix)\(offset)"
    }

    package func localCursorOffset(from cursor: String?) -> Int {
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

    private func threadQuery<Model: CodexPersistentModel>(
        from descriptor: CodexFetchDescriptor<Model>,
        cursor: String? = nil,
        includePaging: Bool = true,
        archived archiveScope: Bool? = nil
    )
        -> CodexThreadQuery
    {
        if let plan = chatQueryPlan(for: descriptor) {
            return plan.threadQuery(
                cursor: cursor,
                includePaging: includePaging,
                archived: archiveScope
            )
        }
        let sortPlans = descriptor.sortPlans
        let serverSort = sortPlans.first { sortDescriptor in
            switch sortDescriptor.key {
            case .createdAt, .updatedAt, .recencyAt:
                return true
            case .name:
                return false
            }
        }
        return CodexThreadQuery(
            cursor: includePaging ? cursor : nil,
            limit: includePaging ? descriptor.fetchLimit : nil,
            sortDirection: serverSort?.threadSortDirection,
            sortKey: serverSort?.threadSortKey
        )
    }

    private func sectionIdentity<Model: CodexPersistentModel>(
        for item: Model,
        descriptor: CodexSectionDescriptor<Model>
    ) -> (id: CodexFetchSectionID, title: String) {
        switch descriptor.key {
        case .workspace:
            if let chat = item as? CodexChat, let workspace = chat.workspace {
                return (.workspace(workspace.id), workspace.name)
            }
        case .workspaceGroup:
            if let workspace = item as? CodexWorkspace, let group = workspace.workspaceGroup {
                return (.workspaceGroup(group.id), group.name)
            }
            if let chat = item as? CodexChat, let group = chat.workspace?.workspaceGroup {
                return (.workspaceGroup(group.id), group.name)
            }
        }
        return (.unknown("unknown"), "Unknown")
    }

    private func sort(_ chats: [CodexChat], using descriptors: [SortDescriptor<CodexChat>])
        -> [CodexChat]
    {
        let sortPlans = descriptors.map(CodexSortPlan<CodexChat>.init(descriptor:))
        guard sortPlans.first?.key != .recencyAt else {
            return chats
        }
        let localSortPlans = sortPlans.filter { $0.key != .recencyAt }
        guard localSortPlans.isEmpty == false else {
            return chats
        }
        let localDescriptors = zip(descriptors, sortPlans).compactMap { descriptor, sortPlan in
            sortPlan.key == .recencyAt ? nil : descriptor
        }
        return sortModels(chats, using: localDescriptors) { descriptor, lhs, rhs in
            descriptor.compare(lhs, rhs)
        }
    }

    private func sort(
        _ workspaces: [CodexWorkspace],
        using descriptors: [SortDescriptor<CodexWorkspace>]
    ) -> [CodexWorkspace] {
        _ = descriptors.map(CodexSortPlan<CodexWorkspace>.init(descriptor:))
        return sortModels(workspaces, using: descriptors) { descriptor, lhs, rhs in
            descriptor.compare(lhs, rhs)
        }
    }

    private func sort(
        _ groups: [CodexWorkspaceGroup],
        using descriptors: [SortDescriptor<CodexWorkspaceGroup>]
    ) -> [CodexWorkspaceGroup] {
        _ = descriptors.map(CodexSortPlan<CodexWorkspaceGroup>.init(descriptor:))
        return sortModels(groups, using: descriptors) { descriptor, lhs, rhs in
            descriptor.compare(lhs, rhs)
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

    private func compare(_ lhs: Date?, _ rhs: Date?, order: SortOrder) -> ComparisonResult {
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

    private func unique<Model: CodexPersistentModel>(_ models: [Model]) -> [Model] {
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

private extension CodexReviewTarget {
    var dataKitPreview: String {
        switch self {
        case .uncommittedChanges:
            return "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings."
        case .baseBranch(let branch):
            return "Review the code changes against the base branch '\(branch)'."
        case .commit(let sha, let title):
            if let title, title.isEmpty == false {
                return "Review the code changes introduced by commit \(sha) (\"\(title)\"). Provide prioritized, actionable findings."
            }
            return "Review the code changes introduced by commit \(sha). Provide prioritized, actionable findings."
        case .custom(let instructions):
            let preview = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "Review code changes." : preview
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
        var directoryPath = url.standardizedFileURL.path
        while true {
            let gitPath = (directoryPath as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitPath) {
                return URL(fileURLWithPath: gitPath)
            }

            let parentPath = (directoryPath as NSString).deletingLastPathComponent
            guard parentPath != directoryPath, parentPath.isEmpty == false else {
                return nil
            }
            directoryPath = parentPath
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
