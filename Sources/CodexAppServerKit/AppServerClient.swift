import Foundation
import OSLog

private let logger = Logger(subsystem: "CodexAppServerKit", category: "app-server-client")

package actor AppServerClient {
    private static let appServerOverloadedErrorCode = -32001
    private static let overloadRetryDelays: [Duration] = [
        .milliseconds(100),
        .milliseconds(250),
        .milliseconds(500),
    ]

    private let transport: any JSONRPC.Transport
    private let overloadRetryDelay: @Sendable (Int) -> Duration?
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private let deadlines: CodexAppServer.Configuration.Deadlines
    private let deadlineClock: CodexDeadlineClock
    private let serializer = RequestSerializer()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 1
    private var initializationResponse: AppServerAPI.Initialize.Response?
    private var initializationTask: Task<AppServerAPI.Initialize.Response, Error>?

    package init(
        transport: any JSONRPC.Transport,
        deadlines: CodexAppServer.Configuration.Deadlines = .init(),
        deadlineClock: CodexDeadlineClock = .continuous,
        overloadRetryDelay: @escaping @Sendable (Int) -> Duration? = AppServerClient
            .defaultOverloadRetryDelay,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.transport = transport
        self.deadlines = deadlines
        self.deadlineClock = deadlineClock
        self.overloadRetryDelay = overloadRetryDelay
        self.retrySleep = retrySleep
    }

    package func initialize(
        clientName: String = "CodexAppServerKit",
        clientVersion: String = "2"
    ) async throws -> AppServerAPI.Initialize.Response {
        if let initializationResponse {
            return initializationResponse
        }
        if let initializationTask {
            return try await initializationTask.value
        }
        let task = Task {
            try await self.performInitialize(clientName: clientName, clientVersion: clientVersion)
        }
        initializationTask = task
        do {
            let response = try await task.value
            initializationResponse = response
            initializationTask = nil
            return response
        } catch {
            initializationTask = nil
            throw error
        }
    }

    private func performInitialize(
        clientName: String,
        clientVersion: String
    ) async throws -> AppServerAPI.Initialize.Response {
        logger.info(
            "Initializing codex app-server connection as \(clientName, privacy: .public) \(clientVersion, privacy: .public)"
        )
        let response: AppServerAPI.Initialize.Response = try await send(
            AppServerAPI.Initialize.Request(
                params: .init(clientName: clientName, clientVersion: clientVersion)
            ),
            purpose: .handshake,
            deadline: deadlines.handshake ?? deadlines.request,
            afterResponse: { [transport, encoder] _ in
                let params = try encoder.encode(EmptyResponse())
                try await transport.notify(.init(method: "initialized", params: params))
            }
        )
        logger.info("codex app-server connection initialized")
        return response
    }

    package func send<Request: AppServerAPI.Request>(_ request: Request) async throws
        -> Request.Response
    {
        try await send(
            method: Request.method,
            params: request.params,
            responseType: Request.Response.self,
            scope: request.scope,
            purpose: .operation(Request.method),
            deadline: deadlines.request
        )
    }

    private func send<Request: AppServerAPI.Request>(
        _ request: Request,
        purpose: CodexRequestPurpose,
        deadline: Duration?,
        afterResponse: @escaping @Sendable (Request.Response) async throws -> Void
    ) async throws -> Request.Response {
        try await send(
            method: Request.method,
            params: request.params,
            responseType: Request.Response.self,
            scope: request.scope,
            purpose: purpose,
            deadline: deadline,
            afterResponse: afterResponse
        )
    }

    package func send<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type,
        scope: AppServerAPI.RequestScope? = nil,
        purpose: CodexRequestPurpose? = nil,
        deadline: Duration? = nil,
        afterResponse: @escaping @Sendable (Response) async throws -> Void = { _ in }
    ) async throws -> Response {
        try await serializer.run(scope: scope) { [transport, encoder, decoder, self] in
            var requestID = await self.allocateRequestID()
            let requestPurpose = purpose ?? .operation(method)
            let encodedParams: Data
            do {
                encodedParams = try encoder.encode(params)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CodexAppServerError.request(.init(
                    requestID: requestID,
                    method: method,
                    purpose: requestPurpose,
                    kind: .encode(message: error.localizedDescription)
                ))
            }
            var retryAttempt = 0
            while true {
                let attemptRequestID = requestID
                logger.debug(
                    "JSON-RPC request \(attemptRequestID, privacy: .public) -> \(method, privacy: .public)"
                )
                do {
                    let operation = { @Sendable () async throws -> Response in
                        let rawResponse: Data
                        do {
                            rawResponse = try await transport.send(
                                .init(
                                    id: attemptRequestID,
                                    method: method,
                                    params: encodedParams
                                ))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as JSONRPC.Error {
                            throw error
                        } catch {
                            throw CodexAppServerError.request(.init(
                                requestID: attemptRequestID,
                                method: method,
                                purpose: requestPurpose,
                                kind: .transport(Self.transportFailure(from: error))
                            ))
                        }
                        let response: Response
                        do {
                            response = try decoder.decode(responseType, from: rawResponse)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw CodexAppServerError.request(.init(
                                requestID: attemptRequestID,
                                method: method,
                                purpose: requestPurpose,
                                kind: .invalidResponse(
                                    expectedType: String(reflecting: responseType),
                                    message: error.localizedDescription,
                                    rawData: rawResponse
                                )
                            ))
                        }
                        do {
                            try await afterResponse(response)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw CodexAppServerError.request(.init(
                                requestID: attemptRequestID,
                                method: method,
                                purpose: requestPurpose,
                                kind: .write(Self.transportFailure(from: error))
                            ))
                        }
                        return response
                    }
                    let response: Response
                    if let deadline {
                        do {
                            response = try await self.runWithDeadline(deadline, operation: operation)
                        } catch is RequestDeadlineExpired {
                            throw CodexAppServerError.request(.init(
                                requestID: attemptRequestID,
                                method: method,
                                purpose: requestPurpose,
                                kind: .deadlineExceeded(deadline)
                            ))
                        }
                    } else {
                        response = try await operation()
                    }
                    logger.debug(
                        "JSON-RPC response \(attemptRequestID, privacy: .public) <- \(method, privacy: .public)"
                    )
                    return response
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as JSONRPC.Error {
                    if case .responseError(let serverError) = error,
                       serverError.code == Self.appServerOverloadedErrorCode {
                        guard let delay = overloadRetryDelay(retryAttempt) else {
                            throw CodexAppServerError.request(.init(
                                requestID: attemptRequestID,
                                method: method,
                                purpose: requestPurpose,
                                kind: .overloadRetryExhausted(
                                    last: serverError,
                                    attempts: retryAttempt + 1
                                )
                            ))
                        }
                        retryAttempt += 1
                        logger.warning(
                            "JSON-RPC request \(attemptRequestID, privacy: .public) overloaded for \(method, privacy: .public); retrying in \(String(describing: delay), privacy: .public)"
                        )
                        try await retrySleep(delay)
                        requestID = await self.allocateRequestID()
                        continue
                    }
                    let failure: CodexRequestFailure.Kind
                    switch error {
                    case .responseError(let serverError):
                        failure = .server(serverError)
                    case .closed:
                        throw CodexAppServerError.connectionTerminated(
                            .transportFailure(.closed)
                        )
                    case .invalidMessage(let message):
                        throw CodexAppServerError.connectionTerminated(.transportFailure(
                            .protocolViolation(message: message, rawData: nil)
                        ))
                    }
                    let wrapped = CodexAppServerError.request(.init(
                        requestID: attemptRequestID,
                        method: method,
                        purpose: requestPurpose,
                        kind: failure
                    ))
                    logger.error(
                        "JSON-RPC request \(attemptRequestID, privacy: .public) failed for \(method, privacy: .public): \(wrapped.localizedDescription, privacy: .public)"
                    )
                    throw wrapped
                } catch let error as CodexAppServerError {
                    throw error
                } catch {
                    throw CodexAppServerError.request(.init(
                        requestID: attemptRequestID,
                        method: method,
                        purpose: requestPurpose,
                        kind: .transport(Self.transportFailure(from: error))
                    ))
                }
            }
        }
    }

    package func notificationStream() async -> AsyncThrowingStream<JSONRPC.Notification, Error> {
        await transport.notificationStream()
    }

    package func close() async {
        await transport.close()
    }

    package func runTurnWithDeadline<Output: Sendable>(
        turnID: CodexTurnID,
        duration: Duration,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        do {
            return try await runWithDeadline(duration, operation: operation)
        } catch is RequestDeadlineExpired {
            throw CodexAppServerError.turnDeadlineExceeded(
                turnID: turnID,
                duration: duration
            )
        }
    }

    private func allocateRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func runWithDeadline<Output: Sendable>(
        _ deadline: Duration,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withThrowingTaskGroup(of: DeadlineRace<Output>.self) { group in
            group.addTask { .value(try await operation()) }
            group.addTask { [deadlineClock] in
                try await deadlineClock.sleep(deadline)
                return .expired
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                preconditionFailure("Deadline race must have a winner.")
            }
            switch result {
            case .value(let value):
                return value
            case .expired:
                throw RequestDeadlineExpired()
            }
        }
    }

    private nonisolated static func transportFailure(from error: Error) -> CodexTransportFailure {
        if let failure = error as? CodexTransportFailure {
            return failure
        }
        if let posixError = error as? POSIXError {
            return .io(errno: posixError.code.rawValue, message: posixError.localizedDescription)
        }
        return .io(errno: nil, message: error.localizedDescription)
    }

    private nonisolated static func defaultOverloadRetryDelay(for retryAttempt: Int) -> Duration? {
        guard retryAttempt < overloadRetryDelays.count else {
            return nil
        }
        let base = overloadRetryDelays[retryAttempt]
        let jitter = Duration.milliseconds(Int.random(in: 0...50))
        return base + jitter
    }
}

private enum DeadlineRace<Value: Sendable>: Sendable {
    case value(Value)
    case expired
}

private struct RequestDeadlineExpired: Error, Sendable {}

package actor RequestSerializer {
    private var lanes: [AppServerAPI.RequestScope: SerialLane] = [:]

    package init() {}

    package func run<Output: Sendable>(
        scope: AppServerAPI.RequestScope?,
        operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        guard let scope else {
            try Task.checkCancellation()
            return try await operation()
        }
        let lane = lane(for: scope)
        try await lane.enter()
        do {
            try Task.checkCancellation()
            let output = try await operation()
            await lane.leave()
            return output
        } catch {
            await lane.leave()
            throw error
        }
    }

    private func lane(for scope: AppServerAPI.RequestScope) -> SerialLane {
        if let lane = lanes[scope] {
            return lane
        }
        let lane = SerialLane()
        lanes[scope] = lane
        return lane
    }
}

private actor SerialLane {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var isOccupied = false
    private var waiters: [Waiter] = []

    func enter() async throws {
        try Task.checkCancellation()
        if isOccupied == false {
            isOccupied = true
            return
        }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(.init(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
        if Task.isCancelled {
            if acquired {
                leave()
            }
            throw CancellationError()
        }
        guard acquired else {
            throw CancellationError()
        }
    }

    func leave() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}
