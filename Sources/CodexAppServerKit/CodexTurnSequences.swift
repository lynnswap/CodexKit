import Foundation

package struct CodexThreadEventSequence: AsyncSequence, Sendable {
    package typealias Element = CodexThreadEvent

    private let makeStream: @Sendable () -> AsyncThrowingStream<CodexThreadEvent, Error>

    package init(
        makeStream: @escaping @Sendable () -> AsyncThrowingStream<CodexThreadEvent, Error>
    ) {
        self.makeStream = makeStream
    }

    package func makeAsyncIterator() -> AsyncThrowingStream<CodexThreadEvent, Error>.Iterator {
        makeStream().makeAsyncIterator()
    }
}

package struct CodexThreadMessageSequence: AsyncSequence, Sendable {
    package typealias Element = CodexMessage

    private let events: CodexThreadEventSequence

    package init(events: CodexThreadEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator

        fileprivate init(events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator) {
            self.events = events
        }

        package mutating func next() async throws -> CodexMessage? {
            while let event = try await events.next() {
                switch event {
                case .message(let message, _):
                    return message
                case .itemCompleted(let item, _):
                    if let message = item.message {
                        return message
                    }
                case .itemStarted, .itemUpdated, .messageDelta:
                    continue
                case .turnStarted, .snapshot, .terminal, .reasoningSummaryPartAdded,
                    .reasoningDelta, .tokenUsageUpdated, .statusChanged, .closed, .unknown:
                    continue
                }
            }
            return nil
        }
    }
}

package struct CodexThreadTranscriptSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTranscript

    private let events: CodexThreadEventSequence

    package init(events: CodexThreadEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private var accumulator = CodexTranscriptAccumulator()

        fileprivate init(events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator) {
            self.events = events
        }

        package mutating func next() async throws -> CodexTranscript? {
            while let event = try await events.next() {
                if accumulator.apply(event) {
                    return accumulator.transcript
                }
            }
            return nil
        }
    }
}

package struct CodexThreadLogSequence: AsyncSequence, Sendable {
    package typealias Element = CodexThreadLogEntry

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private let terminalTurnID: CodexTurnID?
        private var logEntryIndex = 0
        private var finished = false

        fileprivate init(
            events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator,
            terminalTurnID: CodexTurnID?
        ) {
            self.events = events
            self.terminalTurnID = terminalTurnID
        }

        package mutating func next() async throws -> CodexThreadLogEntry? {
            guard finished == false else {
                return nil
            }
            while let event = try await events.next() {
                guard reviewEventMatches(event, terminalTurnID: terminalTurnID) else {
                    continue
                }
                switch event {
                case .itemStarted(let item, let turnID):
                    return .itemStarted(item, turnID: turnID)
                case .itemUpdated(let item, let turnID):
                    return .itemUpdated(item, turnID: turnID)
                case .itemCompleted(let item, let turnID):
                    return .itemCompleted(item, turnID: turnID)
                case .message(let message, let turnID):
                    let item = CodexThreadItem(
                        id: message.id,
                        kind: message.role == .user ? .userMessage : .agentMessage,
                        content: .message(message)
                    )
                    return .itemCompleted(item, turnID: turnID)
                case .messageDelta(let delta, let turnID):
                    return .messageDelta(delta, turnID: turnID, id: nextDeltaLogEntryID(for: delta))
                case .reasoningSummaryPartAdded(let part, let turnID):
                    return .reasoningPartStarted(part, turnID: turnID)
                case .reasoningDelta(let delta, let turnID):
                    return .reasoningDelta(delta, turnID: turnID)
                case .terminal:
                    guard terminalTurnID != nil else {
                        continue
                    }
                    finished = true
                    return nil
                case .closed:
                    finished = true
                    return nil
                case .turnStarted, .snapshot, .tokenUsageUpdated, .statusChanged, .unknown:
                    continue
                }
            }
            finished = true
            return nil
        }

        private mutating func nextDeltaLogEntryID(for delta: CodexMessageDelta) -> String {
            defer {
                logEntryIndex += 1
            }
            return "\(delta.itemID ?? "agent-message-delta"):\(logEntryIndex)"
        }
    }
}

