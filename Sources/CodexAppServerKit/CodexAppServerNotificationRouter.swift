import Foundation

package actor CodexAppServerNotificationRouter {
    private struct Subscriber<Event> {
        var continuation: AsyncThrowingStream<Event, Error>.Continuation
    }

    private struct NotificationContext {
        var threadID: CodexThreadID?
        var turnID: CodexTurnID?
    }

    private let client: AppServerClient
    private var routerTask: Task<Void, Never>?
    private var threadIDByTurnID: [CodexTurnID: CodexThreadID] = [:]
    private var reviewThreadIDs: Set<CodexThreadID> = []
    private var turnHistoryByTurnID: [CodexTurnID: [CodexTurnEvent]] = [:]
    private var threadHistoryByThreadID: [CodexThreadID: [CodexThreadEvent]] = [:]
    private var turnSubscribersByTurnID: [CodexTurnID: [UUID: Subscriber<CodexTurnEvent>]] = [:]
    private var threadSubscribersByThreadID: [CodexThreadID: [UUID: Subscriber<CodexThreadEvent>]] =
        [:]
    private let decoder = JSONDecoder()

    package init(client: AppServerClient) {
        self.client = client
    }

    package func start() async {
        guard routerTask == nil else {
            return
        }
        let notifications = await client.notificationStream()
        routerTask = Task {
            do {
                for try await notification in notifications {
                    self.route(notification)
                }
            } catch {
                self.finishAll(throwing: error)
            }
        }
    }

    package func events(for turnID: CodexTurnID) -> AsyncThrowingStream<CodexTurnEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<CodexTurnEvent, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        let subscriptionID = UUID()
        continuation.onTermination = { _ in
            Task { await self.removeTurnSubscriber(subscriptionID, turnID: turnID) }
        }
        addTurnSubscriber(subscriptionID, turnID: turnID, continuation: continuation)
        return stream
    }

    package func events(for threadID: CodexThreadID) -> AsyncThrowingStream<
        CodexThreadEvent, Error
    > {
        let (stream, continuation) = AsyncThrowingStream<CodexThreadEvent, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        let subscriptionID = UUID()
        continuation.onTermination = { _ in
            Task { await self.removeThreadSubscriber(subscriptionID, threadID: threadID) }
        }
        addThreadSubscriber(subscriptionID, threadID: threadID, continuation: continuation)
        return stream
    }

    package func seedTurn(_ turnID: CodexTurnID, threadID: CodexThreadID) {
        seedTurn(turnID, threadID: threadID, isReviewThread: false)
    }

    package func seedReviewTurn(_ turnID: CodexTurnID, reviewThreadID: CodexThreadID) {
        seedTurn(turnID, threadID: reviewThreadID, isReviewThread: true)
    }

    private func seedTurn(
        _ turnID: CodexTurnID,
        threadID: CodexThreadID,
        isReviewThread: Bool
    ) {
        threadIDByTurnID[turnID] = threadID
        if isReviewThread {
            reviewThreadIDs.insert(threadID)
        }
        guard let turnHistory = turnHistoryByTurnID[turnID] else {
            return
        }
        for turnEvent in turnHistory {
            let threadEvent = Self.threadEvent(
                from: turnEvent,
                turnID: turnID,
                threadID: threadID
            )
            if (threadHistoryByThreadID[threadID] ?? []).contains(threadEvent) {
                continue
            }
            appendThreadEvent(threadEvent, threadID: threadID)
        }
    }

    package func stop() {
        routerTask?.cancel()
        routerTask = nil
        finishAll(throwing: JSONRPC.Error.closed)
    }

    package func turnSubscriberCountForTesting(for turnID: CodexTurnID) -> Int {
        turnSubscribersByTurnID[turnID]?.count ?? 0
    }

    package func threadSubscriberCountForTesting(for threadID: CodexThreadID) -> Int {
        threadSubscribersByThreadID[threadID]?.count ?? 0
    }

    private func route(_ notification: JSONRPC.Notification) {
        let reviewNotification = try? AppServerReviewNotification(
            method: notification.method,
            paramsData: notification.params
        )
        if let reviewNotification,
           reviewNotification.method.isThreadlessReviewBroadcast,
           reviewNotification.payload.threadID == nil,
           reviewNotification.payload.resolvedTurnID == nil,
           routeReviewBroadcast(reviewNotification) {
            return
        }

        var context = Self.context(from: notification.params, reviewNotification: reviewNotification)
        if let threadID = context.threadID, let turnID = context.turnID {
            threadIDByTurnID[turnID] = threadID
        } else if let turnID = context.turnID, let threadID = threadIDByTurnID[turnID] {
            context.threadID = threadID
        }

        if let threadID = context.threadID {
            let event = decodeThreadEvent(notification: notification, context: context)
            appendThreadEvent(event, threadID: threadID)
        }

        if let turnID = context.turnID {
            let event = decodeTurnEvent(notification: notification, context: context)
            turnHistoryByTurnID[turnID, default: []].append(event)
            if let subscribers = turnSubscribersByTurnID[turnID] {
                for subscriber in subscribers.values {
                    subscriber.continuation.yield(event)
                }
            }
            if Self.isTerminalTurnEvent(event) {
                finishTurnSubscribers(turnID: turnID)
            }
        }
    }

    private func routeReviewBroadcast(_ notification: AppServerReviewNotification) -> Bool {
        guard reviewThreadIDs.isEmpty == false else {
            return false
        }
        for threadID in reviewThreadIDs {
            var raw = notification.rawNotification
            raw.threadID = threadID
            appendThreadEvent(.unknown(raw), threadID: threadID)
        }
        return true
    }

    private func appendThreadEvent(_ event: CodexThreadEvent, threadID: CodexThreadID) {
        threadHistoryByThreadID[threadID, default: []].append(event)
        if let subscribers = threadSubscribersByThreadID[threadID] {
            for subscriber in subscribers.values {
                subscriber.continuation.yield(event)
            }
        }
        if case .closed = event {
            finishThreadSubscribers(threadID: threadID)
        }
    }

    private func addTurnSubscriber(
        _ subscriptionID: UUID,
        turnID: CodexTurnID,
        continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation
    ) {
        let history = turnHistoryByTurnID[turnID] ?? []
        for event in history {
            continuation.yield(event)
        }
        if history.contains(where: Self.isTerminalTurnEvent) {
            continuation.finish()
            return
        }
        turnSubscribersByTurnID[turnID, default: [:]][subscriptionID] = .init(
            continuation: continuation)
    }

    private func addThreadSubscriber(
        _ subscriptionID: UUID,
        threadID: CodexThreadID,
        continuation: AsyncThrowingStream<CodexThreadEvent, Error>.Continuation
    ) {
        let history = threadHistoryByThreadID[threadID] ?? []
        for event in history {
            continuation.yield(event)
        }
        if history.contains(where: Self.isTerminalThreadEvent) {
            continuation.finish()
            return
        }
        threadSubscribersByThreadID[threadID, default: [:]][subscriptionID] = .init(
            continuation: continuation)
    }

    private nonisolated static func isTerminalTurnEvent(_ event: CodexTurnEvent) -> Bool {
        switch event {
        case .completed, .failed:
            true
        case .started, .itemStarted, .itemUpdated, .itemCompleted, .messageDelta,
            .reasoningSummaryPartAdded, .reasoningDelta, .tokenUsageUpdated, .unknown:
            false
        }
    }

    private nonisolated static func isTerminalThreadEvent(_ event: CodexThreadEvent) -> Bool {
        if case .closed = event {
            return true
        }
        return false
    }

    private nonisolated static func threadEvent(
        from event: CodexTurnEvent,
        turnID: CodexTurnID,
        threadID: CodexThreadID
    ) -> CodexThreadEvent {
        switch event {
        case .started(let turnID):
            return .turnStarted(turnID)
        case .itemStarted(let item):
            return .itemStarted(item, turnID: turnID)
        case .itemUpdated(let item):
            return .itemUpdated(item, turnID: turnID)
        case .itemCompleted(let item):
            return .itemCompleted(item, turnID: turnID)
        case .messageDelta(let delta):
            return .messageDelta(delta, turnID: turnID)
        case .reasoningSummaryPartAdded(let part):
            return .reasoningSummaryPartAdded(part, turnID: turnID)
        case .reasoningDelta(let delta):
            return .reasoningDelta(delta, turnID: turnID)
        case .tokenUsageUpdated(let usage):
            return .tokenUsageUpdated(usage, turnID: turnID)
        case .completed(let response):
            return .turnCompleted(response)
        case .failed(let message):
            return .turnFailed(turnID: turnID, message: message)
        case .unknown(let raw):
            var raw = raw
            raw.threadID = threadID
            raw.turnID = turnID
            return .unknown(raw)
        }
    }

    private func decodeTurnEvent(
        notification: JSONRPC.Notification,
        context: NotificationContext
    ) -> CodexTurnEvent {
        let raw = CodexRawNotification(
            method: notification.method,
            params: notification.params,
            threadID: context.threadID,
            turnID: context.turnID
        )
        switch notification.method {
        case "turn/started":
            return .started(context.turnID ?? .init(rawValue: ""))
        case "turn/completed":
            return .completed(turnResult(from: notification.params, context: context))
        case "turn/failed", "turn/cancelled":
            return .failed(turnFailureMessage(from: notification.params) ?? notification.method)
        case "item/started":
            if let item = item(from: notification.params) {
                return .itemStarted(item)
            }
            return .unknown(raw)
        case "item/updated":
            if let item = item(from: notification.params) {
                return .itemUpdated(item)
            }
            return .unknown(raw)
        case "item/completed":
            if let item = item(from: notification.params) {
                return .itemCompleted(item)
            }
            return .unknown(raw)
        case "item/commandExecution/outputDelta":
            if let item = itemUpdate(from: notification.params, kind: .commandExecution) {
                return .itemUpdated(item)
            }
            return .unknown(raw)
        case "item/fileChange/outputDelta", "item/fileChange/patchUpdated":
            if let item = itemUpdate(from: notification.params, kind: .fileChange) {
                return .itemUpdated(item)
            }
            return .unknown(raw)
        case "item/mcpToolCall/progress":
            if let item = itemUpdate(from: notification.params, kind: .mcpToolCall) {
                return .itemUpdated(item)
            }
            return .unknown(raw)
        case "item/agentMessage/delta":
            if let delta = messageDelta(from: notification.params) {
                return .messageDelta(delta)
            }
            return .unknown(raw)
        case "item/reasoning/summaryPartAdded":
            if let part = reasoningSummaryPart(from: notification.params) {
                return .reasoningSummaryPartAdded(part)
            }
            return .unknown(raw)
        case "item/reasoning/summaryTextDelta":
            if let delta = reasoningSummaryDelta(from: notification.params) {
                return .reasoningDelta(delta)
            }
            return .unknown(raw)
        case "item/reasoning/textDelta":
            if let delta = reasoningTextDelta(from: notification.params) {
                return .reasoningDelta(delta)
            }
            return .unknown(raw)
        case "thread/tokenUsage/updated":
            if let usage = tokenUsage(from: notification.params) {
                return .tokenUsageUpdated(usage)
            }
            return .unknown(raw)
        default:
            return .unknown(raw)
        }
    }

    private func decodeThreadEvent(
        notification: JSONRPC.Notification,
        context: NotificationContext
    ) -> CodexThreadEvent {
        let raw = CodexRawNotification(
            method: notification.method,
            params: notification.params,
            threadID: context.threadID,
            turnID: context.turnID
        )
        switch notification.method {
        case "turn/started":
            return .turnStarted(context.turnID ?? .init(rawValue: ""))
        case "turn/completed":
            return .turnCompleted(turnResult(from: notification.params, context: context))
        case "turn/failed", "turn/cancelled":
            return .turnFailed(
                turnID: context.turnID,
                message: turnFailureMessage(from: notification.params) ?? notification.method
            )
        case "item/started":
            if let item = item(from: notification.params) {
                return .itemStarted(item, turnID: context.turnID)
            }
            return .unknown(raw)
        case "item/updated":
            if let item = item(from: notification.params) {
                return .itemUpdated(item, turnID: context.turnID)
            }
            return .unknown(raw)
        case "item/completed":
            if let item = item(from: notification.params) {
                return .itemCompleted(item, turnID: context.turnID)
            }
            return .unknown(raw)
        case "item/commandExecution/outputDelta":
            if let item = itemUpdate(from: notification.params, kind: .commandExecution) {
                return .itemUpdated(item, turnID: context.turnID)
            }
            return .unknown(raw)
        case "item/fileChange/outputDelta", "item/fileChange/patchUpdated":
            if let item = itemUpdate(from: notification.params, kind: .fileChange) {
                return .itemUpdated(item, turnID: context.turnID)
            }
            return .unknown(raw)
        case "item/mcpToolCall/progress":
            if let item = itemUpdate(from: notification.params, kind: .mcpToolCall) {
                return .itemUpdated(item, turnID: context.turnID)
            }
            return .unknown(raw)
        case "item/agentMessage/delta":
            if let delta = messageDelta(from: notification.params) {
                return .messageDelta(delta, turnID: context.turnID)
            }
            return .unknown(raw)
        case "item/reasoning/summaryPartAdded":
            if let part = reasoningSummaryPart(from: notification.params) {
                return .reasoningSummaryPartAdded(part, turnID: context.turnID)
            }
            return .unknown(raw)
        case "item/reasoning/summaryTextDelta":
            if let delta = reasoningSummaryDelta(from: notification.params) {
                return .reasoningDelta(delta, turnID: context.turnID)
            }
            return .unknown(raw)
        case "item/reasoning/textDelta":
            if let delta = reasoningTextDelta(from: notification.params) {
                return .reasoningDelta(delta, turnID: context.turnID)
            }
            return .unknown(raw)
        case "thread/tokenUsage/updated":
            if let usage = tokenUsage(from: notification.params) {
                return .tokenUsageUpdated(usage, turnID: context.turnID)
            }
            return .unknown(raw)
        case "thread/status/changed":
            if let status = threadStatus(from: notification.params) {
                return .statusChanged(status)
            }
            return .unknown(raw)
        case "thread/closed":
            return .closed
        default:
            return .unknown(raw)
        }
    }

    private func removeTurnSubscriber(_ subscriptionID: UUID, turnID: CodexTurnID) {
        turnSubscribersByTurnID[turnID]?.removeValue(forKey: subscriptionID)
        if turnSubscribersByTurnID[turnID]?.isEmpty == true {
            turnSubscribersByTurnID.removeValue(forKey: turnID)
        }
    }

    private func removeThreadSubscriber(_ subscriptionID: UUID, threadID: CodexThreadID) {
        threadSubscribersByThreadID[threadID]?.removeValue(forKey: subscriptionID)
        if threadSubscribersByThreadID[threadID]?.isEmpty == true {
            threadSubscribersByThreadID.removeValue(forKey: threadID)
        }
    }

    private func finishTurnSubscribers(turnID: CodexTurnID) {
        let subscribers =
            turnSubscribersByTurnID.removeValue(forKey: turnID).map {
                Array($0.values)
            } ?? []
        for subscriber in subscribers {
            subscriber.continuation.finish()
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

    private func finishAll(throwing error: Error) {
        let turnSubscribers = turnSubscribersByTurnID.values.flatMap(\.values)
        let threadSubscribers = threadSubscribersByThreadID.values.flatMap(\.values)
        turnSubscribersByTurnID.removeAll()
        threadSubscribersByThreadID.removeAll()
        for subscriber in turnSubscribers {
            subscriber.continuation.finish(throwing: error)
        }
        for subscriber in threadSubscribers {
            subscriber.continuation.finish(throwing: error)
        }
    }

    private func item(from data: Data) -> CodexThreadItem? {
        guard let payload = try? decoder.decode(ItemPayload.self, from: data) else {
            return nil
        }
        return payload.item.threadItem
    }

    private func itemUpdate(from data: Data, kind: CodexThreadItem.Kind) -> CodexThreadItem? {
        guard let payload = try? decoder.decode(ItemProgressPayload.self, from: data) else {
            return nil
        }
        let output = payload.delta ?? payload.message ?? payload.changes?.displayText
        let itemID = payload.itemID ?? UUID().uuidString
        let content: CodexThreadItem.Content
        switch kind {
        case .commandExecution:
            content = .command(.init(command: "", output: output))
        case .fileChange:
            content = .fileChange(.init(output: output))
        case .mcpToolCall:
            content = .toolCall(.init(result: output))
        case let kind:
            content = .unknown(.init(rawType: kind.rawValue, text: output, payload: data))
        }
        return .init(id: itemID, kind: kind, content: content, rawPayload: data)
    }

    private func messageDelta(from data: Data) -> CodexMessageDelta? {
        guard let payload = try? decoder.decode(AgentMessageDeltaPayload.self, from: data) else {
            return nil
        }
        let text = payload.delta ?? payload.text ?? ""
        guard text.isEmpty == false else {
            return nil
        }
        return .init(
            text: text,
            itemID: payload.itemID,
            phase: payload.phase.map(CodexMessagePhase.init(rawValue:))
        )
    }

    private func reasoningSummaryPart(from data: Data) -> CodexReasoningPart? {
        guard let payload = try? decoder.decode(
            ReasoningSummaryPartPayload.self,
            from: data
        ) else {
            return nil
        }
        return .init(itemID: payload.itemID, kind: .summary, index: payload.summaryIndex)
    }

    private func reasoningSummaryDelta(from data: Data) -> CodexReasoningDelta? {
        guard let payload = try? decoder.decode(
            ReasoningSummaryTextDeltaPayload.self,
            from: data
        ) else {
            return nil
        }
        let part = CodexReasoningPart(
            itemID: payload.itemID,
            kind: .summary,
            index: payload.summaryIndex
        )
        return .init(part: part, delta: payload.delta)
    }

    private func reasoningTextDelta(from data: Data) -> CodexReasoningDelta? {
        guard let payload = try? decoder.decode(
            ReasoningTextDeltaPayload.self,
            from: data
        ) else {
            return nil
        }
        let part = CodexReasoningPart(
            itemID: payload.itemID,
            kind: .text,
            index: payload.contentIndex
        )
        return .init(part: part, delta: payload.delta)
    }

    private func tokenUsage(from data: Data) -> CodexTokenUsage? {
        guard let payload = try? decoder.decode(TokenUsagePayload.self, from: data) else {
            return nil
        }
        return payload.tokenUsage.codexUsage
    }

    private func threadStatus(from data: Data) -> CodexThreadStatus? {
        guard
            let payload = try? decoder.decode(ThreadStatusPayload.self, from: data),
            let type = payload.status?.type
        else {
            return nil
        }
        return .init(rawValue: type)
    }

    private func turnResult(from data: Data, context: NotificationContext) -> CodexResponse {
        let payload = try? decoder.decode(TurnCompletedPayload.self, from: data)
        let turn = payload?.turn
        let status = turn?.status.map(CodexTurnStatus.init(rawValue:))
        let transcript = CodexTranscript(items: threadItems(from: turn?.items))
        return .init(
            turnID: turn.map { .init(rawValue: $0.id) } ?? context.turnID ?? .init(rawValue: ""),
            status: status,
            errorMessage: turn?.error?.message,
            finalAnswer: transcript.finalAnswer,
            transcript: transcript,
            startedAt: turn?.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            completedAt: turn?.completedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            duration: turn?.durationMS.map { .milliseconds(Int64($0)) }
        )
    }

    private func threadItems(from values: [AppServerJSONValue]?) -> [CodexThreadItem] {
        AppServerThreadItemMapping.threadItems(from: values)
    }

    private func turnFailureMessage(from data: Data) -> String? {
        if let payload = try? decoder.decode(TurnCompletedPayload.self, from: data) {
            return payload.turn.error?.message
        }
        if let payload = try? decoder.decode(ErrorPayload.self, from: data) {
            return payload.error?.message ?? payload.message
        }
        return nil
    }

    private static func context(
        from data: Data,
        reviewNotification: AppServerReviewNotification? = nil
    ) -> NotificationContext {
        if let reviewNotification {
            let payload = reviewNotification.payload
            if payload.threadID != nil || payload.resolvedTurnID != nil {
                return .init(
                    threadID: payload.threadID.map(CodexThreadID.init(rawValue:)),
                    turnID: payload.resolvedTurnID.map(CodexTurnID.init(rawValue:))
                )
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .init()
        }
        let threadID =
            stringValue(named: "threadId", in: object)
            ?? objectValue(named: "thread", in: object).flatMap { stringValue(named: "id", in: $0) }
        let turnID =
            stringValue(named: "turnId", in: object)
            ?? objectValue(named: "turn", in: object).flatMap { stringValue(named: "id", in: $0) }
        return .init(
            threadID: threadID.map(CodexThreadID.init(rawValue:)),
            turnID: turnID.map(CodexTurnID.init(rawValue:))
        )
    }

    private static func stringValue(named name: String, in object: [String: Any]) -> String? {
        object[name] as? String
    }

    private static func objectValue(named name: String, in object: [String: Any]) -> [String: Any]? {
        object[name] as? [String: Any]
    }
}

private struct TurnCompletedPayload: Decodable {
    var turn: AppServerAPI.Turn.Payload
}

private struct ErrorPayload: Decodable {
    struct ErrorBody: Decodable {
        var message: String?
    }

    var message: String?
    var error: ErrorBody?
}

private struct AgentMessageDeltaPayload: Decodable {
    var itemID: String?
    var delta: String?
    var text: String?
    var phase: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case delta
        case text
        case phase
    }
}

private struct ReasoningSummaryPartPayload: Decodable {
    var itemID: String
    var summaryIndex: Int

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case summaryIndex
    }
}

