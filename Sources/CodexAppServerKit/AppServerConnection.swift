import Foundation
import OSLog

private let connectionLogger = Logger(
    subsystem: "CodexAppServerKit",
    category: "app-server-connection"
)

package enum ConnectionExitSignal: Equatable, Sendable {
    case transport(CodexTransportFailure)
    case processExited(status: Int32?, observedBeforeTermination: Bool)

    package var termination: CodexConnectionTermination {
        switch self {
        case .transport(let failure):
            .transportFailure(failure)
        case .processExited(let status, _):
            .processExited(status: status)
        }
    }

    package var processExitObservedBeforeTermination: Bool {
        if case .processExited(_, let observedBeforeTermination) = self {
            return observedBeforeTermination
        }
        return false
    }
}

package actor AppServerConnection {
    package let client: AppServerClient
    package let router: CodexAppServerNotificationRouter

    private let transport: any JSONRPC.Transport
    private let serverRequestRegistry: ServerRequestRegistry
    private let notificationDecoder = AppServerNotificationDecoder()

    package init(
        transport: any JSONRPC.Transport,
        client: AppServerClient,
        router: CodexAppServerNotificationRouter,
        serverRequestHandler: @escaping CodexAppServerRequestHandler,
        serverRequestDiagnosticHandler: @escaping ServerRequestRegistry.DiagnosticHandler = {
            diagnostic in
            connectionLogger.error(
                "App-server request registry: \(String(describing: diagnostic), privacy: .public)"
            )
        }
    ) {
        self.transport = transport
        self.client = client
        self.router = router
        self.serverRequestRegistry = ServerRequestRegistry(
            handler: serverRequestHandler,
            responder: { [transport] id, response in
                try await transport.respond(to: id, with: response)
            },
            diagnosticHandler: serverRequestDiagnosticHandler
        )
    }

    package func runInboundEvents(
        onExit: @escaping @Sendable (ConnectionExitSignal) async -> Void
    ) async {
        do {
            while let event = try await transport.nextInboundEvent() {
                try await apply(event)
            }
            await onExit(.transport(.closed))
        } catch is CancellationError {
            return
        } catch let failure as CodexTransportFailure {
            await onExit(.transport(failure))
            await drainResponsesOnly()
        } catch let error as CodexAppServerError {
            connectionLogger.error(
                "App-server domain routing failed: \(error.localizedDescription, privacy: .public)"
            )
            await onExit(.transport(Self.transportFailure(for: error)))
            await drainResponsesOnly()
        } catch {
            let failure = CodexTransportFailure.protocolViolation(
                message: error.localizedDescription,
                rawData: nil
            )
            await onExit(.transport(failure))
            await drainResponsesOnly()
        }
    }

    package func waitForProcessExit() async -> JSONRPC.ProcessExitObservation {
        await transport.waitForProcessExit()
    }

    package func signalCloseIfOwned(by context: ServerRequestTaskContext.Value) async -> Bool {
        await serverRequestRegistry.signalCloseIfOwned(by: context)
    }

    package func beginClose() async -> JSONRPC.ProcessExitObservation? {
        await serverRequestRegistry.beginClosing()
        return await transport.beginClose()
    }

    package func finishPendingResponsesAfterInboundDrain(
        _ failure: CodexTransportFailure
    ) async {
        await transport.finishPendingResponsesAfterInboundDrain(failure)
    }

    package func cancelServerRequestsAndWait() async {
        await serverRequestRegistry.cancelAllAndWait()
    }

    package func finishDomains(throwing error: CodexAppServerError) async {
        await router.finishAll(throwing: error)
    }

    package func waitUntilTransportClosed() async {
        await transport.waitUntilClosed()
    }

    package func reapProcess() async {
        await transport.reapProcess()
    }

    package func serverRequestChildCount() async -> Int {
        await serverRequestRegistry.childCount()
    }

    package func waitUntilServerRequestsIdle() async {
        await serverRequestRegistry.waitUntilIdle()
    }

    package func waitForServerRequestReceiveCount(atLeast minimumCount: Int) async {
        await serverRequestRegistry.waitForReceivedEventCount(atLeast: minimumCount)
    }

    private func apply(_ event: JSONRPC.InboundEvent) async throws {
        switch event {
        case .notification(let notification):
            let decoded = try notificationDecoder.decode(notification)
            if case .serverRequestResolved(let requestID) = decoded.payload {
                await serverRequestRegistry.resolve(requestID)
                return
            }
            try await router.route(decoded)
        case .serverRequest(let id, let method, let params):
            await serverRequestRegistry.receive(id: id, method: method, params: params)
        }
    }

    private func drainResponsesOnly() async {
        while true {
            do {
                guard let event = try await transport.nextInboundEvent() else {
                    return
                }
                switch event {
                case .notification(let notification):
                    connectionLogger.error(
                        "Dropping \(notification.method, privacy: .public) while draining responses"
                    )
                case .serverRequest(_, let method, _):
                    connectionLogger.error(
                        "Dropping server request \(method, privacy: .public) while draining responses"
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }

    private nonisolated static func transportFailure(
        for error: CodexAppServerError
    ) -> CodexTransportFailure {
        if case .malformedNotification(let malformed) = error {
            return .protocolViolation(
                message: malformed.localizedDescription,
                rawData: malformed.rawData
            )
        }
        return .protocolViolation(message: error.localizedDescription, rawData: nil)
    }
}
