import Foundation
import CodexAppServerKit

private actor CodexAppServerInMemoryThreadStore {
    private var snapshotsByID: [String: CodexThreadSnapshot]
    private var snapshotOrder: [String]
    private let nextCursor: String?
    private let backwardsCursor: String?

    init(
        threads: [CodexThreadSnapshot],
        nextCursor: String?,
        backwardsCursor: String?
    ) {
        self.snapshotsByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id.rawValue, $0) })
        self.snapshotOrder = threads.map(\.id.rawValue)
        self.nextCursor = nextCursor
        self.backwardsCursor = backwardsCursor
    }

    func startThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Start.Params.self, from: params)
        let threadID = request.threadID ?? "thread-\(UUID().uuidString)"
        let now = Date()
        let snapshot = CodexThreadSnapshot(
            id: CodexThreadID(rawValue: threadID),
            workspace: request.cwd.map(URL.init(fileURLWithPath:)),
            modelProvider: request.modelProvider,
            createdAt: now,
            updatedAt: now,
            recencyAt: now,
            ephemeral: request.ephemeral
        )
        upsert(snapshot)
        return try JSONEncoder().encode(
            AppServerAPI.Thread.Start.Response(threadID: threadID, model: request.model)
        )
    }

    func listThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.List.Params.self, from: params)
        let snapshots = snapshotOrder.compactMap { snapshotsByID[$0] }
        let filteredThreads = CodexAppServerTestTransport.filteredThreadSnapshots(
            snapshots,
            for: request
        )
        return try JSONEncoder().encode(
            AppServerAPI.Thread.List.Response(
                data: filteredThreads.map(CodexAppServerTestTransport.apiSnapshot(from:)),
                nextCursor: nextCursor,
                backwardsCursor: backwardsCursor
            ))
    }

    func resumeThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Resume.Params.self, from: params)
        guard let threadID = request.threadID,
            let thread = snapshotsByID[threadID]
        else {
            throw JSONRPC.Error.responseError(
                code: -32004,
                message: "No stubbed thread matches thread/resume."
            )
        }
        return try JSONEncoder().encode(
            AppServerAPI.Thread.Resume.Response(
                thread: CodexAppServerTestTransport.apiSnapshot(from: thread),
                model: thread.modelProvider
            ))
    }

    func readThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Read.Params.self, from: params)
        guard let thread = snapshotsByID[request.threadID] else {
            throw JSONRPC.Error.responseError(
                code: -32004,
                message: "No stubbed thread matches thread/read."
            )
        }
        return try JSONEncoder().encode(
            AppServerAPI.Thread.Read.Response(
                thread: CodexAppServerTestTransport.apiSnapshot(from: thread)
            ))
    }

    private func upsert(_ snapshot: CodexThreadSnapshot) {
        snapshotsByID[snapshot.id.rawValue] = snapshot
        snapshotOrder.removeAll { $0 == snapshot.id.rawValue }
        snapshotOrder.insert(snapshot.id.rawValue, at: 0)
    }
}

/// A Codex app-server test runtime backed by an in-memory transport.
///
/// This type does not launch `codex` or any external process. Tests enqueue
/// responses and emit notifications through ``transport`` while exercising the
/// same public ``CodexAppServer`` API that production code uses.
public struct CodexAppServerTestRuntime: Sendable {
    /// The app-server domain container under test.
    public var server: CodexAppServer

    /// The in-memory transport used by ``server``.
    public var transport: CodexAppServerTestTransport

    /// Creates a runtime from an already initialized app-server container and transport.
    public init(server: CodexAppServer, transport: CodexAppServerTestTransport) {
        self.server = server
        self.transport = transport
    }

