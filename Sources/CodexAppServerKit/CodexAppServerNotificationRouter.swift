import Foundation
import OSLog

private let notificationRouterLogger = Logger(
    subsystem: "CodexAppServerKit",
    category: "notification-router"
)

package actor CodexAppServerNotificationRouter {
    private struct ThreadSubscriber {
        var continuation: AsyncThrowingStream<CodexThreadEvent, Error>.Continuation
        var replayPolicy: ThreadEventReplayPolicy
    }

    private typealias NotificationContext = AppServerNotificationDecoder.Context

    private var threadIDByTurnID: [CodexTurnID: CodexThreadID] = [:]
    private var threadHistoryByThreadID: [CodexThreadID: [CodexThreadEvent]] = [:]
    private var threadFailureByThreadID: [CodexThreadID: CodexAppServerError] = [:]
    private var threadGenerationStartByThreadID: [CodexThreadID: ThreadGenerationStart] = [:]
    private var threadSubscribersByThreadID: [CodexThreadID: [UUID: ThreadSubscriber]] = [:]
    private var itemReducer = CodexItemReducer()
    // Removed with the general thread-history bridge when thread observation moves
    // to its dedicated bounded owner. Per-turn replay never reads this state.
    private var threadRoutingTermination: CodexAppServerError?
    private let accountEventHub: AccountEventHub
    package nonisolated let turnReplayStore: TurnReplayStore

    private enum ThreadEventReplayPolicy {
        case currentGeneration
        case none
    }

    private enum ThreadGenerationStart {
        case cursor(Int)
        case includingTurn(CodexTurnID, fallbackCursor: Int)
    }

    package init(
        client: AppServerClient,
        turnReplayStore: TurnReplayStore,
        accountEventHub: AccountEventHub = .init()
    ) {
        _ = client
        self.turnReplayStore = turnReplayStore
        self.accountEventHub = accountEventHub
    }

    package func events(for threadID: CodexThreadID) -> AsyncThrowingStream<
        CodexThreadEvent, Error
    > {
        threadEventStream(for: threadID, replayPolicy: .currentGeneration)
    }

    package func liveEvents(for threadID: CodexThreadID) -> AsyncThrowingStream<
        CodexThreadEvent, Error
    > {
        threadEventStream(for: threadID, replayPolicy: .none)
    }

    package func observationEvents(for threadID: CodexThreadID) -> AsyncThrowingStream<
        CodexThreadEvent, Error
    > {
        threadEventStream(for: threadID, replayPolicy: .currentGeneration)
    }

    private func threadEventStream(
        for threadID: CodexThreadID,
        replayPolicy: ThreadEventReplayPolicy
    ) -> AsyncThrowingStream<CodexThreadEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<CodexThreadEvent, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        let subscriptionID = UUID()
        continuation.onTermination = { _ in
            Task { await self.removeThreadSubscriber(subscriptionID, threadID: threadID) }
        }
        addThreadSubscriber(
            subscriptionID,
            threadID: threadID,
            continuation: continuation,
            replayPolicy: replayPolicy
        )
        return stream
    }

    package func seedTurn(_ turnID: CodexTurnID, threadID: CodexThreadID) {
        if let existingThreadID = threadIDByTurnID[turnID] {
            precondition(
                existingThreadID == threadID,
                "A turn cannot move between thread associations."
            )
        }
        threadIDByTurnID[turnID] = threadID
    }

    package func discardTurnAssociation(
        _ turnID: CodexTurnID,
        threadID: CodexThreadID
    ) {
        guard let registeredThreadID = threadIDByTurnID[turnID] else {
            return
        }
        precondition(
            registeredThreadID == threadID,
            "Only the thread that owns a turn association may discard it."
        )
        threadIDByTurnID.removeValue(forKey: turnID)
    }

    package func seedTurns(
        _ turns: [CodexTurnSnapshot]?,
        threadID: CodexThreadID
    ) {
        itemReducer.seed(turns)
        for turn in turns ?? [] {
            seedTurn(turn.id, threadID: threadID)
        }
    }

    package func accountEvents() async -> CodexAccountEvents {
        return await accountEventHub.events()
    }

    package func replaceRateLimits(
        with response: AppServerAPI.Account.RateLimits.Response
    ) async {
        await accountEventHub.replaceRateLimits(with: response)
    }
    package func threadSubscriberCountForTesting(for threadID: CodexThreadID) -> Int {
        threadSubscribersByThreadID[threadID]?.count ?? 0
    }

    package func itemSnapshotForTesting(
        turnID: CodexTurnID,
        itemID: String
    ) -> CodexThreadItem? {
        itemReducer.item(turnID: turnID, itemID: itemID)
    }

    package func beginThreadEventGeneration(_ threadID: CodexThreadID) {
        threadFailureByThreadID.removeValue(forKey: threadID)
        threadGenerationStartByThreadID[threadID] = .cursor(
            threadHistoryByThreadID[threadID]?.count ?? 0
        )
    }

    package func threadEventGenerationCursor(_ threadID: CodexThreadID) -> Int {
        threadHistoryByThreadID[threadID]?.count ?? 0
    }

    package func beginThreadEventGeneration(_ threadID: CodexThreadID, at cursor: Int) {
        threadFailureByThreadID.removeValue(forKey: threadID)
        let historyCount = threadHistoryByThreadID[threadID]?.count ?? 0
        threadGenerationStartByThreadID[threadID] = .cursor(min(cursor, historyCount))
    }

    package func beginThreadEventGeneration(_ threadID: CodexThreadID, including turnID: CodexTurnID) {
        threadFailureByThreadID.removeValue(forKey: threadID)
        threadGenerationStartByThreadID[threadID] = .includingTurn(
            turnID,
            fallbackCursor: threadHistoryByThreadID[threadID]?.count ?? 0
        )
    }

    package func beginDetachedThreadEventGeneration(
        _ threadID: CodexThreadID,
        including turnID: CodexTurnID
    ) {
        threadFailureByThreadID.removeValue(forKey: threadID)
        threadGenerationStartByThreadID[threadID] = .includingTurn(
            turnID,
            fallbackCursor: threadHistoryByThreadID[threadID]?.count ?? 0
        )
        seedTurn(turnID, threadID: threadID)
    }

    package func route(
        _ decoded: AppServerNotificationDecoder.DecodedNotification
    ) async throws {
        guard threadRoutingTermination == nil else {
            return
        }
        guard decoded.disposition != .explicitIgnore else {
            return
        }

        var context = decoded.context
        if let threadID = context.threadID, let turnID = context.turnID {
            threadIDByTurnID[turnID] = threadID
        } else if let turnID = context.turnID, let threadID = threadIDByTurnID[turnID] {
            context.threadID = threadID
        }
        var routed = decoded
        routed.context = context
        try await routeNotification(routed)
    }

    private func routeNotification(
        _ notification: AppServerNotificationDecoder.DecodedNotification
    ) async throws {
        let context = notification.context
        switch notification.payload {
        case .turnCompleted(let turn):
            var releasedTurnID = context.turnID
            defer {
                if let releasedTurnID {
                    itemReducer.release(turnID: releasedTurnID)
                }
            }
            let outcome = try terminalOutcome(from: turn, context: context)
            let turnID = context.turnID ?? outcome.response.turnID
            releasedTurnID = turnID
            let disposition = await turnReplayStore.finishIfTracked(outcome)
            if let threadID = context.threadID ?? threadIDByTurnID[turnID],
               shouldPublishThreadTerminal(
                   disposition,
                   outcome: outcome,
                   threadID: threadID
               )
            {
                appendThreadEvent(.terminal(outcome), threadID: threadID)
            }
            threadIDByTurnID.removeValue(forKey: turnID)

        case .item(let mutation):
            guard let turnID = context.turnID else {
                preconditionFailure("Validated item notification lost turnId.")
            }
            let event = try reduceItemEvent(mutation, turnID: turnID)
            if let threadID = context.threadID ?? threadIDByTurnID[turnID] {
                appendThreadEvent(
                    Self.threadEvent(from: event, turnID: turnID, threadID: threadID),
                    threadID: threadID
                )
            }
            recordReplayDisposition(
                await turnReplayStore.routeIfTracked(event, for: turnID),
                turnID: turnID
            )

        case .turnStarted(let payloadTurnID):
            let turnID = context.turnID ?? payloadTurnID
            if let threadID = context.threadID ?? threadIDByTurnID[turnID] {
                appendThreadEvent(.turnStarted(turnID), threadID: threadID)
            }
            let event = CodexTurnEvent.started(turnID)
            recordReplayDisposition(
                await turnReplayStore.routeIfTracked(event, for: turnID),
                turnID: turnID
            )

        case .threadStatus(let status):
            if let threadID = context.threadID {
                appendThreadEvent(.statusChanged(status), threadID: threadID)
            }

        case .tokenUsage(let usage):
            if let threadID = context.threadID {
                appendThreadEvent(
                    .tokenUsageUpdated(usage, turnID: context.turnID),
                    threadID: threadID
                )
            }
            if let turnID = context.turnID {
                let event = CodexTurnEvent.tokenUsageUpdated(usage)
                recordReplayDisposition(
                    await turnReplayStore.routeIfTracked(event, for: turnID),
                    turnID: turnID
                )
            }

        case .threadClosed:
            if let threadID = context.threadID {
                appendThreadEvent(.closed, threadID: threadID)
            }

        case .serverRequestResolved, .connectionDiagnostic:
            preconditionFailure("A connection-owned notification reached the domain router.")

        case .account(let mutation):
            switch mutation {
            case .updated(let update):
                await accountEventHub.apply(.updated(update))
            case .rateLimitsUpdated(let update):
                await accountEventHub.apply(.rateLimitsUpdated(update))
            case .loginCompleted(let completion):
                await accountEventHub.apply(.loginCompleted(completion))
            }

        case .raw:
            let raw = CodexRawNotification(
                method: notification.methodName,
                params: notification.rawData,
                threadID: context.threadID,
                turnID: context.turnID
            )
            if let threadID = context.threadID {
                appendThreadEvent(.unknown(raw), threadID: threadID)
            }
            if let turnID = context.turnID {
                let event = CodexTurnEvent.unknown(raw)
                recordReplayDisposition(
                    await turnReplayStore.routeIfTracked(event, for: turnID),
                    turnID: turnID
                )
            }

        case .ignored:
            preconditionFailure("Explicit-ignore notification reached the router.")
        }
    }

    private func appendThreadEvent(_ event: CodexThreadEvent, threadID: CodexThreadID) {
        threadHistoryByThreadID[threadID, default: []].append(event)
        let history = threadHistoryByThreadID[threadID] ?? []
        let eventIndex = history.index(before: history.endIndex)
        if let subscribers = threadSubscribersByThreadID[threadID] {
            for subscriber in subscribers.values {
                guard
                    shouldYieldThreadEvent(
                        at: eventIndex,
                        in: history,
                        threadID: threadID,
                        replayPolicy: subscriber.replayPolicy
                    )
                else {
                    continue
                }
                subscriber.continuation.yield(event)
            }
        }
        if case .closed = event {
            let turnIDs = threadIDByTurnID.compactMap { entry in
                entry.value == threadID ? entry.key : nil
            }
            for turnID in turnIDs {
                itemReducer.release(turnID: turnID)
                threadIDByTurnID.removeValue(forKey: turnID)
            }
            finishThreadSubscribers(threadID: threadID)
        }
    }

    private func addThreadSubscriber(
        _ subscriptionID: UUID,
        threadID: CodexThreadID,
        continuation: AsyncThrowingStream<CodexThreadEvent, Error>.Continuation,
        replayPolicy: ThreadEventReplayPolicy = .currentGeneration
    ) {
        if let threadRoutingTermination {
            continuation.finish(throwing: threadRoutingTermination)
            return
        }
        let history = threadHistoryByThreadID[threadID] ?? []
        let replayedHistory: [CodexThreadEvent]
        switch replayPolicy {
        case .currentGeneration:
            replayedHistory = currentGenerationEvents(in: history, threadID: threadID)
        case .none:
            replayedHistory = []
        }
        for event in replayedHistory {
            continuation.yield(event)
        }
        if isCurrentThreadEventGenerationFinished(threadID) {
            continuation.finish()
            return
        }
        if let failure = threadFailureByThreadID[threadID] {
            continuation.finish(throwing: failure)
            return
        }
        threadSubscribersByThreadID[threadID, default: [:]][subscriptionID] = .init(
            continuation: continuation,
            replayPolicy: replayPolicy
        )
    }

    private func isCurrentThreadEventGenerationFinished(_ threadID: CodexThreadID) -> Bool {
        let history = threadHistoryByThreadID[threadID] ?? []
        return currentGenerationEvents(in: history, threadID: threadID)
            .contains(where: Self.isTerminalThreadEvent)
    }

    private func currentGenerationEvents(
        in history: [CodexThreadEvent],
        threadID: CodexThreadID
    ) -> [CodexThreadEvent] {
        currentGenerationEventIndices(in: history, threadID: threadID).map { history[$0] }
    }

    private func currentGenerationEventIndices(
        in history: [CodexThreadEvent],
        threadID: CodexThreadID
    ) -> [Array<CodexThreadEvent>.Index] {
        guard let generationStart = threadGenerationStartByThreadID[threadID] else {
            return Array(history.indices)
        }

        let startIndex = currentGenerationStartIndex(generationStart, in: history)
        let eventIndices = Array(history.indices.filter { $0 >= startIndex })
        if case .includingTurn(let turnID, _) = generationStart,
            eventIndices.contains(where: { Self.threadEvent(history[$0], matches: turnID) }) == false
        {
            return eventIndices.filter {
                Self.threadEventTurnID(history[$0]).map { $0 == turnID } ?? true
            }
        }
        return eventIndices
    }

    private func shouldYieldThreadEvent(
        at eventIndex: Int,
        in history: [CodexThreadEvent],
        threadID: CodexThreadID,
        replayPolicy: ThreadEventReplayPolicy
    ) -> Bool {
        switch replayPolicy {
        case .none:
            return true
        case .currentGeneration:
            guard let generationStart = threadGenerationStartByThreadID[threadID] else {
                return true
            }
            if case .includingTurn(let turnID, _) = generationStart,
                history[...eventIndex].contains(where: { Self.threadEvent($0, matches: turnID) })
                    == false,
                Self.threadEventTurnID(history[eventIndex]).map({ $0 != turnID }) == true
            {
                return false
            }
            return eventIndex >= currentGenerationStartIndex(generationStart, in: history)
        }
    }

    private nonisolated func currentGenerationStartIndex(
        _ generationStart: ThreadGenerationStart,
        in history: [CodexThreadEvent]
    ) -> Int {
        switch generationStart {
        case .cursor(let cursor):
            return min(cursor, history.count)
        case .includingTurn(let turnID, let fallbackCursor):
            return Self.generationStartIndex(
                in: history,
                including: turnID,
                fallbackCursor: fallbackCursor
            )
        }
    }

    private nonisolated static func generationStartIndex(
        in history: [CodexThreadEvent],
        including turnID: CodexTurnID,
        fallbackCursor: Int
    ) -> Int {
        if let firstTurnEventIndex = history.firstIndex(where: { threadEvent($0, matches: turnID) }) {
            let precedingHistory = history[..<firstTurnEventIndex]
            if let boundaryIndex = precedingHistory.lastIndex(where: isThreadEventGenerationBoundary) {
                return history.index(after: boundaryIndex)
            }
            let clampedFallback = min(fallbackCursor, history.count)
            return min(clampedFallback, firstTurnEventIndex)
        }

        let clampedFallback = min(fallbackCursor, history.count)
        let fallbackHistory = history[clampedFallback...]
        if let boundaryIndex = fallbackHistory.lastIndex(where: isPendingTurnGenerationBoundary) {
            return history.index(after: boundaryIndex)
        }
        return clampedFallback
    }

    private nonisolated static func isPendingTurnGenerationBoundary(_ event: CodexThreadEvent) -> Bool {
        switch event {
        case .terminal:
            true
        case .closed, .turnStarted, .snapshot, .statusChanged, .itemStarted, .itemUpdated, .itemCompleted,
             .message, .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
             .tokenUsageUpdated, .unknown:
            false
        }
    }

    private nonisolated static func threadEventTurnID(_ event: CodexThreadEvent) -> CodexTurnID? {
        switch event {
        case .turnStarted(let turnID):
            turnID
        case .snapshot(let snapshot):
            snapshot.id
        case .terminal(let outcome):
            outcome.response.turnID
        case .itemStarted(_, let turnID),
             .itemUpdated(_, let turnID), .itemCompleted(_, let turnID), .message(_, let turnID),
             .messageDelta(_, let turnID), .reasoningSummaryPartAdded(_, let turnID),
             .reasoningDelta(_, let turnID), .tokenUsageUpdated(_, let turnID):
            turnID
        case .unknown(let raw):
            raw.turnID
        case .statusChanged, .closed:
            nil
        }
    }

    private nonisolated static func isTerminalThreadEvent(_ event: CodexThreadEvent) -> Bool {
        switch event {
        case .closed:
            true
        case .turnStarted, .snapshot, .terminal, .itemStarted, .itemUpdated, .itemCompleted, .message,
             .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta, .tokenUsageUpdated,
             .statusChanged, .unknown:
            false
        }
    }

    private nonisolated static func isThreadEventGenerationBoundary(_ event: CodexThreadEvent) -> Bool {
        switch event {
        case .closed, .terminal:
            true
        case .turnStarted, .snapshot, .statusChanged, .itemStarted, .itemUpdated, .itemCompleted,
            .message, .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
            .tokenUsageUpdated, .unknown:
            false
        }
    }

    private nonisolated static func isTerminalThreadEvent(
        _ event: CodexThreadEvent,
        for turnID: CodexTurnID
    ) -> Bool {
        switch event {
        case .terminal(let outcome):
            outcome.response.turnID == turnID
        case .turnStarted, .snapshot, .statusChanged, .closed, .itemStarted, .itemUpdated, .itemCompleted,
             .message, .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
             .tokenUsageUpdated, .unknown:
            false
        }
    }

    private func shouldPublishThreadTerminal(
        _ disposition: TurnReplayStore.TerminalRoutingDisposition,
        outcome: CodexTurnOutcome,
        threadID: CodexThreadID
    ) -> Bool {
        guard disposition != .duplicate else {
            return false
        }
        guard let existing = threadHistoryByThreadID[threadID]?.first(where: {
            Self.isTerminalThreadEvent($0, for: outcome.response.turnID)
        }) else {
            return true
        }
        guard case .terminal(let existingOutcome) = existing else {
            preconditionFailure("A matching terminal thread event must carry a turn outcome.")
        }
        if existingOutcome != outcome {
            notificationRouterLogger.error(
                "Ignoring conflicting terminal outcome for turn \(outcome.response.turnID.rawValue, privacy: .public)"
            )
        } else {
            notificationRouterLogger.debug(
                "Ignoring duplicate terminal outcome for turn \(outcome.response.turnID.rawValue, privacy: .public)"
            )
        }
        return false
    }

    private nonisolated static func threadEvent(
        _ event: CodexThreadEvent,
        matches turnID: CodexTurnID
    ) -> Bool {
        switch event {
        case .turnStarted(let eventTurnID):
            eventTurnID == turnID
        case .snapshot(let snapshot):
            snapshot.id == turnID
        case .terminal(let outcome):
            outcome.response.turnID == turnID
        case .itemStarted(_, let eventTurnID),
             .itemUpdated(_, let eventTurnID), .itemCompleted(_, let eventTurnID),
             .message(_, let eventTurnID), .messageDelta(_, let eventTurnID),
             .reasoningSummaryPartAdded(_, let eventTurnID),
             .reasoningDelta(_, let eventTurnID),
             .tokenUsageUpdated(_, let eventTurnID):
            eventTurnID == turnID
        case .unknown(let raw):
            raw.turnID == turnID
        case .statusChanged, .closed:
            false
        }
    }

    private nonisolated static func threadEvent(
        from event: CodexTurnEvent,
        turnID: CodexTurnID,
        threadID: CodexThreadID
    ) -> CodexThreadEvent {
        switch event {
        case .started(let turnID):
            return .turnStarted(turnID)
        case .snapshot(let snapshot):
            return .snapshot(snapshot)
        case .itemStarted(let item):
            return .itemStarted(item, turnID: turnID)
        case .itemUpdated(let item):
            return .itemUpdated(item, turnID: turnID)
        case .itemCompleted(let item):
            return .itemCompleted(item, turnID: turnID)
        case .message(let message):
            return .message(
                CodexAgentMessageFallbackID.scopedMessage(message, turnID: turnID),
                turnID: turnID
            )
        case .messageDelta(let delta):
            return .messageDelta(delta, turnID: turnID)
        case .reasoningSummaryPartAdded(let part):
            return .reasoningSummaryPartAdded(part, turnID: turnID)
        case .reasoningDelta(let delta):
            return .reasoningDelta(delta, turnID: turnID)
        case .tokenUsageUpdated(let usage):
            return .tokenUsageUpdated(usage, turnID: turnID)
        case .terminal(let outcome):
            return .terminal(outcome)
        case .unknown(let raw):
            var raw = raw
            raw.threadID = threadID
            raw.turnID = turnID
            return .unknown(raw)
        }
    }

    private func reduceItemEvent(
        _ mutation: CodexItemReducer.Mutation,
        turnID: CodexTurnID
    ) throws -> CodexTurnEvent {
        let item = try itemReducer.apply(mutation, turnID: turnID)
        switch mutation {
        case .started:
            return .itemStarted(item)
        case .completed:
            return .itemCompleted(item)
        case .agentMessageDelta(let itemID, let delta):
            return .messageDelta(.init(
                text: delta,
                itemID: itemID,
                phase: item.message?.phase,
                currentItem: item
            ))
        case .reasoningSummaryPartAdded(let itemID, let index):
            return .reasoningSummaryPartAdded(.init(
                itemID: itemID,
                kind: .summary,
                index: index,
                currentItem: item
            ))
        case .reasoningSummaryDelta(let itemID, let index, let delta):
            let part = CodexReasoningPart(itemID: itemID, kind: .summary, index: index)
            return .reasoningDelta(.init(part: part, delta: delta, currentItem: item))
        case .reasoningTextDelta(let itemID, let index, let delta):
            let part = CodexReasoningPart(itemID: itemID, kind: .text, index: index)
            return .reasoningDelta(.init(part: part, delta: delta, currentItem: item))
        case .planDelta, .commandOutputDelta, .filePatchSnapshot, .mcpProgress:
            return .itemUpdated(item)
        }
    }

    private func removeThreadSubscriber(_ subscriptionID: UUID, threadID: CodexThreadID) {
        threadSubscribersByThreadID[threadID]?.removeValue(forKey: subscriptionID)
        if threadSubscribersByThreadID[threadID]?.isEmpty == true {
            threadSubscribersByThreadID.removeValue(forKey: threadID)
        }
    }

    private func finishThreadSubscribers(threadID: CodexThreadID) {
        let subscribers =
            threadSubscribersByThreadID.removeValue(forKey: threadID).map {
                Array($0.values)
            } ?? []
        for subscriber in subscribers {
            subscriber.continuation.finish()
        }
    }

    private func finishThreadSubscribers(threadID: CodexThreadID, throwing error: Error) {
        let subscribers = threadSubscribersByThreadID.removeValue(forKey: threadID).map {
            Array($0.values)
        } ?? []
        for subscriber in subscribers {
            subscriber.continuation.finish(throwing: error)
        }
    }

    package func finishAll(throwing error: CodexAppServerError) async {
        let threadSubscribers = threadSubscribersByThreadID.values.flatMap(\.values)
        threadRoutingTermination = threadRoutingTermination ?? error
        itemReducer.releaseAll()
        threadSubscribersByThreadID.removeAll()
        for subscriber in threadSubscribers {
            subscriber.continuation.finish(throwing: error)
        }
        await accountEventHub.finish(throwing: error)
    }

    private nonisolated func recordReplayDisposition(
        _ disposition: TurnReplayStore.RoutingDisposition,
        turnID: CodexTurnID
    ) {
        guard case .routed(let count) = disposition else {
            return
        }
        guard count > 0 else {
            return
        }
        notificationRouterLogger.warning(
            "Compacted \(count, privacy: .public) slow turn replay subscriber(s) for \(turnID.rawValue, privacy: .public)"
        )
    }

    private func terminalOutcome(
        from turn: AppServerAPI.Turn.Payload,
        context: NotificationContext
    ) throws -> CodexTurnOutcome {
        let turnID = CodexTurnID(rawValue: turn.id)
        if let correlatedTurnID = context.turnID, correlatedTurnID != turnID {
            throw CodexAppServerError.malformedNotification(.init(
                method: "turn/completed",
                message: "Correlated turn id \(correlatedTurnID.rawValue) does not match payload turn id \(turnID.rawValue).",
                rawData: nil
            ))
        }
        let snapshot = CodexAppServer.turnSnapshots(from: [turn])[0]
        let response = CodexResponse(
            turnID: snapshot.id,
            transcript: .init(items: snapshot.items),
            startedAt: snapshot.startedAt,
            completedAt: snapshot.completedAt,
            duration: snapshot.duration
        )
        switch snapshot.state {
        case .completed:
            return .completed(response)
        case .interrupted:
            return .interrupted(response)
        case .failed(let error):
            return .failed(.init(response: response, error: error))
        case .inProgress:
            return .invalidTerminalStatus(
                rawStatus: CodexTurnStatus.inProgress.rawValue,
                error: nil,
                response: response
            )
        case .unknown(let rawValue, let error):
            return .invalidTerminalStatus(
                rawStatus: rawValue,
                error: error,
                response: response
            )
        }
    }

}