/// Projection over a thread event stream for a `CodexReviewSession`.
package struct CodexReviewEventSequence: AsyncSequence, Sendable {
    package typealias Element = CodexReviewEvent

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private let terminalTurnID: CodexTurnID?
        private var accumulator = CodexResponseAccumulator()
        private var finished = false

        fileprivate init(
            events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator,
            terminalTurnID: CodexTurnID?
        ) {
            self.events = events
            self.terminalTurnID = terminalTurnID
        }

        package mutating func next() async throws -> CodexReviewEvent? {
            guard finished == false else {
                return nil
            }
            while let event = try await events.next() {
                guard reviewEventMatches(event, terminalTurnID: terminalTurnID) else {
                    continue
                }
                switch event {
                case .terminal(let outcome) where isTerminal(event):
                    finished = true
                    return .terminal(accumulator.finalized(outcome))
                case .closed where isTerminal(event):
                    finished = true
                    return nil
                case .terminal:
                    continue
                default:
                    _ = accumulator.apply(event)
                    return CodexReviewEvent(event)
                }
            }
            finished = true
            return nil
        }

        private func isTerminal(_ event: CodexThreadEvent) -> Bool {
            switch event {
            case .terminal(let outcome):
                terminalTurnID.map { outcome.response.turnID == $0 } ?? true
            case .closed:
                true
            case .turnStarted, .snapshot, .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta, .tokenUsageUpdated, .statusChanged,
                .unknown:
                false
            }
        }
    }
}

/// Incremental review progress projected from the thread event stream.
package struct CodexReviewProgressSequence: AsyncSequence, Sendable {
    package typealias Element = CodexReviewProgress

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private let terminalTurnID: CodexTurnID?
        private var accumulator = CodexResponseAccumulator()
        private var finished = false

        fileprivate init(
            events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator,
            terminalTurnID: CodexTurnID?
        ) {
            self.events = events
            self.terminalTurnID = terminalTurnID
        }

        package mutating func next() async throws -> CodexReviewProgress? {
            guard finished == false else {
                return nil
            }
            while let event = try await events.next() {
                guard reviewEventMatches(event, terminalTurnID: terminalTurnID) else {
                    continue
                }
                switch event {
                case .turnStarted, .snapshot, .unknown:
                    return .running(transcript: accumulator.transcript, usage: accumulator.usage)
                case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                    .reasoningSummaryPartAdded, .reasoningDelta:
                    _ = accumulator.apply(event)
                    return .running(transcript: accumulator.transcript, usage: accumulator.usage)
                case .tokenUsageUpdated:
                    _ = accumulator.apply(event)
                    return .running(transcript: accumulator.transcript, usage: accumulator.usage)
                case .terminal(let outcome):
                    guard isTerminal(event) else {
                        continue
                    }
                    finished = true
                    return .terminal(accumulator.finalized(outcome))
                case .statusChanged:
                    return .running(transcript: accumulator.transcript, usage: accumulator.usage)
                case .closed:
                    finished = true
                    return nil
                }
            }
            finished = true
            return nil
        }

        private func isTerminal(_ event: CodexThreadEvent) -> Bool {
            switch event {
            case .terminal(let outcome):
                terminalTurnID.map { outcome.response.turnID == $0 } ?? true
            case .closed:
                true
            case .turnStarted, .snapshot, .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta, .tokenUsageUpdated, .statusChanged,
                .unknown:
                false
            }
        }
    }
}

private func reviewEventMatches(
    _ event: CodexThreadEvent,
    terminalTurnID: CodexTurnID?
) -> Bool {
    guard let terminalTurnID else {
        return true
    }
    switch event {
    case .turnStarted(let turnID):
        return turnID == terminalTurnID
    case .snapshot(let snapshot):
        return snapshot.id == terminalTurnID
    case .terminal(let outcome):
        return outcome.response.turnID == terminalTurnID
    case .itemStarted(_, let turnID), .itemUpdated(_, let turnID),
         .itemCompleted(_, let turnID), .message(_, let turnID), .messageDelta(_, let turnID),
         .reasoningSummaryPartAdded(_, let turnID), .reasoningDelta(_, let turnID),
         .tokenUsageUpdated(_, let turnID):
        return turnID == terminalTurnID
    case .unknown(let raw):
        return raw.turnID.map { $0 == terminalTurnID } ?? true
    case .statusChanged:
        return true
    case .closed:
        return true
    }
}

package struct CodexTurnEventSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTurnEvent

    private let makeStream: @Sendable () -> AsyncThrowingStream<CodexTurnEvent, Error>

    package init(makeStream: @escaping @Sendable () -> AsyncThrowingStream<CodexTurnEvent, Error>) {
        self.makeStream = makeStream
    }

    package func makeAsyncIterator() -> AsyncThrowingStream<CodexTurnEvent, Error>.Iterator {
        makeStream().makeAsyncIterator()
    }
}