    /// Creates a test runtime without launching a real app-server process.
    ///
    /// The runtime automatically enqueues the `initialize` response required by
    /// ``CodexAppServer`` startup.
    ///
    /// - Parameters:
    ///   - transport: The in-memory transport to use.
    ///   - codexHome: Optional Codex home path returned by initialization.
    ///   - userAgent: Optional user-agent returned by initialization.
    /// - Returns: A started test runtime.
    public static func start(
        transport: CodexAppServerTestTransport = CodexAppServerTestTransport(),
        codexHome: String? = nil,
        userAgent: String? = nil
    ) async throws -> CodexAppServerTestRuntime {
        try await transport.enqueueInitialize(codexHome: codexHome, userAgent: userAgent)
        let server = try await CodexAppServer.testing(transport: transport)
        return .init(server: server, transport: transport)
    }

    /// Creates a test runtime whose app-server thread APIs are backed by in-memory snapshots.
    ///
    /// The returned runtime still exercises the public ``CodexAppServer`` API.
    /// Higher-level code can build its normal data container from ``server``:
    ///
    /// ```swift
    /// let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
    /// let container = CodexModelContainer(appServer: runtime.server)
    /// ```
    public static func start(
        threads: [CodexThreadSnapshot],
        nextCursor: String? = nil,
        backwardsCursor: String? = nil,
        transport: CodexAppServerTestTransport = CodexAppServerTestTransport(),
        codexHome: String? = nil,
        userAgent: String? = nil
    ) async throws -> CodexAppServerTestRuntime {
        try await transport.stubThreads(
            threads,
            nextCursor: nextCursor,
            backwardsCursor: backwardsCursor
        )
        return try await start(
            transport: transport,
            codexHome: codexHome,
            userAgent: userAgent
        )
    }
}

/// A recorded JSON-RPC request sent by ``CodexAppServer``.
public struct CodexAppServerRecordedRequest: Equatable, Sendable {
    /// The JSON-RPC request identifier.
    public var id: Int

    /// The app-server method name.
    public var method: String

    /// The encoded request parameters.
    public var params: Data

    /// Creates a recorded request value.
    public init(id: Int, method: String, params: Data) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Decodes the request parameters as `Value`.
    public func decodeParams<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(type, from: params)
    }
}

/// A recorded JSON-RPC notification sent by ``CodexAppServer``.
public struct CodexAppServerRecordedNotification: Equatable, Sendable {
    /// The app-server notification method name.
    public var method: String

    /// The encoded notification parameters.
    public var params: Data

    /// Creates a recorded notification value.
    public init(method: String, params: Data) {
        self.method = method
        self.params = params
    }

    /// Decodes the notification parameters as `Value`.
    public func decodeParams<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(type, from: params)
    }
}

