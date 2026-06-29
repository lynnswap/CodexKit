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

    private struct ChatFetchedResultState: Equatable {
        var name: String?
        var preview: String?
        var modelProvider: String?
        var isArchived: Bool
        var createdAt: Date?
        var updatedAt: Date?
        var recencyAt: Date?
        var status: CodexThreadStatus?
        var ephemeral: Bool?
        var workspaceID: CodexWorkspaceID?
        var workspaceGroupID: CodexWorkspaceGroupID?
    }

    private final class ActiveChatObservation {
        var leaseCount = 0
        var setupTask: Task<Void, Error>?
        var eventTask: Task<Void, Never>?
        var turnsUpgradeTask: Task<Void, Error>?
        var eventThread: CodexThread?
        var includesTurns = false
        var isFinished = false
        var isBufferingEvents = false
        var bufferedEvents: [CodexThreadEvent] = []
        var changeContinuations: [UUID: AsyncStream<CodexChatChange>.Continuation] = [:]

        func cancel() {
            isFinished = true
            setupTask?.cancel()
            eventTask?.cancel()
            turnsUpgradeTask?.cancel()
            discardBufferedEvents()
            finishChangeStreams()
        }

        func beginBufferingEvents() {
            isBufferingEvents = true
        }

        func appendBufferedEvent(_ event: CodexThreadEvent) {
            bufferedEvents.append(event)
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

        func makeChangeStream(
            initialSnapshot: CodexChatSnapshot
        ) -> (id: UUID, stream: AsyncStream<CodexChatChange>) {
            let id = UUID()
            let pair = AsyncStream<CodexChatChange>.makeStream(bufferingPolicy: .unbounded)
            pair.continuation.yield(.snapshot(initialSnapshot))
            if isFinished {
                pair.continuation.finish()
            } else {
                changeContinuations[id] = pair.continuation
            }
            return (id, pair.stream)
        }

        func removeChangeStream(id: UUID) {
            changeContinuations.removeValue(forKey: id)?.finish()
        }

        func yield(_ changes: [CodexChatChange]) {
            guard changes.isEmpty == false else {
                return
            }
            for continuation in changeContinuations.values {
                for change in changes {
                    continuation.yield(change)
                }
            }
        }

        func finishChangeStreams() {
            for continuation in changeContinuations.values {
                continuation.finish()
            }
            changeContinuations.removeAll(keepingCapacity: true)
        }
    }

    public private(set) weak var container: CodexModelContainer?
    public let appServer: CodexAppServer

    private var workspaceGroupsByID: [CodexWorkspaceGroupID: CodexWorkspaceGroup] = [:]
    private var workspacesByID: [CodexWorkspaceID: CodexWorkspace] = [:]
    private var chatsByID: [CodexThreadID: CodexChat] = [:]
    private var fetchedResults: [WeakFetchedResultsRegistration] = []
    private var activeChatObservationsByID: [CodexThreadID: ActiveChatObservation] = [:]

    package init(container: CodexModelContainer) {
        self.container = container
        self.appServer = container.appServer
    }

    public func fetch<Model: CodexObservableModel>(
        _ request: CodexFetchRequest<Model>
    ) async throws -> [Model] {
        let page = try await fetchPage(request)
        await syncLoadedRelationships(from: page, request: request)
        return page.items
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

    public func model(for reviewIdentity: CodexReviewIdentity) -> CodexChat {
        chat(for: reviewIdentity.activeTurnThreadID)
    }

    public func model(for reviewSession: CodexReviewSession) -> CodexChat {
        model(for: reviewSession.identity)
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
        let previousWorkspaces = group.workspaces
        let previousChats = group.workspaces.flatMap(\.chats)
        let snapshots = try await fetchAllThreadSnapshots(matching: request)
        let fetchedChats = await applyFetchedSnapshots(
            snapshots,
            archived: request.filter.archived == true,
            scopedWorkspaceURL: request.filter.singleWorkspace
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
                    && shouldPreserve($0, outside: request.filter.archived)
            }
            let currentChats = fetchedWorkspaceChats + preservedChats
            workspace.setChats(currentChats)
            pruneWorkspaceIfEmpty(workspace)
            _ = detachStaleChats(
                previousWorkspaceChats,
                from: workspace,
                keeping: currentChats,
                archivedScope: request.filter.archived
            )
        }
        let previousWorkspacesStillInGroup = previousWorkspaces.filter {
            $0.workspaceGroup?.id == group.id
        }
        let refreshedWorkspaces = workspaces.filter { $0.workspaceGroup?.id == group.id }
        let refreshedWorkspaceIDs = Set(refreshedWorkspaces.map(\.id))
        let preservedWorkspaces = previousWorkspacesStillInGroup.filter {
            refreshedWorkspaceIDs.contains($0.id) == false
                && containsOutOfScopeChat(in: $0, archivedScope: request.filter.archived)
        }
        group.setWorkspaces(sort(refreshedWorkspaces + preservedWorkspaces, using: request.sortDescriptors))
        let currentChatIDs = Set(group.workspaces.flatMap(\.chats).map(\.id))
        let removedChats = previousChats.filter {
            currentChatIDs.contains($0.id) == false
                && fetchedChatIDs.contains($0.id) == false
                && isInRefreshedScope($0, archivedScope: request.filter.archived)
        }
        await refreshWorkspaceGroupInRegisteredResults(
            group,
            archived: request.filter.archived == true,
            removedChats: removedChats
        )
    }

    public func refresh(_ workspace: CodexWorkspace) async throws {
        let request = CodexFetchRequest<CodexChat>.chats(in: workspace)
        let previousChats = workspace.chats
        let snapshots = try await fetchAllThreadSnapshots(matching: request)
        let fetchedChats = await applyFetchedSnapshots(
            snapshots,
            archived: request.filter.archived == true,
            scopedWorkspaceURL: request.filter.singleWorkspace
        )
        let chats = sort(
            fetchedChats,
            using: request.sortDescriptors
        )
        let refreshedIDs = Set(chats.map(\.id))
        let preservedChats = previousChats.filter {
            refreshedIDs.contains($0.id) == false
                && shouldPreserve($0, outside: request.filter.archived)
        }
        let currentChats = chats + preservedChats
        workspace.setChats(currentChats)
        pruneWorkspaceIfEmpty(workspace)
        let removedChats = detachStaleChats(
            previousChats,
            from: workspace,
            keeping: currentChats,
            archivedScope: request.filter.archived
        )
        await refreshWorkspaceInRegisteredResults(
            workspace,
            archived: request.filter.archived == true,
            removedChats: removedChats
        )
    }

    public func refresh(_ chat: CodexChat, includeTurns: Bool = true) async throws {
        let thread = try await appServer.resumeThread(chat.id)
        try await refresh(chat, using: thread, includeTurns: includeTurns)
    }

    private func refresh(
        _ chat: CodexChat,
        using thread: CodexThread,
        includeTurns: Bool,
        replaysBufferedEvents: Bool = true
    ) async throws {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let observation = activeChatObservationsByID[chat.id]
        observation?.beginBufferingEvents()
        let snapshot: CodexThreadSnapshot
        do {
            snapshot = try await thread.read(includeTurns: includeTurns)
        } catch {
            if replaysBufferedEvents {
                await flushBufferedEvents(from: observation, to: chat)
            } else {
                observation?.discardBufferedEvents()
            }
            throw error
        }
        let refreshedChat = apply(snapshot)
        if includeTurns {
            refreshedChat.resetLiveMergeStateFromCurrentItems()
        }
        refreshedChat.syncPhaseAfterRefresh(includeTurns: includeTurns)
        observation?.yield([.snapshot(CodexChatSnapshot(chat: refreshedChat))])
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

    private func flushBufferedEvents(
        from observation: ActiveChatObservation?,
        to chat: CodexChat
    ) async {
        let bufferedEvents = observation?.finishBufferingEvents() ?? []
        for event in bufferedEvents {
            let changes = await apply(event, to: chat)
            observation?.yield(changes)
        }
    }

    public func observe(
        _ chat: CodexChat,
        includeTurns: Bool = true
    ) async throws -> CodexChatObservation {
        guard chat.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }

        let activeObservation = activeObservation(for: chat, includeTurns: includeTurns)
        do {
            try await activeObservation.setupTask?.value
            if includeTurns {
                try await activeObservation.turnsUpgradeTask?.value
            }
        } catch {
            releaseChatObservation(chat.id, observation: activeObservation)
            throw error
        }

        return makeChatObservation(chat: chat, activeObservation: activeObservation)
    }

    private func activeObservation(
        for chat: CodexChat,
        includeTurns: Bool,
        resumedThread: CodexThread? = nil
    ) -> ActiveChatObservation {
        if let observation = activeChatObservationsByID[chat.id] {
            if observation.isFinished {
                activeChatObservationsByID.removeValue(forKey: chat.id)
            } else {
                observation.leaseCount += 1
                if includeTurns {
                    scheduleTurnsUpgrade(
                        observation,
                        for: chat,
                        resumedThread: resumedThread
                    )
                }
                return observation
            }
        }

        let observation = ActiveChatObservation()
        observation.leaseCount = 1
        activeChatObservationsByID[chat.id] = observation
        if includeTurns {
            observation.includesTurns = true
        }
        observation.setupTask = Task { @MainActor [weak self, weak chat, weak observation] in
            guard let self, let chat, let observation else {
                return
            }
            try await self.startObservation(
                observation,
                for: chat,
                includeTurns: includeTurns,
                resumedThread: resumedThread
            )
        }
        return observation
    }

    private func scheduleTurnsUpgrade(
        _ observation: ActiveChatObservation,
        for chat: CodexChat,
        resumedThread: CodexThread? = nil
    ) {
        guard observation.includesTurns == false else {
            return
        }
        if observation.turnsUpgradeTask != nil {
            return
        }
        observation.turnsUpgradeTask = Task { @MainActor [weak self, weak chat, weak observation] in
            guard let self, let chat, let observation else {
                return
            }
            defer {
                if observation.includesTurns == false {
                    observation.turnsUpgradeTask = nil
                }
            }
            try await observation.setupTask?.value
            guard self.activeChatObservationsByID[chat.id] === observation,
                  observation.isFinished == false,
                  observation.includesTurns == false
            else {
                return
            }
            let thread: CodexThread
            if let eventThread = observation.eventThread {
                thread = eventThread
            } else if let resumedThread {
                thread = resumedThread
            } else {
                thread = try await self.appServer.resumeThread(chat.id)
            }
            try await self.refresh(chat, using: thread, includeTurns: true)
            observation.includesTurns = true
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
        do {
            if let resumedThread {
                thread = resumedThread
            } else {
                thread = try await appServer.resumeThread(chat.id)
            }
            observation.eventThread = thread
            try Task.checkCancellation()
            await thread.reopenLiveEventStream()
            observation.beginBufferingEvents()
            await startEventTask(observation, for: chat, thread: thread)
            try await refresh(chat, using: thread, includeTurns: includeTurns)
            try Task.checkCancellation()
            observation.includesTurns = includeTurns
        } catch {
            chat.fail(with: error)
            discardChatObservation(chat.id, observation: observation)
            throw error
        }
    }

    private func startEventTask(
        _ observation: ActiveChatObservation,
        for chat: CodexChat,
        thread: CodexThread
    ) async {
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            observation.eventTask = Task { @MainActor [weak self, weak chat, weak observation] in
                guard let self, let chat, let observation else {
                    ready.resume()
                    return
                }
                let events = await thread.makeLiveEventStream()
                ready.resume()
                do {
                    for try await event in events {
                        try Task.checkCancellation()
                        if observation.isBufferingEvents {
                            observation.appendBufferedEvent(event)
                            continue
                        }
                        let changes = await self.apply(event, to: chat)
                        observation.yield(changes)
                    }
                } catch is CancellationError {
                } catch {
                    chat.fail(with: error)
                    observation.yield([.phaseChanged(chat.phase)])
                }
                while observation.isBufferingEvents {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                observation.finishChangeStreams()
                self.finishChatObservationIfIdle(chat.id, observation: observation)
            }
        }
    }

    private func releaseChatObservation(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) {
        guard activeChatObservationsByID[chatID] === observation else {
            return
        }
        observation.leaseCount -= 1
        guard observation.leaseCount <= 0 else {
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
        observation.eventTask = nil
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

    public func observe(
        _ reviewIdentity: CodexReviewIdentity,
        includeTurns: Bool = true
    ) async throws -> CodexChatObservation {
        let reviewSession = try await appServer.resumeReview(reviewIdentity)
        return try await observe(reviewSession, includeTurns: includeTurns)
    }

    public func observe(
        _ reviewSession: CodexReviewSession,
        includeTurns: Bool = true
    ) async throws -> CodexChatObservation {
        let chat = model(for: reviewSession)
        guard chat.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }

        let activeObservation = activeObservation(
            for: chat,
            includeTurns: includeTurns,
            resumedThread: reviewSession.eventThread
        )
        do {
            try await activeObservation.setupTask?.value
            if includeTurns {
                try await activeObservation.turnsUpgradeTask?.value
            }
        } catch {
            releaseChatObservation(chat.id, observation: activeObservation)
            throw error
        }

        return makeChatObservation(chat: chat, activeObservation: activeObservation)
    }

    private func makeChatObservation(
        chat: CodexChat,
        activeObservation: ActiveChatObservation
    ) -> CodexChatObservation {
        let chatID = chat.id
        let changeStream = activeObservation.makeChangeStream(
            initialSnapshot: CodexChatSnapshot(chat: chat)
        )
        return CodexChatObservation(chat: chat, changes: changeStream.stream) {
            [weak self, weak activeObservation] in
            guard let activeObservation else {
                return
            }
            activeObservation.removeChangeStream(id: changeStream.id)
            self?.releaseChatObservation(chatID, observation: activeObservation)
        }
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
            updatedAt: now,
            ephemeral: input.options.ephemeral
        )
        let chat = apply(snapshot)
        chat.setArchived(false)
        workspace.moveChatToFront(chat)
        await insertChatIntoRegisteredResults(chat, archived: false)
        return chat
    }

    @discardableResult
    public func send(
        _ input: CodexChatMessageInput,
        in chat: CodexChat
    ) async throws -> CodexResponse {
        let thread = try await appServer.resumeThread(chat.id)
        do {
            let response = try await thread.respond(to: input.prompt, options: input.options)
            await apply(response, to: chat)
            return response
        } catch {
            if input.options.transcriptErrorHandlingPolicy == .revertTranscript {
                try? await refresh(
                    chat,
                    using: thread,
                    includeTurns: true,
                    replaysBufferedEvents: false
                )
            }
            throw error
        }
    }

    @discardableResult
    package func apply(_ response: CodexResponse, to chat: CodexChat) async -> [CodexChatChange] {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let previousUpdatedAt = chat.updatedAt
        let changes = chat.apply(response)
        if let workspace = chat.workspace,
            let updatedAt = chat.updatedAt,
            previousUpdatedAt.map({ updatedAt > $0 }) ?? true
        {
            workspace.moveChatToFront(chat)
        }
        await revalidateChatInRegisteredResults(
            chat,
            previousWorkspace: previousWorkspace,
            previousGroup: previousGroup,
            archived: chat.isArchived
        )
        activeChatObservationsByID[chat.id]?.yield(changes)
        return changes
    }

    @discardableResult
    package func apply(_ event: CodexThreadEvent, to chat: CodexChat) async -> [CodexChatChange] {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let previousState = fetchedResultState(for: chat)
        let previousUpdatedAt = chat.updatedAt
        let changes = chat.apply(event)
        if let workspace = chat.workspace,
            let updatedAt = chat.updatedAt,
            previousUpdatedAt.map({ updatedAt > $0 }) ?? true
        {
            workspace.moveChatToFront(chat)
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
        chat.setArchived(true)
        await archiveChatInRegisteredResults(chat, workspace: workspace, group: group)
    }

    public func unarchive(_ chat: CodexChat) async throws {
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

    public func delete(_ chat: CodexChat) async throws {
        try await appServer.deleteThread(chat.id)
        await remove(chat)
    }

    package func fetchPage<Model: CodexObservableModel>(
        _ request: CodexFetchRequest<Model>,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> CodexFetchPage<Model> {
        if Model.self == CodexChat.self {
            let page = try await fetchChatPage(
                request as! CodexFetchRequest<CodexChat>,
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
                request as! CodexFetchRequest<CodexWorkspace>,
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
                request as! CodexFetchRequest<CodexWorkspaceGroup>,
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

    package func backfillCursor(after itemCount: Int, currentCursor: String?) -> String? {
        guard currentCursor?.hasPrefix(Self.localCursorPrefix) == true else {
            return currentCursor
        }
        return localCursor(for: itemCount)
    }

    private func fetchChatPage(
        _ request: CodexFetchRequest<CodexChat>,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws
        -> CodexFetchPage<CodexChat>
    {
        if canUseServerOrderedPages(for: request) == false {
            let fetchedChats = await applyFetchedSnapshots(
                try await fetchAllThreadSnapshots(matching: request),
                archived: request.filter.archived == true,
                scopedWorkspaceURL: request.filter.singleWorkspace,
                excluding: excludedRegistration
            )
            let chats = sort(
                fetchedChats,
                using: request.sortDescriptors
            )
            let page = localPage(chats, for: request)
            return CodexFetchPage(
                items: page.items,
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: chats,
                relationshipIsComplete: true
            )
        }

        let page = try await appServer.listThreads(threadQuery(from: request))
        let fetchedChats = await applyFetchedSnapshots(
            page.threads,
            archived: request.filter.archived == true,
            scopedWorkspaceURL: request.filter.singleWorkspace,
            excluding: excludedRegistration
        )
        let chats = sort(
            fetchedChats,
            using: request.sortDescriptors
        )
        return CodexFetchPage(
            items: chats,
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    private func fetchWorkspacePage(
        _ request: CodexFetchRequest<CodexWorkspace>,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> CodexFetchPage<CodexWorkspace> {
        let chats = await applyFetchedSnapshots(
            try await fetchAllThreadSnapshots(matching: request),
            archived: request.filter.archived == true,
            scopedWorkspaceURL: request.filter.singleWorkspace,
            excluding: excludedRegistration
        )
        let workspaces = unique(chats.compactMap(\.workspace))
        let removedChats = syncWorkspaceChats(
            chats,
            preservingExisting: shouldPreserveExistingWorkspaceChats(
                for: request,
                relationshipIsComplete: true
            ),
            workspaceFilters: request.filter.workspaces,
            archivedScope: request.filter.archived
        )
        await removeChatsFromRegisteredResults(removedChats, excluding: excludedRegistration)
        let sortedWorkspaces = sort(workspaces, using: request.sortDescriptors)
        let page = localPage(sortedWorkspaces, for: request)
        return CodexFetchPage(
            items: page.items,
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor,
            relationshipItems: sortedWorkspaces,
            relationshipIsComplete: true
        )
    }

    private func fetchWorkspaceGroupPage(
        _ request: CodexFetchRequest<CodexWorkspaceGroup>,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> CodexFetchPage<CodexWorkspaceGroup> {
        let chats = await applyFetchedSnapshots(
            try await fetchAllThreadSnapshots(matching: request),
            archived: request.filter.archived == true,
            scopedWorkspaceURL: request.filter.singleWorkspace,
            excluding: excludedRegistration
        )
        let workspaces = unique(chats.compactMap(\.workspace))
        let groups = unique(workspaces.compactMap(\.workspaceGroup))
        let preservingGroupWorkspaces = request.filter.workspaces != nil
            || shouldPreserveExistingWorkspaceChats(
                for: request,
                relationshipIsComplete: true
            )
        let removedChats = syncWorkspaceChats(
            chats,
            preservingExisting: shouldPreserveExistingWorkspaceChats(
                for: request,
                relationshipIsComplete: true
            ),
            workspaceFilters: request.filter.workspaces,
            archivedScope: request.filter.archived
        )
        await removeChatsFromRegisteredResults(removedChats, excluding: excludedRegistration)
        syncGroupWorkspaces(
            workspaces,
            preservingExisting: preservingGroupWorkspaces,
            archivedScope: request.filter.archived
        )
        let sortedGroups = sort(groups, using: request.sortDescriptors)
        let page = localPage(sortedGroups, for: request)
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
    private func apply(_ snapshot: CodexThreadSnapshot, archived: Bool? = nil) -> CodexChat {
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
        chat.apply(snapshot, workspace: workspace)
        if let archived {
            chat.setArchived(archived)
        }
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
            if let previousGroup = workspace.workspaceGroup,
                previousGroup !== group
            {
                previousGroup.setWorkspaces(previousGroup.workspaces.filter { $0 !== workspace })
            }
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

    private func remove(_ chat: CodexChat) async {
        let workspace = chat.workspace
        let group = workspace?.workspaceGroup
        chatsByID.removeValue(forKey: chat.id)
        if let workspace {
            detach(chat, from: workspace)
        }
        chat.detachFromContext()
        await removeChatFromRegisteredResults(chat, workspace: workspace, group: group)
    }

    package func syncLoadedRelationships<Model: CodexObservableModel>(
        from page: CodexFetchPage<Model>,
        request: CodexFetchRequest<Model>,
        loadedItems: [Model]? = nil,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        let relationshipItems = page.relationshipItems ?? loadedItems ?? page.items
        let relationshipIsComplete = page.relationshipIsComplete
            ?? (page.nextCursor == nil && request.cursor == nil)
        await syncLoadedRelationships(
            relationshipItems,
            request: request,
            relationshipIsComplete: relationshipIsComplete,
            excluding: excludedRegistration
        )
    }

    private func syncLoadedRelationships<Model: CodexObservableModel>(
        _ items: [Model],
        request: CodexFetchRequest<Model>,
        relationshipIsComplete: Bool,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        if let chats = items as? [CodexChat] {
            let removedChats = syncWorkspaceChats(
                chats,
                preservingExisting: shouldPreserveExistingWorkspaceChats(
                    for: request,
                    relationshipIsComplete: relationshipIsComplete
                ),
                workspaceFilters: request.filter.workspaces,
                archivedScope: request.filter.archived
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
                workspace.setChats(fetchedChats + remainingChats)
            } else {
                let fetchedIDs = Set(fetchedChats.map(\.id))
                let preservedChats = workspace.chats.filter {
                    fetchedIDs.contains($0.id) == false
                        && shouldPreserve($0, outside: archivedScope)
                }
                let currentChats = fetchedChats + preservedChats
                workspace.setChats(currentChats)
                let staleChats = detachStaleChats(
                    previousChats,
                    from: workspace,
                    keeping: currentChats,
                    archivedScope: archivedScope
                )
                let group = workspace.workspaceGroup
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

    private func containsOutOfScopeChat(in workspace: CodexWorkspace, archivedScope: Bool?) -> Bool {
        workspace.chats.contains { shouldPreserve($0, outside: archivedScope) }
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
                group.setWorkspaces(sort(fetchedWorkspaces + remainingWorkspaces, using: [.name()]))
            } else {
                let fetchedIDs = Set(fetchedWorkspaces.map(\.id))
                let preservedWorkspaces = group.workspaces.filter {
                    fetchedIDs.contains($0.id) == false
                        && containsOutOfScopeChat(in: $0, archivedScope: archivedScope)
                }
                group.setWorkspaces(sort(fetchedWorkspaces + preservedWorkspaces, using: [.name()]))
            }
        }
    }

    private func detach(_ chat: CodexChat, from workspace: CodexWorkspace) {
        workspace.setChats(workspace.chats.filter { $0 !== chat })
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
        group.setWorkspaces(group.workspaces.filter { $0 !== workspace })
    }

    private func shouldPreserveExistingWorkspaceChats<Model: CodexObservableModel>(
        for request: CodexFetchRequest<Model>,
        relationshipIsComplete: Bool
    ) -> Bool {
        (Model.self == CodexChat.self
            && relationshipIsComplete == false)
            || request.filter.searchTerm?.isEmpty == false
            || request.filter.modelProviders?.isEmpty == false
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
        if request.cursor?.hasPrefix(Self.localCursorPrefix) == true {
            return false
        }
        guard let primarySort = request.sortDescriptors.first else {
            return true
        }
        if primarySort.key == .recencyAt {
            return true
        }
        return request.sortDescriptors.count == 1 && primarySort.threadSortKey != nil
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
            workspaces: request.filter.workspaces,
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
                compare(lhs.recencyAt, rhs.recencyAt, order: descriptor.order)
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

extension CodexFetchFilter {
    fileprivate var singleWorkspace: URL? {
        guard let workspaces, workspaces.count == 1 else {
            return nil
        }
        return workspaces[0]
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
