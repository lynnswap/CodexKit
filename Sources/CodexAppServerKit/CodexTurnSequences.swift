import Foundation

public struct CodexThreadEventSequence: AsyncSequence, Sendable {
    public typealias Element = CodexThreadEvent

    private let makeStream: @Sendable () -> AsyncThrowingStream<CodexThreadEvent, Error>

    package init(
        makeStream: @escaping @Sendable () -> AsyncThrowingStream<CodexThreadEvent, Error>
    ) {
        self.makeStream = makeStream
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<CodexThreadEvent, Error>.Iterator {
        makeStream().makeAsyncIterator()
    }
}

public struct CodexThreadMessageSequence: AsyncSequence, Sendable {
    public typealias Element = CodexMessage

    private let events: CodexThreadEventSequence

    package init(events: CodexThreadEventSequence) {
        self.events = events
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator

        fileprivate init(events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator) {
            self.events = events
        }

        public mutating func next() async throws -> CodexMessage? {
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
                case .turnStarted, .turnCompleted, .turnFailed, .reasoningSummaryPartAdded,
                    .reasoningDelta, .tokenUsageUpdated, .statusChanged, .closed, .unknown:
                    continue
                }
            }
            return nil
        }
    }
}

public struct CodexThreadTranscriptSequence: AsyncSequence, Sendable {
    public typealias Element = CodexTranscript

    private let events: CodexThreadEventSequence

    package init(events: CodexThreadEventSequence) {
        self.events = events
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private var accumulator = CodexTranscriptAccumulator()

        fileprivate init(events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator) {
            self.events = events
        }

        public mutating func next() async throws -> CodexTranscript? {
            while let event = try await events.next() {
                if accumulator.apply(event) {
                    return accumulator.transcript
                }
            }
            return nil
        }
    }
}

