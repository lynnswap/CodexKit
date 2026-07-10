import Foundation
import Synchronization

/// A connection-scoped diagnostic or terminal event emitted by Codex app-server.
public enum CodexConnectionEvent: Equatable, Sendable {
    case warning(CodexDiagnostic)
    case retrying(CodexRetryDiagnostic)
    case deprecation(CodexDeprecationNotice)
    case unknown(CodexRawNotification)
    case terminated(CodexConnectionTermination)
}

/// A user-visible warning associated with the app-server connection.
public struct CodexDiagnostic: Equatable, Sendable {
    public let message: String
    public let method: String?
    public let details: String?

    package init(message: String, method: String? = nil, details: String? = nil) {
        self.message = message
        self.method = method
        self.details = details
    }
}

/// A scheduled retry after an app-server overload response.
public struct CodexRetryDiagnostic: Equatable, Sendable {
    public let requestID: Int
    public let method: String
    public let attempt: Int
    public let delay: Duration
    public let serverError: CodexServerError

    package init(
        requestID: Int,
        method: String,
        attempt: Int,
        delay: Duration,
        serverError: CodexServerError
    ) {
        precondition(attempt > 0, "A retry attempt is one-based.")
        self.requestID = requestID
        self.method = method
        self.attempt = attempt
        self.delay = delay
        self.serverError = serverError
    }
}

/// A deprecation notice emitted by the pinned app-server protocol.
public struct CodexDeprecationNotice: Equatable, Sendable {
    public let summary: String
    public let details: String?

    package init(summary: String, details: String? = nil) {
        self.summary = summary
        self.details = details
    }
}

/// A root-bound, connection-scoped event subscription.
///
/// The subscription does not retain the connection, its supervisor, or a connection lease.
/// Cancelling iteration only releases this subscriber.
public struct CodexConnectionEvents: AsyncSequence, Sendable {
    public typealias Element = CodexConnectionEvent

    private let channel: ConnectionEventSubscriberChannel
    private let cancellation: ConnectionEventSubscriptionCancellation

    fileprivate init(
        channel: ConnectionEventSubscriberChannel,
        cancellation: ConnectionEventSubscriptionCancellation
    ) {
        self.channel = channel
        self.cancellation = cancellation
    }

    public func makeAsyncIterator() -> Iterator {
        .init(channel: channel, cancellation: cancellation)
    }

    public func cancel() async {
        cancellation.cancel()
    }

    package func waitUntilNextSuspendsForTesting() async {
        await channel.waitUntilNextSuspendsForTesting()
    }

    package func claimNextCallForTesting() -> Bool {
        channel.tryBeginNext()
    }

    package func endNextCallForTesting() {
        channel.endNext()
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let channel: ConnectionEventSubscriberChannel
        private let cancellation: ConnectionEventSubscriptionCancellation

        fileprivate init(
            channel: ConnectionEventSubscriberChannel,
            cancellation: ConnectionEventSubscriptionCancellation
        ) {
            self.channel = channel
            self.cancellation = cancellation
        }

        public mutating func next() async -> CodexConnectionEvent? {
            await channel.next(cancellation: cancellation)
        }
    }
}

/// Owns connection diagnostic fan-out and compact terminal replay.
///
/// The termination winner is supplied by `ConnectionTerminationArbiter`; this hub never
/// arbitrates or replaces it.
package final class ConnectionEventHub: Sendable {
    package struct Snapshot: Equatable, Sendable {
        package var subscriberCount: Int
        package var terminal: CodexConnectionTermination?
    }

    private let subscriptionRegistry = ConnectionEventSubscriptionRegistry()

    package init() {}

    deinit {
        subscriptionRegistry.cancelAll()
    }

    package func events() -> CodexConnectionEvents {
        subscriptionRegistry.makeEvents()
    }

    package func yield(_ event: CodexConnectionEvent) {
        if case .terminated = event {
            preconditionFailure("Connection terminal delivery must use finish(with:).")
        }
        subscriptionRegistry.yield(event)
    }

    package func finish(with termination: CodexConnectionTermination) {
        subscriptionRegistry.finish(with: termination)
    }

    package func snapshotForTesting() -> Snapshot {
        subscriptionRegistry.snapshot()
    }
}

private final class ConnectionEventSubscriberChannel: Sendable {
    private enum Phase {
        case open
        case terminalPending(CodexConnectionTermination)
        case finished(CodexConnectionTermination)
        case cancelled
    }

    private struct State {
        var pending: [CodexConnectionEvent] = []
        var waiter: CheckedContinuation<CodexConnectionEvent?, Never>?
        var suspensionObservers: [CheckedContinuation<Void, Never>] = []
        var nextIsActive = false
        var phase = Phase.open
    }

    private static let diagnosticCapacity = 32
    private let state = Mutex(State())

