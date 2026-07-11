import Foundation
import OSLog

private let notificationRouterLogger = Logger(
    subsystem: "CodexAppServerKit",
    category: "notification-router"
)

package actor CodexAppServerNotificationRouter {
    private typealias NotificationContext = AppServerNotificationDecoder.Context

    private var threadIDByTurnID: [CodexTurnID: CodexThreadID] = [:]
    private var itemReducer = CodexItemReducer()
    private let accountEventHub: AccountEventHub
    package nonisolated let turnReplayStore: TurnReplayStore
    package nonisolated let threadEventHub: ThreadEventHub

    package init(
        client: AppServerClient,
        turnReplayStore: TurnReplayStore,
        threadEventHub: ThreadEventHub,
        accountEventHub: AccountEventHub = .init()
    ) {
        _ = client
        self.turnReplayStore = turnReplayStore
        self.threadEventHub = threadEventHub
        self.accountEventHub = accountEventHub
    }

    package nonisolated func events(for threadID: CodexThreadID) -> CodexThreadEventSequence {
        threadEventHub.events(for: threadID)
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
    package nonisolated func threadSubscriberCountForTesting(for threadID: CodexThreadID) -> Int {
        threadEventHub.snapshotForTesting(threadID: threadID).subscriberCount
    }

    package func itemSnapshotForTesting(
        turnID: CodexTurnID,
        itemID: String
    ) -> CodexThreadItem? {
        itemReducer.item(turnID: turnID, itemID: itemID)
    }

    package nonisolated func resetThreadEventGeneration(_ threadID: CodexThreadID) {
        threadEventHub.resetGeneration(for: threadID)
    }

    package func adoptDetachedThreadEventGeneration(
        _ threadID: CodexThreadID,
        including turnID: CodexTurnID
    ) {
        threadEventHub.beginGeneration(for: threadID, including: turnID)
        seedTurn(turnID, threadID: threadID)
    }

    package func route(
        _ decoded: AppServerNotificationDecoder.DecodedNotification
    ) async throws {
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
            _ = await turnReplayStore.finishIfTracked(outcome)
            if let threadID = context.threadID ?? threadIDByTurnID[turnID] {
                try routeThreadEvent(.terminal(outcome), threadID: threadID)
            }
            threadIDByTurnID.removeValue(forKey: turnID)

        case .item(let mutation):
            guard let turnID = context.turnID else {
                preconditionFailure("Validated item notification lost turnId.")
            }
            let event = try reduceItemEvent(mutation, turnID: turnID)
            if let threadID = context.threadID ?? threadIDByTurnID[turnID] {
                try routeThreadEvent(
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
                try routeThreadEvent(.turnStarted(turnID), threadID: threadID)
            }
            let event = CodexTurnEvent.started(turnID)
            recordReplayDisposition(
                await turnReplayStore.routeIfTracked(event, for: turnID),
                turnID: turnID
            )

        case .threadStatus(let status):
            if let threadID = context.threadID {
                try routeThreadEvent(.statusChanged(status), threadID: threadID)
            }

        case .tokenUsage(let usage):
            if let threadID = context.threadID {
                try routeThreadEvent(
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
                try routeThreadEvent(.closed, threadID: threadID)
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
                try routeThreadEvent(.unknown(raw), threadID: threadID)
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

    private func routeThreadEvent(_ event: CodexThreadEvent, threadID: CodexThreadID) throws {
        let overflowCount = try threadEventHub.route(event, for: threadID)
        if overflowCount > 0 {
            notificationRouterLogger.warning(
                "Compacted \(overflowCount, privacy: .public) slow thread event subscriber(s) for \(threadID.rawValue, privacy: .public)"
            )
        }
        if case .closed = event {
            let turnIDs = threadIDByTurnID.compactMap { entry in
                entry.value == threadID ? entry.key : nil
            }
            for turnID in turnIDs {
                itemReducer.release(turnID: turnID)
                threadIDByTurnID.removeValue(forKey: turnID)
            }
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

    package func finishAll(throwing error: CodexAppServerError) async {
        itemReducer.releaseAll()
        threadEventHub.finish(throwing: error)
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