package struct CodexTurnProgressSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTurnProgress

    private let events: CodexTurnEventSequence

    package init(events: CodexTurnEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexTurnEvent, Error>.Iterator
        private var accumulator = CodexResponseAccumulator()

        fileprivate init(events: AsyncThrowingStream<CodexTurnEvent, Error>.Iterator) {
            self.events = events
        }

        package mutating func next() async throws -> CodexTurnProgress? {
            guard let event = try await events.next() else {
                try Task.checkCancellation()
                return nil
            }
            switch event {
            case .started, .snapshot, .unknown:
                return .running(transcript: accumulator.transcript, usage: accumulator.usage)
            case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta:
                _ = accumulator.apply(event)
                return .running(transcript: accumulator.transcript, usage: accumulator.usage)
            case .tokenUsageUpdated:
                _ = accumulator.apply(event)
                return .running(transcript: accumulator.transcript, usage: accumulator.usage)
            case .terminal(let outcome):
                return .terminal(accumulator.finalized(outcome))
            }
        }
    }
}

package struct CodexResponseCollector {
    static func collect(from events: CodexTurnEventSequence) async throws -> CodexTurnOutcome {
        var accumulator = CodexResponseAccumulator()
        for try await event in events {
            switch event {
            case .started, .snapshot, .unknown:
                continue
            case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta:
                _ = accumulator.apply(event)
            case .tokenUsageUpdated:
                _ = accumulator.apply(event)
            case .terminal(let outcome):
                return accumulator.finalized(outcome)
            }
        }
        try Task.checkCancellation()
        throw CodexAppServerError.connectionTerminated(.transportFailure(.closed))
    }
}

private struct CodexResponseAccumulator {
    private var transcriptAccumulator = CodexTranscriptAccumulator()
    private(set) var usage: CodexTokenUsage?

    var transcript: CodexTranscript {
        transcriptAccumulator.transcript
    }

    mutating func apply(_ event: CodexTurnEvent) -> Bool {
        switch event {
        case .tokenUsageUpdated(let newUsage):
            usage = newUsage
            return true
        case .started, .snapshot, .terminal, .unknown:
            return false
        case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
            .reasoningSummaryPartAdded, .reasoningDelta:
            return transcriptAccumulator.apply(event)
        }
    }

    mutating func apply(_ event: CodexThreadEvent) -> Bool {
        switch event {
        case .tokenUsageUpdated(let newUsage, _):
            usage = newUsage
            return true
        case .turnStarted, .snapshot, .terminal, .statusChanged, .closed, .unknown:
            return false
        case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
            .reasoningSummaryPartAdded, .reasoningDelta:
            return transcriptAccumulator.apply(event)
        }
    }

    func finalized(_ response: CodexResponse) -> CodexResponse {
        var response = response
        let finalizedTranscript = finalizedTranscript(for: response.transcript)
        response.transcript = finalizedTranscript
        if response.usage == nil {
            response.usage = usage
        }
        return response
    }

    func finalized(_ outcome: CodexTurnOutcome) -> CodexTurnOutcome {
        switch outcome {
        case .completed(let response):
            .completed(finalized(response))
        case .interrupted(let response):
            .interrupted(finalized(response))
        case .failed(let failedTurn):
            .failed(.init(response: finalized(failedTurn.response), error: failedTurn.error))
        case .invalidTerminalStatus(let rawStatus, let error, let response):
            .invalidTerminalStatus(
                rawStatus: rawStatus,
                error: error,
                response: finalized(response)
            )
        }
    }

    private func finalizedTranscript(for terminalTranscript: CodexTranscript) -> CodexTranscript {
        let liveTranscript = transcript
        guard terminalTranscript.items.isEmpty == false else {
            return liveTranscript
        }
        guard terminalTranscript.reviewOutputText == nil else {
            return terminalTranscript
        }

        var mergedItems = terminalTranscript.items
        var didMerge = false
        for liveItem in liveTranscript.items where liveItem.kind == .exitedReviewMode {
            guard liveItem.text?.isEmpty == false else {
                continue
            }
            if let index = mergedItems.firstIndex(where: { $0.id == liveItem.id && $0.kind == liveItem.kind }) {
                guard mergedItems[index].text?.isEmpty != false else {
                    continue
                }
                mergedItems[index] = liveItem
            } else {
                mergedItems.append(liveItem)
            }
            didMerge = true
        }
        guard didMerge else {
            return terminalTranscript
        }
        return CodexTranscript(items: mergedItems)
    }
}

private struct CodexTranscriptAccumulator {
    private var items: [CodexThreadItem] = []
    private var itemIndexesByID: [String: Int] = [:]
    private var messageDeltaTextByItemID: [String: String] = [:]
    private var reasoningDeltaTextByPartID: [String: String] = [:]

    var transcript: CodexTranscript {
        .init(items: items)
    }