package enum AppServerThreadItemMapping {
    package static func threadItems(from values: [AppServerJSONValue]?) -> [CodexThreadItem] {
        values?.compactMap(threadItem(from:)) ?? []
    }

    package static func threadItem(from value: AppServerJSONValue) -> CodexThreadItem? {
        guard let data = try? JSONEncoder().encode(value),
              let item = try? JSONDecoder().decode(RawThreadItem.self, from: data)
        else {
            return nil
        }
        return item.makeThreadItem(startedAt: nil, completedAt: nil, allowsFallbackID: true)
    }
}

struct RawCommandAction: Decodable {
    var kind: String
    var command: String?
    var name: String?
    var path: String?
    var query: String?

    var codexCommandAction: CodexCommand.Action {
        CodexCommand.Action(
            kind: codexKind,
            command: command,
            name: name,
            path: path,
            query: query
        )
    }

    private var codexKind: CodexCommand.Action.Kind {
        switch kind {
        case "read":
            .read
        case "listFiles", "list_files":
            .listFiles
        case "search":
            .search
        default:
            .unknown
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case kind
        case command
        case name
        case path
        case query
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeStringIfPresent(forKey: .type))
            ?? (try? container.decodeStringIfPresent(forKey: .kind))
            ?? "unknown"
        command = try? container.decodeStringIfPresent(forKey: .command)
        name = try? container.decodeStringIfPresent(forKey: .name)
        path = try? container.decodeStringIfPresent(forKey: .path)
        query = try? container.decodeStringIfPresent(forKey: .query)
    }
}

