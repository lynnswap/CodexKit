import Foundation
import OSLog
import Synchronization

private let supervisorLogger = Logger(
    subsystem: "CodexAppServerKit",
    category: "connection-supervisor"
)

package final class ConnectionCloseAction: Sendable {
    private let action: Mutex<(@Sendable () async -> Void)?>

    package init(action: (@Sendable () async -> Void)? = nil) {
        self.action = Mutex(action)
    }

    package func bind(to supervisor: ConnectionSupervisor) {
        action.withLock { action in
            precondition(action == nil, "Connection close action may be bound exactly once.")
            action = { [weak supervisor] in
                guard let supervisor else {
                    preconditionFailure(
                        "Connection supervisor must outlive every client operation."
                    )
                }
                await supervisor.closeConnection()
            }
        }
    }

    package func closeConnection() async {
        guard let action = action.withLock({ $0 }) else {
            preconditionFailure("Connection close action is not bound.")
        }
        await action()
    }
}

package actor ConnectionSupervisor {
    private enum Phase: Equatable {
        case initialized
        case running
        case closing
        case closed
    }

    private let connection: AppServerConnection
    private var phase: Phase = .initialized
    private var routerTask: Task<Void, Never>?
    private var processExitTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var firstTermination: CodexConnectionTermination?
    private var terminationWaiters:
        [CheckedContinuation<CodexConnectionTermination, Never>] = []

    package init(connection: AppServerConnection) {
        self.connection = connection
    }

    deinit {
        routerTask?.cancel()
        processExitTask?.cancel()
        closeTask?.cancel()
    }

    package func start() {
        guard phase == .initialized else {
            preconditionFailure("ConnectionSupervisor.start() may be called exactly once.")
        }
        phase = .running
        let connection = connection
        routerTask = Task { [weak self, connection] in
            await connection.runInboundEvents { [weak self] signal in
                await self?.recordExitSignal(signal)
            }
        }
        processExitTask = Task { [weak self, connection] in
            let observation = await connection.waitForProcessExit()
            guard Task.isCancelled == false else {
                return
            }
            switch observation {
            case .unavailable:
                return
            case .exited(let status, let observedBeforeTermination):
                await self?.recordExitSignal(.processExited(
                    status: status,
                    observedBeforeTermination: observedBeforeTermination
                ))
            case .failed(let failure):
                await self?.recordExitSignal(.transport(failure))
            }
        }
    }

    package func closeConnection() async {
        if let context = ServerRequestTaskContext.value,
           await connection.signalCloseIfOwned(by: context) {
            _ = recordTermination(.closedByCaller)
            return
        }

        let completion = recordTermination(.closedByCaller)
        await completion.value
    }

    package func waitUntilClosed() async {
        guard let closeTask else {
            preconditionFailure("Connection close has not started.")
        }
        await closeTask.value
    }

    package func serverRequestChildCount() async -> Int {
        await connection.serverRequestChildCount()
    }

    package func terminationForTesting() -> CodexConnectionTermination? {
        firstTermination
    }

    package func waitForTerminationForTesting() async -> CodexConnectionTermination {
        if let firstTermination {
            return firstTermination
        }
        return await withCheckedContinuation { continuation in
            terminationWaiters.append(continuation)
        }
    }

    private func recordExitSignal(_ signal: ConnectionExitSignal) async {
        _ = recordTermination(
            signal.termination,
            processExitObservedBeforeTermination: signal.processExitObservedBeforeTermination
        )
    }

    @discardableResult
    private func recordTermination(
        _ termination: CodexConnectionTermination,
        processExitObservedBeforeTermination: Bool = false
    ) -> Task<Void, Never> {
        if let firstTermination {
            if Self.shouldReplaceEOF(
                firstTermination,
                with: termination,
                processExitObservedBeforeTermination: processExitObservedBeforeTermination
            ) {
                self.firstTermination = termination
            } else if firstTermination != termination {
                supervisorLogger.debug(
                    "Ignoring late connection termination: \(String(describing: termination), privacy: .public)"
                )
            }
            guard let closeTask else {
                preconditionFailure("A terminal reason must publish its close task atomically.")
            }
            return closeTask
        }
        firstTermination = termination
        let terminationWaiters = terminationWaiters
        self.terminationWaiters.removeAll(keepingCapacity: false)
        for waiter in terminationWaiters {
            waiter.resume(returning: termination)
        }
        phase = .closing
        let closeTask = startCloseTask()
        return closeTask
    }

    private func startCloseTask() -> Task<Void, Never> {
        if let closeTask {
            return closeTask
        }
        let connection = connection
        let task = Task { [weak self, connection] in
            let observedAtClose = await connection.beginClose()
            guard let self else {
                return
            }
            await self.runFullClose(observedAtClose: observedAtClose)
        }
        closeTask = task
        return task
    }

    private func runFullClose(
        observedAtClose: JSONRPC.ProcessExitObservation?
    ) async {
        if case .transportFailure(.closed) = firstTermination {
            applyCloseArbitrationObservation(observedAtClose)
        }
        guard let termination = firstTermination else {
            preconditionFailure("Full close requires a terminal reason.")
        }

        await routerTask?.value
        await connection.finishPendingResponsesAfterInboundDrain(
            Self.pendingResponseFailure(for: termination)
        )
        await connection.cancelServerRequestsAndWait()
        let serverRequestChildCount = await connection.serverRequestChildCount()
        precondition(
            serverRequestChildCount == 0,
            "Server-request registry must be empty before domain termination."
        )
        await connection.finishDomains(
            throwing: .connectionTerminated(termination)
        )
        await connection.waitUntilTransportClosed()
        await processExitTask?.value
        await connection.reapProcess()
        phase = .closed
    }

    private func applyCloseArbitrationObservation(
        _ observation: JSONRPC.ProcessExitObservation?
    ) {
        switch observation {
        case .exited(let status, observedBeforeTermination: true):
            firstTermination = .processExited(status: status)
        case .failed(let failure):
            firstTermination = .transportFailure(failure)
        case .none, .unavailable, .exited:
            break
        }
    }

    private nonisolated static func shouldReplaceEOF(
        _ current: CodexConnectionTermination,
        with candidate: CodexConnectionTermination,
        processExitObservedBeforeTermination: Bool
    ) -> Bool {
        guard case .transportFailure(.closed) = current,
              case .processExited = candidate else {
            return false
        }
        return processExitObservedBeforeTermination
    }

    private nonisolated static func pendingResponseFailure(
        for termination: CodexConnectionTermination
    ) -> CodexTransportFailure {
        switch termination {
        case .closedByCaller:
            .closed
        case .transportFailure(let failure):
            failure
        case .processExited(let status):
            .io(
                errno: nil,
                message: status.map { "App-server process exited with status \($0)." }
                    ?? "App-server process exited."
            )
        }
    }
}

package final class AppServerConnectionLease: Sendable {
    private struct State {
        var supervisor: ConnectionSupervisor
        var processTerminationToken: ProcessTerminationToken
    }

    private let state: Mutex<State>

    package init(
        supervisor: ConnectionSupervisor,
        processTerminationToken: ProcessTerminationToken
    ) {
        self.state = Mutex(.init(
            supervisor: supervisor,
            processTerminationToken: processTerminationToken
        ))
    }

    deinit {
        state.withLock { state in
            state.processTerminationToken.terminateOnce()
        }
    }

    package func closeConnection() async {
        let supervisor = state.withLock { $0.supervisor }
        await supervisor.closeConnection()
    }

    package var supervisor: ConnectionSupervisor {
        state.withLock { $0.supervisor }
    }
}