    mutating func apply(_ event: CodexTurnEvent) -> Bool {
        switch event {
        case .itemStarted(let item), .itemUpdated(let item), .itemCompleted(let item):
            upsert(item)
            return true
        case .message(let message):
            upsert(
                .init(
                    id: message.id,
                    kind: message.role == .user ? .userMessage : .agentMessage,
                    content: .message(message)
                ),
                replacingFallbackID: message.role == .assistant
                    ? CodexAgentMessageFallbackID.unscoped
                    : nil
            )
            return true
        case .messageDelta(let delta):
            append(delta)
            return true
        case .reasoningSummaryPartAdded(let part):
            start(part)
            return true
        case .reasoningDelta(let delta):
            append(delta)
            return true
        case .started, .snapshot, .tokenUsageUpdated, .terminal, .unknown:
            return false
        }
    }

    mutating func apply(_ event: CodexThreadEvent) -> Bool {
        switch event {
        case .itemStarted(let item, _), .itemUpdated(let item, _), .itemCompleted(let item, _):
            upsert(item)
            return true
        case .message(let message, let turnID):
            upsert(
                .init(
                    id: message.id,
                    kind: message.role == .user ? .userMessage : .agentMessage,
                    content: .message(message)
                ),
                replacingFallbackID: message.role == .assistant
                    ? scopedFallbackMessageID(turnID: turnID)
                    : nil
            )
            return true
        case .messageDelta(let delta, let turnID):
            append(delta, fallbackItemID: scopedFallbackMessageID(turnID: turnID))
            return true
        case .reasoningSummaryPartAdded(let part, _):
            start(part)
            return true
        case .reasoningDelta(let delta, _):
            append(delta)
            return true
        case .turnStarted, .snapshot, .terminal, .tokenUsageUpdated, .statusChanged,
            .closed, .unknown:
            return false
        }
    }

    private mutating func upsert(
        _ item: CodexThreadItem,
        replacingFallbackID fallbackID: String? = nil
    ) {
        if item.kind == .reasoning && item.id.contains(":summary:") == false
            && item.id.contains(":content:") == false
        {
            removeReasoningParts(parentItemID: item.id)
        }
        if let fallbackID,
           fallbackID != item.id,
           item.kind == .agentMessage,
           itemIndexesByID[item.id] == nil,
           let fallbackIndex = itemIndexesByID.removeValue(forKey: fallbackID)
        {
            messageDeltaTextByItemID.removeValue(forKey: fallbackID)
            itemIndexesByID[item.id] = fallbackIndex
            items[fallbackIndex] = item
            return
        }
        if let index = itemIndexesByID[item.id] {
            items[index] = item
        } else {
            itemIndexesByID[item.id] = items.count
            items.append(item)
        }
    }

    private mutating func append(
        _ delta: CodexMessageDelta,
        fallbackItemID: String = CodexAgentMessageFallbackID.unscoped
    ) {
        let itemID = delta.itemID ?? fallbackItemID
        let text = (messageDeltaTextByItemID[itemID] ?? "") + delta.text
        messageDeltaTextByItemID[itemID] = text
        let message = CodexMessage(
            id: itemID,
            role: .assistant,
            phase: delta.phase,
            text: text
        )
        upsert(.init(id: itemID, kind: .agentMessage, content: .message(message)))
    }

    private func scopedFallbackMessageID(turnID: CodexTurnID?) -> String {
        CodexAgentMessageFallbackID.scoped(turnID: turnID)
    }

    private mutating func start(_ part: CodexReasoningPart) {
        upsert(.init(
            id: part.id,
            kind: .reasoning,
            content: .reasoning(.empty)
        ))
    }

    private mutating func append(_ delta: CodexReasoningDelta) {
        let text = (reasoningDeltaTextByPartID[delta.id] ?? "") + delta.delta
        reasoningDeltaTextByPartID[delta.id] = text
        let reasoning: CodexReasoning
        switch delta.part.kind {
        case .summary:
            reasoning = .init(summary: text)
        case .text:
            reasoning = .init(content: text)
        }
        upsert(.init(id: delta.id, kind: .reasoning, content: .reasoning(reasoning)))
    }

    private mutating func removeReasoningParts(parentItemID: String) {
        let prefixes = ["\(parentItemID):summary:", "\(parentItemID):content:"]
        items.removeAll { item in
            prefixes.contains { item.id.hasPrefix($0) }
        }
        reasoningDeltaTextByPartID = reasoningDeltaTextByPartID.filter { id, _ in
            prefixes.contains { id.hasPrefix($0) } == false
        }
        itemIndexesByID = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { index, item in (item.id, index) }
        )
    }
}