public struct CodexThreadLogSequence: AsyncSequence, Sendable {
    public typealias Element = CodexThreadLogEntry

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    public struct Iterator: AsyncIteratorProtocol {
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

        public mutating func next() async throws -> CodexThreadLogEntry? {
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
                case .turnCompleted, .turnFailed:
                    guard terminalTurnID != nil else {
                        continue
                    }
                    finished = true
                    return nil
                case .closed:
                    finished = true
                    return nil
                case .turnStarted, .tokenUsageUpdated, .statusChanged, .unknown:
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
public struct CodexReviewEventSequence: AsyncSequence, Sendable {
    public typealias Element = CodexReviewEvent

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    public struct Iterator: AsyncIteratorProtocol {
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

        public mutating func next() async throws -> CodexReviewEvent? {
            guard finished == false else {
                return nil
            }
            while let event = try await events.next() {
                guard reviewEventMatches(event, terminalTurnID: terminalTurnID) else {
                    continue
                }
                switch event {
                case .turnCompleted(let response) where isTerminal(event):
                    finished = true
                    return .turnCompleted(accumulator.finalized(response))
                case .turnFailed where isTerminal(event),
                    .closed where isTerminal(event):
                    finished = true
                    return CodexReviewEvent(event)
                case .turnCompleted:
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
            case .turnCompleted(let response):
                terminalTurnID.map { response.turnID == $0 } ?? true
            case .turnFailed(let turnID, _):
                terminalTurnID.map { turnID == $0 } ?? true
            case .closed:
                true
            case .turnStarted, .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta, .tokenUsageUpdated, .statusChanged,
                .unknown:
                false
            }
        }
    }
}

/// Incremental review progress projected from the thread event stream.
public struct CodexReviewProgressSequence: AsyncSequence, Sendable {
    public typealias Element = CodexReviewProgress

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    public struct Iterator: AsyncIteratorProtocol {
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

        public mutating func next() async throws -> CodexReviewProgress? {
            guard finished == false else {
                return nil
            }
            while let event = try await events.next() {
                guard reviewEventMatches(event, terminalTurnID: terminalTurnID) else {
                    continue
                }
                switch event {
                case .turnStarted, .unknown:
                    return .init(phase: .running, transcript: accumulator.transcript, usage: accumulator.usage)
                case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                    .reasoningSummaryPartAdded, .reasoningDelta:
                    _ = accumulator.apply(event)
                    return .init(phase: .running, transcript: accumulator.transcript, usage: accumulator.usage)
                case .tokenUsageUpdated:
                    _ = accumulator.apply(event)
                    return .init(phase: .running, transcript: accumulator.transcript, usage: accumulator.usage)
                case .turnCompleted(let result):
                    guard isTerminal(event) else {
                        continue
                    }
                    finished = true
                    let result = accumulator.finalized(result)
                    if result.errorMessage != nil || result.status?.isFailure == true {
                        return .init(
                            phase: .failed(.turnFailedWithResponse(result)),
                            transcript: result.transcript,
                            usage: result.usage,
                            result: result
                        )
                    }
                    return .init(
                        phase: .completed,
                        transcript: result.transcript,
                        usage: result.usage,
                        result: result
                    )
                case .turnFailed(_, let message):
                    guard isTerminal(event) else {
                        continue
                    }
                    finished = true
                    return .init(
                        phase: .failed(.turnFailed(message)),
                        transcript: accumulator.transcript,
                        usage: accumulator.usage
                    )
                case .statusChanged:
                    return .init(phase: .running, transcript: accumulator.transcript, usage: accumulator.usage)
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
            case .turnCompleted(let response):
                terminalTurnID.map { response.turnID == $0 } ?? true
            case .turnFailed(let turnID, _):
                terminalTurnID.map { turnID == $0 } ?? true
            case .closed:
                true
            case .turnStarted, .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
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
    case .turnCompleted(let response):
        return response.turnID == terminalTurnID
    case .turnFailed(let turnID, _), .itemStarted(_, let turnID), .itemUpdated(_, let turnID),
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
                return nil
            }
            switch event {
            case .started, .unknown:
                return .init(phase: .running, transcript: accumulator.transcript, usage: accumulator.usage)
            case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta:
                _ = accumulator.apply(event)
                return .init(phase: .running, transcript: accumulator.transcript, usage: accumulator.usage)
            case .tokenUsageUpdated:
                _ = accumulator.apply(event)
                return .init(phase: .running, transcript: accumulator.transcript, usage: accumulator.usage)
            case .completed(let result):
                let result = accumulator.finalized(result)
                if result.errorMessage != nil {
                    return .init(
                        phase: .failed(.turnFailedWithResponse(result)),
                        transcript: result.transcript,
                        usage: result.usage,
                        result: result
                    )
                }
                if result.status?.isFailure == true {
                    return .init(
                        phase: .failed(.turnFailedWithResponse(result)),
                        transcript: result.transcript,
                        usage: result.usage,
                        result: result
                    )
                }
                return .init(
                    phase: .completed,
                    transcript: result.transcript,
                    usage: result.usage,
                    result: result
                )
            case .failed(let message):
                return .init(
                    phase: .failed(.turnFailed(message)),
                    transcript: accumulator.transcript,
                    usage: accumulator.usage
                )
            }
        }
    }
}

package struct CodexResponseCollector {
    static func collect(from events: CodexTurnEventSequence) async throws -> CodexResponse {
        var accumulator = CodexResponseAccumulator()
        for try await event in events {
            switch event {
            case .started, .unknown:
                continue
            case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta:
                _ = accumulator.apply(event)
            case .tokenUsageUpdated:
                _ = accumulator.apply(event)
            case .completed(let response):
                let result = accumulator.finalized(response)
                if result.errorMessage != nil {
                    throw CodexAppServerError.turnFailedWithResponse(result)
                }
                if result.status?.isFailure == true {
                    throw CodexAppServerError.turnFailedWithResponse(result)
                }
                return result
            case .failed(let message):
                throw CodexAppServerError.turnFailed(message)
            }
        }
        throw CodexAppServerError.transportClosed
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
        case .started, .completed, .failed, .unknown:
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
        case .turnStarted, .turnCompleted, .turnFailed, .statusChanged, .closed, .unknown:
            return false
        case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
            .reasoningSummaryPartAdded, .reasoningDelta:
            return transcriptAccumulator.apply(event)
        }
    }

    func finalized(_ response: CodexResponse) -> CodexResponse {
        var response = response
        let finalizedTranscript = finalizedTranscript(for: response.transcript)
        if response.finalAnswer?.isEmpty != false {
            response.finalAnswer = transcript.finalAnswer
                ?? finalizedTranscript.finalAnswer
        }
        response.transcript = finalizedTranscript
        if response.usage == nil {
            response.usage = usage
        }
        return response
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
        case .started, .tokenUsageUpdated, .completed, .failed, .unknown:
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
        case .turnStarted, .turnCompleted, .turnFailed, .tokenUsageUpdated, .statusChanged,
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