struct RawThreadItem: Decodable {
    var id: String?
    var type: String?
    var kind: String?
    var text: String?
    var review: String?
    var phase: String?
    var command: String?
    var cwd: String?
    var processID: String?
    var source: String?
    var aggregatedOutput: String?
    var output: String?
    var exitCode: Int?
    var durationMs: Int?
    var commandActions: [RawCommandAction]
    var status: String?
    var path: String?
    var namespace: String?
    var server: String?
    var tool: String?
    var name: String?
    var query: String?
    var prompt: String?
    var summary: [String]?
    var content: [String]?
    var arguments: AppServerJSONValue?
    var input: AppServerJSONValue?
    var result: AppServerJSONValue?
    var error: AppServerJSONValue?
    var changes: AppServerJSONValue?
    var rawValue: AppServerJSONValue?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case kind
        case text
        case review
        case phase
        case command
        case cwd
        case processID = "processId"
        case source
        case aggregatedOutput
        case output
        case exitCode
        case durationMs
        case commandActions
        case status
        case path
        case namespace
        case server
        case tool
        case name
        case query
        case prompt
        case summary
        case content
        case arguments
        case input
        case result
        case error
        case changes
    }

    init(from decoder: Decoder) throws {
        rawValue = try? AppServerJSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeStringIfPresent(forKey: .id)
        type = try container.decodeStringIfPresent(forKey: .type)
        kind = try container.decodeStringIfPresent(forKey: .kind)
        text = try container.decodeStringIfPresent(forKey: .text)
        review = try container.decodeStringIfPresent(forKey: .review)
        phase = try container.decodeStringIfPresent(forKey: .phase)
        command = try container.decodeStringIfPresent(forKey: .command)
        cwd = try container.decodeStringIfPresent(forKey: .cwd)
        processID = try container.decodeStringIfPresent(forKey: .processID)
        source = try container.decodeStringIfPresent(forKey: .source)
        aggregatedOutput = try container.decodeStringIfPresent(forKey: .aggregatedOutput)
        output = try container.decodeStringIfPresent(forKey: .output)
        exitCode = try? container.decodeIfPresent(Int.self, forKey: .exitCode)
        durationMs = try? container.decodeIfPresent(Int.self, forKey: .durationMs)
        commandActions = (try? container.decodeIfPresent([RawCommandAction].self, forKey: .commandActions)) ?? []
        status = try container.decodeStringIfPresent(forKey: .status)
        path = try container.decodeStringIfPresent(forKey: .path)
        namespace = try container.decodeStringIfPresent(forKey: .namespace)
        server = try container.decodeStringIfPresent(forKey: .server)
        tool = try container.decodeStringIfPresent(forKey: .tool)
        name = try container.decodeStringIfPresent(forKey: .name)
        query = try container.decodeStringIfPresent(forKey: .query)
        prompt = try container.decodeStringIfPresent(forKey: .prompt)
        summary = try container.decodeTextListIfPresent(forKey: .summary)
        content = try container.decodeTextListIfPresent(forKey: .content)
        arguments = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .arguments)
        input = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .input)
        result = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .result)
        error = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .error)
        changes = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .changes)
    }

    var threadItem: CodexThreadItem? {
        makeThreadItem(startedAt: nil, completedAt: nil)
    }

    func makeThreadItem(
        startedAt: Date?,
        completedAt: Date?,
        allowsFallbackID: Bool = false
    ) -> CodexThreadItem? {
        let rawType = type ?? kind ?? "unknown"
        let kind = CodexThreadItem.Kind(rawValue: rawType)
        guard let itemID = id ?? fallbackItemID(rawType: rawType, allowed: allowsFallbackID) else {
            return nil
        }
        return .init(
            id: itemID,
            kind: kind,
            content: content(
                kind: kind,
                id: itemID,
                rawType: rawType,
                startedAt: startedAt,
                completedAt: completedAt
            ),
            rawPayload: rawPayload
        )
    }

    private func fallbackItemID(rawType: String, allowed: Bool) -> String? {
        guard allowed else {
            return nil
        }
        return "missing-id:\(rawType):\(UUID().uuidString)"
    }

    private func content(
        kind: CodexThreadItem.Kind,
        id: String,
        rawType: String,
        startedAt: Date?,
        completedAt: Date?
    ) -> CodexThreadItem.Content {
        switch kind {
        case .userMessage:
            return .message(.init(id: id, role: .user, text: messageText))
        case .agentMessage:
            return .message(
                .init(
                    id: id,
                    role: .assistant,
                    phase: phase.map(CodexMessagePhase.init(rawValue:)),
                    text: messageText
                ))
        case .enteredReviewMode, .exitedReviewMode:
            return .log(messageText)
        case .plan:
            return .plan(messageText)
        case .reasoning:
            let summary = summary ?? []
            let content = content ?? []
            if summary.isEmpty && content.isEmpty {
                return .reasoning(.init(summary: messageText))
            }
            return .reasoning(.init(summary: summary, content: content))
        case .commandExecution:
            return .command(
                .init(
                    command: command ?? "",
                    cwd: cwd,
                    output: aggregatedOutput ?? output ?? text,
                    exitCode: exitCode,
                    status: status.map(CodexTurnStatus.init(rawValue:)),
                    startedAt: startedAt,
                    completedAt: completedAt,
                    duration: durationMs.map { .milliseconds(Int64($0)) },
                    processID: processID,
                    source: source.map(CodexCommand.Source.init(rawValue:)),
                    commandActions: commandActions.map(\.codexCommandAction)
                ))
        case .fileChange:
            return .fileChange(
                .init(
                    path: path,
                    output: aggregatedOutput ?? output ?? changes?.displayText ?? text,
                    status: status.map(CodexTurnStatus.init(rawValue:))
                ))
        case .mcpToolCall, .dynamicToolCall, .collabAgentToolCall, .subAgentActivity,
            .webSearch, .imageView, .sleep, .imageGeneration:
            return .toolCall(
                .init(
                    namespace: namespace,
                    server: server,
                    name: tool ?? name ?? query ?? path,
                    arguments: arguments?.displayText ?? input?.displayText,
                    result: result?.displayText ?? text,
                    error: error?.displayText,
                    status: status.map(CodexTurnStatus.init(rawValue:))
                ))
        case .contextCompaction:
            return .contextCompaction(status ?? text)
        case .diagnostic, .error:
            return .diagnostic(messageText)
        case .unknown:
            return .unknown(.init(rawType: rawType, text: messageText, payload: rawPayload))
        }
    }

    private var messageText: String {
        text ?? review ?? content?.joined(separator: "\n") ?? ""
    }

    private var rawPayload: Data? {
        rawValue.flatMap { try? JSONEncoder().encode($0) }
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeTextListIfPresent(forKey key: Key) throws -> [String]? {
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return values.nonEmpty
        }
        if let value = try? decodeStringIfPresent(forKey: key) {
            return [value]
        }
        if let fragments = try? decodeIfPresent([AppServerTextFragment].self, forKey: key) {
            return fragments.compactMap(\.text).nonEmpty
        }
        return nil
    }

    fileprivate func decodeStringIfPresent(forKey key: Key) throws -> String? {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        if let int = try? decode(Int.self, forKey: key) {
            return String(int)
        }
        if let double = try? decode(Double.self, forKey: key) {
            return String(double)
        }
        if let bool = try? decode(Bool.self, forKey: key) {
            return bool ? "true" : "false"
        }
        return nil
    }
}

private struct AppServerTextFragment: Decodable {
    var text: String?

    enum CodingKeys: String, CodingKey {
        case text
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if singleValue.decodeNil() {
            text = nil
            return
        }
        if let text = try? singleValue.decode(String.self) {
            self.text = text
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeStringIfPresent(forKey: .text)
    }
}

private extension Array where Element == String {
    var nonEmpty: [String]? {
        isEmpty ? nil : self
    }
}

extension AppServerJSONValue {
    var displayText: String? {
        switch self {
        case .string(let value):
            value
        case .int(let value):
            String(value)
        case .double(let value):
            String(value)
        case .bool(let value):
            value ? "true" : "false"
        case .object(let value):
            value["displayText"]?.displayText
                ?? value["text"]?.displayText
                ?? (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        case .array:
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        case .null:
            nil
        }
    }
}
