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

    private let events: CodexTurnEventSequence
    private let turnID: CodexTurnID

    package init(events: CodexTurnEventSequence, turnID: CodexTurnID) {
        self.events = events
        self.turnID = turnID
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), turnID: turnID)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexTurnEventSequence.Iterator
        private let turnID: CodexTurnID
        private var finished = false

        fileprivate init(
            events: CodexTurnEventSequence.Iterator,
            turnID: CodexTurnID
        ) {
            self.events = events
            self.turnID = turnID
        }

        package mutating func next() async throws -> CodexReviewEvent? {
            guard finished == false else {
                return nil
            }
            guard let event = try await events.next() else {
                finished = true
                return nil
            }
            switch event {
            case .terminal(let outcome):
                finished = true
                return .terminal(outcome)
            case .started, .snapshot, .itemStarted, .itemUpdated, .itemCompleted, .message,
                 .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
                 .tokenUsageUpdated, .unknown:
                return CodexReviewEvent(event, turnID: turnID)
            }
        }
    }
}

/// Incremental review progress projected from the thread event stream.
package struct CodexReviewProgressSequence: AsyncSequence, Sendable {
    package typealias Element = CodexReviewProgress

    private let turnID: CodexTurnID
    private let store: TurnReplayStore
    private let state: TurnGenerationHandleState

    package init(
        turnID: CodexTurnID,
        store: TurnReplayStore,
        state: TurnGenerationHandleState
    ) {
        self.turnID = turnID
        self.store = store
        self.state = state
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(turnID: turnID, store: store, state: state)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private let turnID: CodexTurnID
        private let store: TurnReplayStore
        private let state: TurnGenerationHandleState
        private var events: TurnReplayProgressEvents.Iterator?

        fileprivate init(
            turnID: CodexTurnID,
            store: TurnReplayStore,
            state: TurnGenerationHandleState
        ) {
            self.turnID = turnID
            self.store = store
            self.state = state
        }

        package mutating func next() async throws -> CodexReviewProgress? {
            if events == nil {
                events = try await store.progressEvents(for: turnID, state: state)
                    .makeAsyncIterator()
            }
            guard var iterator = events else {
                preconditionFailure("A replay progress iterator must be installed before use.")
            }
            let value = try await iterator.next()
            events = iterator
            return value
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

    private let turnID: CodexTurnID
    private let store: TurnReplayStore
    private let state: TurnGenerationHandleState

    package init(
        turnID: CodexTurnID,
        store: TurnReplayStore,
        state: TurnGenerationHandleState
    ) {
        self.turnID = turnID
        self.store = store
        self.state = state
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(turnID: turnID, store: store, state: state)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private let turnID: CodexTurnID
        private let store: TurnReplayStore
        private let state: TurnGenerationHandleState
        private var events: TurnReplayEvents.Iterator?

        fileprivate init(
            turnID: CodexTurnID,
            store: TurnReplayStore,
            state: TurnGenerationHandleState
        ) {
            self.turnID = turnID
            self.store = store
            self.state = state
        }

        package mutating func next() async throws -> CodexTurnEvent? {
            if events == nil {
                events = try await store.events(for: turnID, state: state)
                    .makeAsyncIterator()
            }
            guard var iterator = events else {
                preconditionFailure("A turn replay iterator must be installed before use.")
            }
            let value = try await iterator.next()
            events = iterator
            return value
        }
    }
}

package struct CodexTurnProgressSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTurnProgress

    private let turnID: CodexTurnID
    private let store: TurnReplayStore
    private let state: TurnGenerationHandleState

    package init(
        turnID: CodexTurnID,
        store: TurnReplayStore,
        state: TurnGenerationHandleState
    ) {
        self.turnID = turnID
        self.store = store
        self.state = state
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(turnID: turnID, store: store, state: state)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexReviewProgressSequence.Iterator

        fileprivate init(
            turnID: CodexTurnID,
            store: TurnReplayStore,
            state: TurnGenerationHandleState
        ) {
            self.events = CodexReviewProgressSequence(
                turnID: turnID,
                store: store,
                state: state
            ).makeAsyncIterator()
        }

        package mutating func next() async throws -> CodexTurnProgress? {
            switch try await events.next() {
            case .running(let transcript, let usage):
                .running(transcript: transcript, usage: usage)
            case .terminal(let outcome):
                .terminal(outcome)
            case nil:
                nil
            }
        }
    }
}

package struct CodexTurnMessageSequence: AsyncSequence, Sendable {
    package typealias Element = CodexMessage
    private let events: CodexTurnEventSequence

    package init(events: CodexTurnEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexTurnEventSequence.Iterator
        private var pendingMessages: [CodexMessage] = []
        private var pendingMessageIndex = 0

        fileprivate init(events: CodexTurnEventSequence.Iterator) {
            self.events = events
        }

        package mutating func next() async throws -> CodexMessage? {
            if let pending = nextPendingMessage() {
                return pending
            }
            while let event = try await events.next() {
                switch event {
                case .message(let message):
                    return message
                case .itemCompleted(let item):
                    if let message = item.message {
                        return message
                    }
                case .snapshot(let snapshot):
                    pendingMessages = snapshot.items.compactMap(\.message)
                    pendingMessageIndex = 0
                    if let pending = nextPendingMessage() {
                        return pending
                    }
                case .started, .terminal, .itemStarted, .itemUpdated,
                     .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
                     .tokenUsageUpdated, .unknown:
                    continue
                }
            }
            return nil
        }

        private mutating func nextPendingMessage() -> CodexMessage? {
            guard pendingMessageIndex < pendingMessages.count else {
                pendingMessages.removeAll(keepingCapacity: false)
                pendingMessageIndex = 0
                return nil
            }
            defer { pendingMessageIndex += 1 }
            return pendingMessages[pendingMessageIndex]
        }
    }
}

package struct CodexTurnTranscriptSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTranscript
    private let events: CodexTurnEventSequence

    package init(events: CodexTurnEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexTurnEventSequence.Iterator
        private var accumulator = CodexTranscriptAccumulator()

        fileprivate init(events: CodexTurnEventSequence.Iterator) {
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

package struct CodexTurnLogSequence: AsyncSequence, Sendable {
    package typealias Element = CodexThreadLogEntry
    private let events: CodexTurnEventSequence
    private let turnID: CodexTurnID

    package init(events: CodexTurnEventSequence, turnID: CodexTurnID) {
        self.events = events
        self.turnID = turnID
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), turnID: turnID)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexTurnEventSequence.Iterator
        private let turnID: CodexTurnID
        private var logEntryIndex = 0
        private var pendingSnapshotItems: [CodexThreadItem] = []
        private var pendingSnapshotIndex = 0

        fileprivate init(events: CodexTurnEventSequence.Iterator, turnID: CodexTurnID) {
            self.events = events
            self.turnID = turnID
        }

        package mutating func next() async throws -> CodexThreadLogEntry? {
            if let pending = nextPendingSnapshotEntry() {
                return pending
            }
            while let event = try await events.next() {
                switch event {
                case .itemStarted(let item):
                    return .itemStarted(item, turnID: turnID)
                case .itemUpdated(let item):
                    return .itemUpdated(item, turnID: turnID)
                case .itemCompleted(let item):
                    return .itemCompleted(item, turnID: turnID)
                case .message(let message):
                    return .itemCompleted(
                        .init(
                            id: message.id,
                            kind: message.role == .user ? .userMessage : .agentMessage,
                            content: .message(message)
                        ),
                        turnID: turnID
                    )
                case .messageDelta(let delta):
                    defer { logEntryIndex += 1 }
                    return .messageDelta(
                        delta,
                        turnID: turnID,
                        id: "\(delta.itemID ?? "agent-message-delta"):\(logEntryIndex)"
                    )
                case .reasoningSummaryPartAdded(let part):
                    return .reasoningPartStarted(part, turnID: turnID)
                case .reasoningDelta(let delta):
                    return .reasoningDelta(delta, turnID: turnID)
                case .terminal:
                    return nil
                case .snapshot(let snapshot):
                    pendingSnapshotItems = snapshot.items
                    pendingSnapshotIndex = 0
                    if let pending = nextPendingSnapshotEntry() {
                        return pending
                    }
                case .started, .tokenUsageUpdated, .unknown:
                    continue
                }
            }
            return nil
        }

        private mutating func nextPendingSnapshotEntry() -> CodexThreadLogEntry? {
            guard pendingSnapshotIndex < pendingSnapshotItems.count else {
                pendingSnapshotItems.removeAll(keepingCapacity: false)
                pendingSnapshotIndex = 0
                return nil
            }
            defer { pendingSnapshotIndex += 1 }
            return .itemCompleted(
                pendingSnapshotItems[pendingSnapshotIndex],
                turnID: turnID
            )
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

    var transcript: CodexTranscript {
        .init(items: items)
    }

    mutating func apply(_ event: CodexTurnEvent) -> Bool {
        switch event {
        case .snapshot(let snapshot):
            let previousItems = items
            replace(with: snapshot.items)
            return items != previousItems
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
            upsert(Self.currentItem(from: delta))
            return true
        case .reasoningSummaryPartAdded(let part):
            upsert(Self.currentItem(from: part))
            return true
        case .reasoningDelta(let delta):
            upsert(Self.currentItem(from: delta))
            return true
        case .started, .tokenUsageUpdated, .terminal, .unknown:
            return false
        }
    }

    private mutating func replace(with snapshotItems: [CodexThreadItem]) {
        items.removeAll(keepingCapacity: true)
        itemIndexesByID.removeAll(keepingCapacity: true)
        for item in snapshotItems {
            upsert(item)
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
        case .messageDelta(let delta, _):
            upsert(Self.currentItem(from: delta))
            return true
        case .reasoningSummaryPartAdded(let part, _):
            upsert(Self.currentItem(from: part))
            return true
        case .reasoningDelta(let delta, _):
            upsert(Self.currentItem(from: delta))
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
        if let fallbackID,
           fallbackID != item.id,
           item.kind == .agentMessage,
           itemIndexesByID[item.id] == nil,
           let fallbackIndex = itemIndexesByID.removeValue(forKey: fallbackID)
        {
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

    private func scopedFallbackMessageID(turnID: CodexTurnID?) -> String {
        CodexAgentMessageFallbackID.scoped(turnID: turnID)
    }

    private static func currentItem(from delta: CodexMessageDelta) -> CodexThreadItem {
        guard let currentItem = delta.currentItem else {
            preconditionFailure("CodexMessageDelta must be emitted through CodexItemReducer.")
        }
        return currentItem
    }

    private static func currentItem(from part: CodexReasoningPart) -> CodexThreadItem {
        guard let currentItem = part.currentItem else {
            preconditionFailure("CodexReasoningPart must be emitted through CodexItemReducer.")
        }
        return currentItem
    }

    private static func currentItem(from delta: CodexReasoningDelta) -> CodexThreadItem {
        guard let currentItem = delta.currentItem else {
            preconditionFailure("CodexReasoningDelta must be emitted through CodexItemReducer.")
        }
        return currentItem
    }
}