    func yield(_ event: CodexConnectionEvent) {
        let waiter = state.withLock { state -> CheckedContinuation<
            CodexConnectionEvent?, Never
        >? in
            guard case .open = state.phase else {
                return nil
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if state.pending.count == Self.diagnosticCapacity {
                state.pending.removeFirst()
            }
            state.pending.append(event)
            return nil
        }
        waiter?.resume(returning: event)
    }

    func finish(with termination: CodexConnectionTermination) {
        let completion = state.withLock { state -> (
            CheckedContinuation<CodexConnectionEvent?, Never>?,
            [CheckedContinuation<Void, Never>]
        ) in
            switch state.phase {
            case .open:
                state.pending.removeAll(keepingCapacity: false)
                let waiter = state.waiter
                state.waiter = nil
                let observers = state.suspensionObservers
                state.suspensionObservers.removeAll(keepingCapacity: false)
                state.phase = waiter == nil ? .terminalPending(termination) : .finished(termination)
                return (waiter, observers)
            case .terminalPending(let existing), .finished(let existing):
                precondition(
                    existing == termination,
                    "A connection subscriber cannot receive conflicting terminal reasons."
                )
                return (nil, [])
            case .cancelled:
                return (nil, [])
            }
        }
        for observer in completion.1 {
            observer.resume()
        }
        completion.0?.resume(returning: .terminated(termination))
    }

    func cancel() {
        let completion = state.withLock { state -> (
            CheckedContinuation<CodexConnectionEvent?, Never>?,
            [CheckedContinuation<Void, Never>]
        ) in
            guard case .cancelled = state.phase else {
                if case .finished = state.phase {
                    return (nil, [])
                }
                state.phase = .cancelled
                state.pending.removeAll(keepingCapacity: false)
                let waiter = state.waiter
                state.waiter = nil
                let observers = state.suspensionObservers
                state.suspensionObservers.removeAll(keepingCapacity: false)
                return (waiter, observers)
            }
            return (nil, [])
        }
        for observer in completion.1 {
            observer.resume()
        }
        completion.0?.resume(returning: nil)
    }

    func next(
        cancellation: ConnectionEventSubscriptionCancellation
    ) async -> CodexConnectionEvent? {
        precondition(
            tryBeginNext(),
            "CodexConnectionEvents supports one in-flight next() call."
        )
        defer { endNext() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let registration = state.withLock { state -> (
                    CodexConnectionEvent??,
                    [CheckedContinuation<Void, Never>]
                ) in
                    if state.pending.isEmpty == false {
                        return (state.pending.removeFirst(), [])
                    }
                    switch state.phase {
                    case .open:
                        precondition(state.waiter == nil)
                        state.waiter = continuation
                        let observers = state.suspensionObservers
                        state.suspensionObservers.removeAll(keepingCapacity: false)
                        return (nil, observers)
                    case .terminalPending(let termination):
                        state.phase = .finished(termination)
                        return (.some(.terminated(termination)), [])
                    case .finished, .cancelled:
                        return (.some(nil), [])
                    }
                }
                for observer in registration.1 {
                    observer.resume()
                }
                if let immediate = registration.0 {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func tryBeginNext() -> Bool {
        state.withLock { state in
            guard state.nextIsActive == false else {
                return false
            }
            state.nextIsActive = true
            return true
        }
    }

    func endNext() {
        state.withLock { state in
            precondition(state.nextIsActive, "A next() call must own the channel before ending.")
            state.nextIsActive = false
        }
    }

    func waitUntilNextSuspendsForTesting() async {
        await withCheckedContinuation { continuation in
            let isAlreadySuspendedOrFinished = state.withLock { state in
                if state.waiter != nil {
                    return true
                }
                guard case .open = state.phase else {
                    return true
                }
                state.suspensionObservers.append(continuation)
                return false
            }
            if isAlreadySuspendedOrFinished {
                continuation.resume()
            }
        }
    }
}

private final class ConnectionEventSubscriptionCancellation: Sendable {
    private struct State {
        var isCancelled = false
    }

    private let state = Mutex(State())
    private let id: UUID
    private let registry: ConnectionEventSubscriptionRegistry

    init(id: UUID, registry: ConnectionEventSubscriptionRegistry) {
        self.id = id
        self.registry = registry
    }

    func cancel() {
        let shouldRemove = state.withLock { state in
            guard state.isCancelled == false else {
                return false
            }
            state.isCancelled = true
            return true
        }
        if shouldRemove {
            registry.remove(id)
        }
    }

    deinit {
        cancel()
    }
}

private final class ConnectionEventSubscriptionRegistry: Sendable {
    private struct State {
        var channels: [UUID: ConnectionEventSubscriberChannel] = [:]
        var terminal: CodexConnectionTermination?
    }

    private let state = Mutex(State())

    func makeEvents() -> CodexConnectionEvents {
        let id = UUID()
        let channel = ConnectionEventSubscriberChannel()
        let cancellation = ConnectionEventSubscriptionCancellation(id: id, registry: self)
        let terminal = state.withLock { state -> CodexConnectionTermination? in
            guard let terminal = state.terminal else {
                state.channels[id] = channel
                return nil
            }
            return terminal
        }
        if let terminal {
            channel.finish(with: terminal)
        }
        return .init(channel: channel, cancellation: cancellation)
    }

    func yield(_ event: CodexConnectionEvent) {
        state.withLock { state in
            guard state.terminal == nil else {
                return
            }
            for channel in state.channels.values {
                channel.yield(event)
            }
        }
    }

    func remove(_ id: UUID) {
        state.withLock { state in
            state.channels.removeValue(forKey: id)?.cancel()
        }
    }

    func finish(with termination: CodexConnectionTermination) {
        state.withLock { state in
            if let existing = state.terminal {
                precondition(
                    existing == termination,
                    "ConnectionEventHub cannot replace its derived terminal replay."
                )
                return
            }
            state.terminal = termination
            for channel in state.channels.values {
                channel.finish(with: termination)
            }
            state.channels.removeAll(keepingCapacity: false)
        }
    }

    func cancelAll() {
        state.withLock { state in
            for channel in state.channels.values {
                channel.cancel()
            }
            state.channels.removeAll(keepingCapacity: false)
        }
    }

    func snapshot() -> ConnectionEventHub.Snapshot {
        state.withLock { state in
            .init(subscriberCount: state.channels.count, terminal: state.terminal)
        }
    }
}