/// A deterministic gate for app-server concurrency tests.
///
/// Use this to hold a request at a known point and release it explicitly,
/// instead of depending on sleeps or repeated `Task.yield()` calls.
public actor CodexAppServerTestGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Creates a closed gate.
    public init() {}

    /// Suspends until the gate opens, or until the waiting task is cancelled.
    public func wait() async {
        if isOpen {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    /// Suspends until the gate opens, ignoring task cancellation while waiting.
    public func waitIgnoringCancellation() async {
        if isOpen {
            return
        }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters[waiterID] = continuation
            }
        }
    }

    /// Opens the gate and resumes all suspended waiters.
    public func open() {
        guard isOpen == false else {
            return
        }
        isOpen = true
        let waiters = Array(waiters.values)
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

/// An in-memory app-server transport for tests.
public actor CodexAppServerTestTransport {
    private struct RequestGate: Sendable {
        var gate: CodexAppServerTestGate
        var ignoresCancellation: Bool

        func wait() async {
            if ignoresCancellation {
                await gate.waitIgnoringCancellation()
            } else {
                await gate.wait()
            }
        }
    }

    private enum QueuedResponse: Sendable {
        case success(Data)
        case failure(JSONRPC.Error)
    }

    private typealias ResponseHandler = @Sendable (Data) async throws -> Data

    private var responses: [String: [QueuedResponse]] = [:]
    private var responseHandlers: [String: ResponseHandler] = [:]
    private var requests: [JSONRPC.Request] = []
    private var notifications: [JSONRPC.Notification] = []
    private var serverNotificationContinuations:
        [AsyncThrowingStream<JSONRPC.Notification, Error>.Continuation] = []
    private var activeByMethod: [String: Int] = [:]
    private var maxActiveByMethod: [String: Int] = [:]
    private var gatesByMethod: [String: RequestGate] = [:]
    private var oneShotGatesByMethod: [String: [RequestGate]] = [:]
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var requestMethodWaiters: [(String, Int, CheckedContinuation<Void, Never>)] = []
    private var notificationStreamCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var closed = false

    /// Creates an in-memory app-server transport.
    public init() {}

    package init(responses: [String: [Data]]) {
        self.responses = responses.mapValues { $0.map(QueuedResponse.success) }
    }

    /// Enqueues a raw Encodable response for `method`.
    public func enqueue<Response: Encodable & Sendable>(
        _ response: Response,
        for method: String
    ) throws {
        responses[method, default: []].append(.success(try JSONEncoder().encode(response)))
    }

    /// Registers a reusable response handler for `method`.
    ///
    /// Queued responses still take precedence. Use handlers for in-memory
    /// app-server fixtures that must answer the same request multiple times.
    public func handle(
        method: String,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) {
        responseHandlers[method] = handler
    }

    /// Clears the reusable response handler for `method`.
    public func clearHandler(method: String) {
        responseHandlers[method] = nil
    }

    /// Registers a reusable Encodable response for `method`.
    public func stub<Response: Encodable & Sendable>(
        _ response: Response,
        for method: String
    ) throws {
        let encoded = try JSONEncoder().encode(response)
        handle(method: method) { _ in encoded }
    }

    /// Enqueues a JSON string response for `method`.
    public func enqueueJSON(_ json: String, for method: String) throws {
        responses[method, default: []].append(.success(Data(json.utf8)))
    }

    /// Registers a reusable JSON object response for `method`.
    public func stubJSON(_ json: String, for method: String) {
        let encoded = Data(json.utf8)
        handle(method: method) { _ in encoded }
    }

    /// Enqueues a JSON-RPC response error for `method`.
    public func enqueueFailure(code: Int, message: String, for method: String) {
        responses[method, default: []].append(.failure(.responseError(
            code: code,
            message: message
        )))
    }

    package func enqueueFailure(_ error: JSONRPC.Error, for method: String) {
        responses[method, default: []].append(.failure(error))
    }

    /// Enqueues an empty JSON object response for `method`.
    public func enqueueEmpty(for method: String) throws {
        try enqueue(EmptyResponse(), for: method)
    }

    /// Enqueues a thread-start response.
    public func enqueueThreadStart(threadID: String, model: String? = nil) throws {
        try enqueue(
            AppServerAPI.Thread.Start.Response(threadID: threadID, model: model),
            for: "thread/start"
        )
    }

    /// Enqueues a thread-resume response.
    public func enqueueThreadResume(_ thread: CodexThreadSnapshot, model: String? = nil) throws {
        try enqueue(
            AppServerAPI.Thread.Resume.Response(thread: Self.apiSnapshot(from: thread), model: model),
            for: "thread/resume"
        )
    }

    /// Enqueues a thread-list response.
    public func enqueueThreadList(_ page: CodexThreadPage) throws {
        try enqueue(
            AppServerAPI.Thread.List.Response(
                data: page.threads.map(Self.apiSnapshot(from:)),
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor
            ),
            for: "thread/list"
        )
    }

    /// Enqueues a thread-read response.
    public func enqueueThreadRead(_ thread: CodexThreadSnapshot) throws {
        try enqueue(
            AppServerAPI.Thread.Read.Response(thread: Self.apiSnapshot(from: thread)),
            for: "thread/read"
        )
    }

    /// Stubs thread list, resume, and read requests from in-memory thread snapshots.
    ///
    /// This is useful for UI previews and tests that should exercise the same
    /// app-server/DataKit path repeatedly without launching a real app-server.
    public func stubThreads(
        _ threads: [CodexThreadSnapshot],
        nextCursor: String? = nil,
        backwardsCursor: String? = nil
    ) throws {
        let store = CodexAppServerInMemoryThreadStore(
            threads: threads,
            nextCursor: nextCursor,
            backwardsCursor: backwardsCursor
        )

        handle(method: "thread/start") { params in
            try await store.startThreadResponse(for: params)
        }
        handle(method: "thread/list") { params in
            try await store.listThreadResponse(for: params)
        }
        handle(method: "thread/resume") { params in
            try await store.resumeThreadResponse(for: params)
        }
        handle(method: "thread/read") { params in
            try await store.readThreadResponse(for: params)
        }
    }

    /// Enqueues a thread-unarchive response.
    public func enqueueThreadUnarchive(_ thread: CodexThreadSnapshot) throws {
        try enqueue(
            AppServerAPI.Thread.Unarchive.Response(thread: Self.apiSnapshot(from: thread)),
            for: "thread/unarchive"
        )
    }

    /// Enqueues a turn-start response.
    public func enqueueTurnStart(turnID: String, status: String? = nil) throws {
        try enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: turnID, status: status)),
            for: "turn/start"
        )
    }

    /// Enqueues a review-start response.
    public func enqueueReviewStart(turnID: String, reviewThreadID: String? = nil) throws {
        try enqueue(
            AppServerAPI.Review.Start.Response(turnID: turnID, reviewThreadID: reviewThreadID),
            for: "review/start"
        )
    }

    /// Enqueues a model-list response.
    public func enqueueModels(_ models: [CodexModel], nextCursor: String? = nil) throws {
        try enqueue(
            AppServerAPI.Model.List.Response(data: models, nextCursor: nextCursor),
            for: "model/list"
        )
    }

    /// Enqueues an account-read response.
    public func enqueueAccount(_ account: CodexAccount?, requiresOpenAIAuth: Bool = false) throws {
        let snapshot = account.map {
            AppServerAPI.Account.Snapshot(
                kind: .init(rawValue: $0.kind.rawValue) ?? .chatGPT,
                id: $0.id,
                label: $0.label,
                planType: $0.planType
            )
        }
        try enqueue(
            AppServerAPI.Account.Read.Response(
                account: snapshot,
                requiresOpenAIAuth: requiresOpenAIAuth
            ),
            for: "account/read"
        )
    }

    /// Enqueues a config-read response.
    public func enqueueConfiguration(_ configuration: CodexConfiguration) throws {
        try enqueue(
            AppServerAPI.Config.Read.Response(config: .init(
                model: configuration.model,
                reviewModel: configuration.reviewModel,
                modelReasoningEffort: configuration.reasoningEffort?.rawValue,
                serviceTier: configuration.serviceTier
            )),
            for: "config/read"
        )
    }

    /// Enqueues an account rate-limit response.
    public func enqueueRateLimits(_ rateLimits: CodexRateLimits) throws {
        let windows = rateLimits.windows
        let primary = windows.first.map(Self.window)
        let secondary = windows.dropFirst().first.map(Self.window)
        try enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: primary,
                secondary: secondary,
                planType: rateLimits.planType
            )),
            for: "account/rateLimits/read"
        )
    }

    fileprivate static func apiSnapshot(from snapshot: CodexThreadSnapshot) -> AppServerAPI.Thread.Snapshot {
        .init(
            id: snapshot.id.rawValue,
            cwd: snapshot.workspace?.path,
            name: snapshot.name,
            preview: snapshot.preview,
            modelProvider: snapshot.modelProvider,
            createdAt: snapshot.createdAt.map { Int($0.timeIntervalSince1970) },
            updatedAt: snapshot.updatedAt.map { Int($0.timeIntervalSince1970) },
            recencyAt: snapshot.recencyAt.map { Int($0.timeIntervalSince1970) },
            status: snapshot.status.map(Self.apiStatus(from:)),
            ephemeral: snapshot.ephemeral,
            turns: snapshot.turns?.map(Self.apiTurn(from:))
        )
    }

    fileprivate static func filteredThreadSnapshots(
        _ snapshots: [CodexThreadSnapshot],
        for request: AppServerAPI.Thread.List.Params
    ) -> [CodexThreadSnapshot] {
        let workspacePaths: Set<String>?
        switch request.cwd {
        case .paths(let paths):
            workspacePaths = Set(paths)
        case nil:
            workspacePaths = nil
        }

        return snapshots.filter { snapshot in
            if let workspacePaths {
                guard let path = snapshot.workspace?.path,
                    workspacePaths.contains(path)
                else {
                    return false
                }
            }
            if let modelProviders = request.modelProviders,
                modelProviders.isEmpty == false,
                modelProviders.contains(snapshot.modelProvider ?? "") == false
            {
                return false
            }
            if let searchTerm = request.searchTerm?.lowercased(),
                searchTerm.isEmpty == false
            {
                let haystack = [
                    snapshot.name,
                    snapshot.preview,
                    snapshot.workspace?.lastPathComponent,
                ]
                .compactMap { $0?.lowercased() }
                .joined(separator: "\n")
                guard haystack.contains(searchTerm) else {
                    return false
                }
            }
            return true
        }
    }

    private static func apiStatus(
        from status: CodexThreadStatus
    ) -> AppServerAPI.Thread.Snapshot.Status {
        switch status {
        case .active(let activeFlags):
            .init(type: status.rawValue, activeFlags: activeFlags.map(\.rawValue))
        case .notLoaded, .idle, .systemError, .unknown:
            .init(type: status.rawValue)
        }
    }

    private static func apiTurn(from snapshot: CodexTurnSnapshot) -> AppServerAPI.Turn.Payload {
        .init(
            id: snapshot.id.rawValue,
            status: snapshot.status?.rawValue,
            error: snapshot.errorMessage.map { .init(message: $0) },
            items: snapshot.items.map(Self.apiItem(from:))
        )
    }

    private static func apiItem(from item: CodexThreadItem) -> AppServerJSONValue {
        var object: [String: AppServerJSONValue] = [
            "id": .string(item.id),
            "type": .string(item.kind.rawValue),
        ]
        switch item.content {
        case .message(let message):
            object["text"] = .string(message.text)
            if let phase = message.phase?.rawValue {
                object["phase"] = .string(phase)
            }
        case .plan(let text):
            object["text"] = .string(text)
        case .reasoning(let reasoning):
            object["type"] = .string(CodexThreadItem.Kind.reasoning.rawValue)
            object["summary"] = .array(reasoning.summary.map(AppServerJSONValue.string))
            object["content"] = .array(reasoning.content.map(AppServerJSONValue.string))
        case .command(let command):
            object["command"] = .string(command.command)
            set(command.cwd, forKey: "cwd", in: &object)
            set(command.output, forKey: "output", in: &object)
            set(command.exitCode, forKey: "exitCode", in: &object)
            set(command.status?.rawValue, forKey: "status", in: &object)
        case .fileChange(let fileChange):
            set(fileChange.path, forKey: "path", in: &object)
            set(fileChange.output, forKey: "output", in: &object)
            set(fileChange.status?.rawValue, forKey: "status", in: &object)
        case .toolCall(let toolCall):
            set(toolCall.namespace, forKey: "namespace", in: &object)
            set(toolCall.server, forKey: "server", in: &object)
            set(toolCall.name, forKey: "name", in: &object)
            set(toolCall.arguments, forKey: "arguments", in: &object)
            set(toolCall.result, forKey: "result", in: &object)
            set(toolCall.error, forKey: "error", in: &object)
            set(toolCall.status?.rawValue, forKey: "status", in: &object)
        case .contextCompaction(let text):
            set(text, forKey: "text", in: &object)
        case .diagnostic(let text), .log(let text):
            object["text"] = .string(text)
        case .unknown(let raw):
            set(raw.text, forKey: "text", in: &object)
        }
        return .object(object)
    }

    private static func set(
        _ value: String?,
        forKey key: String,
        in object: inout [String: AppServerJSONValue]
    ) {
        guard let value else {
            return
        }
        object[key] = .string(value)
    }

    private static func set(
        _ value: Int?,
        forKey key: String,
        in object: inout [String: AppServerJSONValue]
    ) {
        guard let value else {
            return
        }
        object[key] = .int(value)
    }

    /// Enqueues a ChatGPT browser login response.
    public func enqueueChatGPTLogin(
        loginID: String,
        authenticationURL: URL
    ) throws {
        try enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: loginID,
                authURL: authenticationURL.absoluteString
            ),
            for: "account/login/start"
        )
    }

    /// Enqueues a ChatGPT device-code login response.
    public func enqueueChatGPTDeviceCodeLogin(
        loginID: String,
        verificationURL: URL,
        userCode: String
    ) throws {
        try enqueue(
            AppServerAPI.Account.Login.Response.chatgptDeviceCode(
                loginID: loginID,
                verificationURL: verificationURL.absoluteString,
                userCode: userCode
            ),
            for: "account/login/start"
        )
    }

    /// Enqueues an API-key login response.
    public func enqueueAPIKeyLogin() throws {
        try enqueue(AppServerAPI.Account.Login.Response.apiKey, for: "account/login/start")
    }

    /// Holds every request for `method` until `gate` opens.
    public func hold(method: String, gate: CodexAppServerTestGate) {
        gatesByMethod[method] = .init(gate: gate, ignoresCancellation: false)
    }

    /// Holds the next request for `method` until `gate` opens.
    public func holdNext(method: String, gate: CodexAppServerTestGate) {
        oneShotGatesByMethod[method, default: []].append(.init(
            gate: gate,
            ignoresCancellation: false
        ))
    }

    /// Holds the next request for `method` and ignores task cancellation while waiting.
    public func holdNextIgnoringCancellation(method: String, gate: CodexAppServerTestGate) {
        oneShotGatesByMethod[method, default: []].append(.init(
            gate: gate,
            ignoresCancellation: true
        ))
    }

    /// Returns all requests sent so far.
    public func recordedRequests() -> [CodexAppServerRecordedRequest] {
        requests.map { .init(id: $0.id, method: $0.method, params: $0.params) }
    }

    /// Returns all requests sent so far for `method`.
    public func recordedRequests(method: String) -> [CodexAppServerRecordedRequest] {
        recordedRequests().filter { $0.method == method }
    }

    /// Returns all client notifications sent so far.
    public func recordedNotifications() -> [CodexAppServerRecordedNotification] {
        notifications.map { .init(method: $0.method, params: $0.params) }
    }

    /// Suspends until at least `count` requests have been sent.
    public func waitForRequestCount(_ count: Int) async {
        if requests.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if requests.count >= count {
                continuation.resume()
            } else {
                requestCountWaiters.append((count, continuation))
            }
        }
    }

    /// Suspends until at least `count` requests for `method` have been sent.
    public func waitForRequest(method: String, count: Int = 1) async {
        if requests.filter({ $0.method == method }).count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if requests.filter({ $0.method == method }).count >= count {
                continuation.resume()
            } else {
                requestMethodWaiters.append((method, count, continuation))
            }
        }
    }

    /// Suspends until at least `count` notification stream consumers are attached.
    public func waitForNotificationStreamCount(_ count: Int) async {
        if serverNotificationContinuations.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if serverNotificationContinuations.count >= count {
                continuation.resume()
            } else {
                notificationStreamCountWaiters.append((count, continuation))
            }
        }
    }

    /// Returns the maximum number of in-flight requests observed for `method`.
    public func maxActiveCount(for method: String) -> Int {
        maxActiveByMethod[method] ?? 0
    }

    package func notificationStreamCount() -> Int {
        serverNotificationContinuations.count
    }

    package func isClosedForTesting() -> Bool {
        closed
    }

    /// Emits a server notification to all attached app-server notification streams.
    public func emitServerNotification<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) throws {
        let notification = JSONRPC.Notification(
            method: method,
            params: try JSONEncoder().encode(params)
        )
        for continuation in serverNotificationContinuations {
            continuation.yield(notification)
        }
    }

    /// Emits a server notification from a raw JSON object string.
    public func emitServerNotificationJSON(method: String, json: String) {
        let notification = JSONRPC.Notification(
            method: method,
            params: Data(json.utf8)
        )
        for continuation in serverNotificationContinuations {
            continuation.yield(notification)
        }
    }

    /// Finishes all attached notification streams with `error`.
    public func finishNotificationStreams(throwing error: any Error) {
        for continuation in serverNotificationContinuations {
            continuation.finish(throwing: error)
        }
        serverNotificationContinuations.removeAll()
    }

    package func enqueueInitialize(codexHome: String?, userAgent: String?) throws {
        try enqueue(
            AppServerAPI.Initialize.Response(codexHome: codexHome, userAgent: userAgent),
            for: "initialize"
        )
    }

    private func dequeueResponse(for method: String) -> QueuedResponse? {
        guard var queued = responses[method], queued.isEmpty == false else {
            return nil
        }
        let response = queued.removeFirst()
        responses[method] = queued
        return response
    }

    private func dequeueOneShotGate(for method: String) -> RequestGate? {
        guard var gates = oneShotGatesByMethod[method], gates.isEmpty == false else {
            return nil
        }
        let gate = gates.removeFirst()
        oneShotGatesByMethod[method] = gates
        return gate
    }

    private func resumeRequestCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if requests.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestCountWaiters = remaining
    }

    private func resumeRequestMethodWaiters() {
        var remaining: [(String, Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestMethodWaiters {
            let count = requests.filter { $0.method == waiter.0 }.count
            if count >= waiter.1 {
                waiter.2.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestMethodWaiters = remaining
    }

    private func resumeNotificationStreamCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in notificationStreamCountWaiters {
            if serverNotificationContinuations.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        notificationStreamCountWaiters = remaining
    }

    private static func window(
        from window: CodexRateLimitWindow
    ) -> AppServerAPI.Account.RateLimits.Window {
        .init(
            usedPercent: window.usedPercent,
            windowDurationMins: window.windowDurationMinutes,
            resetsAt: window.resetsAt.map { Int64($0.timeIntervalSince1970) }
        )
    }
}

extension CodexAppServerTestTransport: JSONRPC.Transport {
    package func send(_ request: JSONRPC.Request) async throws -> Data {
        guard closed == false else {
            throw JSONRPC.Error.closed
        }
        requests.append(request)
        resumeRequestCountWaiters()
        resumeRequestMethodWaiters()
        activeByMethod[request.method, default: 0] += 1
        maxActiveByMethod[request.method] = max(
            maxActiveByMethod[request.method] ?? 0,
            activeByMethod[request.method] ?? 0
        )
        if let gate = dequeueOneShotGate(for: request.method) ?? gatesByMethod[request.method] {
            await gate.wait()
        }
        activeByMethod[request.method, default: 1] -= 1
        let queuedResponse = dequeueResponse(for: request.method)
        if let queuedResponse {
            switch queuedResponse {
            case .success(let data):
                return data
            case .failure(let error):
                throw error
            }
        }
        if let responseHandler = responseHandlers[request.method] {
            return try await responseHandler(request.params)
        }
        return try JSONEncoder().encode(EmptyResponse())
    }

    package func notify(_ notification: JSONRPC.Notification) async throws {
        notifications.append(notification)
    }

    package func notificationStream() -> AsyncThrowingStream<JSONRPC.Notification, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            serverNotificationContinuations.append(continuation)
            resumeNotificationStreamCountWaiters()
        }
    }

    package func close() async {
        closed = true
        for continuation in serverNotificationContinuations {
            continuation.finish()
        }
        serverNotificationContinuations.removeAll()
    }
}