private struct ReasoningSummaryTextDeltaPayload: Decodable {
    var itemID: String
    var summaryIndex: Int
    var delta: String

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case summaryIndex
        case delta
    }
}

private struct ReasoningTextDeltaPayload: Decodable {
    var itemID: String
    var contentIndex: Int
    var delta: String

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case contentIndex
        case delta
    }
}

private struct ItemPayload: Decodable {
    var item: RawThreadItem
}

private struct ItemProgressPayload: Decodable {
    var itemID: String?
    var delta: String?
    var message: String?
    var changes: AppServerJSONValue?

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case delta
        case message
        case changes
    }
}

private struct ThreadStatusPayload: Decodable {
    struct Status: Decodable {
        var type: String?
    }

    var status: Status?
}

private struct TokenUsagePayload: Decodable {
    var tokenUsage: RawTokenUsage
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
        return item.threadItem
    }
}

private struct RawTokenUsage: Decodable {
    var total: RawTokenUsageBreakdown?
    var modelContextWindow: Int?

    var codexUsage: CodexTokenUsage {
        .init(
            inputTokens: total?.inputTokens,
            outputTokens: total?.outputTokens,
            totalTokens: total?.totalTokens,
            cachedInputTokens: total?.cachedInputTokens,
            reasoningOutputTokens: total?.reasoningOutputTokens,
            modelContextWindow: modelContextWindow
        )
    }
}

private struct RawTokenUsageBreakdown: Decodable {
    var cachedInputTokens: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningOutputTokens: Int?
    var totalTokens: Int?
}

private struct RawThreadItem: Decodable {
    var id: String?
    var type: String?
    var kind: String?
    var text: String?
    var review: String?
    var phase: String?
    var command: String?
    var cwd: String?
    var aggregatedOutput: String?
    var output: String?
    var exitCode: Int?
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
        case aggregatedOutput
        case output
        case exitCode
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
        aggregatedOutput = try container.decodeStringIfPresent(forKey: .aggregatedOutput)
        output = try container.decodeStringIfPresent(forKey: .output)
        exitCode = try? container.decodeIfPresent(Int.self, forKey: .exitCode)
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

    var threadItem: CodexThreadItem {
        let rawType = type ?? kind ?? "unknown"
        let kind = CodexThreadItem.Kind(rawValue: rawType)
        let itemID = id ?? UUID().uuidString
        return .init(
            id: itemID,
            kind: kind,
            content: content(kind: kind, id: itemID, rawType: rawType),
            rawPayload: rawPayload
        )
    }

    private func content(
        kind: CodexThreadItem.Kind,
        id: String,
        rawType: String
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
                    status: status.map(CodexTurnStatus.init(rawValue:))
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
    fileprivate var displayText: String? {
        switch self {
        case .string(let value):
            value
        case .int(let value):
            String(value)
        case .double(let value):
            String(value)
        case .bool(let value):
            value ? "true" : "false"
        case .array, .object:
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        case .null:
            nil
        }
    }
}
