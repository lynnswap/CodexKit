import Foundation

/// A live connection to a Codex app-server process.
///
/// `CodexAppServer` owns the app-server transport, performs the initial
/// JSON-RPC handshake, and routes server notifications to thread, turn, and
/// login domain objects.
public actor CodexAppServer {
    /// Options for creating a Codex app-server container.
    public struct Configuration: Sendable {
        public struct Deadlines: Equatable, Sendable {
            public var handshake: Duration?
            public var request: Duration?

            public init(
                handshake: Duration? = nil,
                request: Duration? = nil
            ) {
                self.handshake = handshake
                self.request = request
            }
        }

        /// Options for launching a local `codex app-server` process.
        public struct LocalProcess: Sendable {
            /// The `codex` executable path or command name.
            ///
            /// Set this when the executable is not available through the process
            /// environment. When `nil`, the default transport command is used.
            public var executable: String?

            /// Command-line arguments passed to the app-server executable.
            ///
            /// When `nil`, the transport uses the default arguments for starting
            /// `codex app-server`.
            public var arguments: [String]?

            /// Environment variables supplied to the app-server process.
            public var environment: [String: String]

            /// The Codex home directory used by the app-server process.
            public var codexHomeURL: URL

            /// Creates a configuration for launching a local app-server process.
            ///
            /// - Parameters:
            ///   - executable: The `codex` executable path or command name.
            ///   - arguments: Command-line arguments for the app-server process.
            ///   - environment: Environment variables for the app-server process.
            ///   - codexHomeURL: Codex home directory, or `nil` to use the local-process default.
            public init(
                executable: String? = nil,
                arguments: [String]? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                codexHomeURL: URL? = nil
            ) {
                self.executable = executable
                self.arguments = arguments
                self.environment = environment
                self.codexHomeURL = codexHomeURL ?? Self.defaultCodexHomeURL(environment: environment)
            }

            /// Returns the default Codex home for a local app-server process.
            ///
            /// The value honors `CODEX_HOME` first. On macOS command-line runs,
            /// it then matches the Codex CLI convention of `~/.codex`. Other
            /// Apple platform environments prefer Application Support so the
            /// default stays inside the app container when this API is compiled
            /// for a non-command-line host.
            public static func defaultCodexHomeURL(
                environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectoryForCurrentUser: URL = FileManager.default.homeDirectoryForCurrentUser,
                applicationSupportDirectory: URL? = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
            ) -> URL {
                if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                   codexHome.isEmpty == false {
                    return URL(fileURLWithPath: codexHome, isDirectory: true)
                }
#if os(macOS)
                if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   home.isEmpty == false {
                    return URL(fileURLWithPath: home, isDirectory: true)
                        .appendingPathComponent(".codex", isDirectory: true)
                }
#endif
                if let applicationSupportDirectory {
                    return applicationSupportDirectory
                        .appendingPathComponent("Codex", isDirectory: true)
                }
                return homeDirectoryForCurrentUser
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Codex", isDirectory: true)
            }
        }

        /// Local process launch settings for the app-server runtime.
        public var localProcess: LocalProcess

        /// The client name sent in the app-server `initialize` request.
        public var clientName: String

        /// The client version sent in the app-server `initialize` request.
        public var clientVersion: String

        /// Monotonic request and handshake deadlines. `nil` disables the
        /// corresponding deadline.
        public var deadlines: Deadlines

        package var deadlineClock: CodexDeadlineClock
        package var clock: CodexAppServerClock
        package var serverRequestHandler: CodexAppServerRequestHandler?

        /// Creates a configuration for a Codex app-server container.
        ///
        /// - Parameters:
        ///   - localProcess: Local process launch settings.
        ///   - clientName: Client name sent during app-server initialization.
        ///   - clientVersion: Client version sent during app-server initialization.
        public init(
            localProcess: LocalProcess = .init(),
            clientName: String = "CodexAppServerKit",
            clientVersion: String = "1",
            deadlines: Deadlines = .init()
        ) {
            self.localProcess = localProcess
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.deadlines = deadlines
            self.deadlineClock = .continuous
            self.clock = .init()
            self.serverRequestHandler = nil
        }

        package init(
            localProcess: LocalProcess = .init(),
            clientName: String = "CodexAppServerKit",
            clientVersion: String = "1",
            deadlines: Deadlines = .init(),
            deadlineClock: CodexDeadlineClock,
            clock: CodexAppServerClock = .init(),
            serverRequestHandler: CodexAppServerRequestHandler? = nil
        ) {
            self.localProcess = localProcess
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.deadlines = deadlines
            self.deadlineClock = deadlineClock
            self.clock = clock
            self.serverRequestHandler = serverRequestHandler
        }

        package static func defaultServerRequestHandler(
            clock: CodexAppServerClock
        ) -> CodexAppServerRequestHandler {
            { request in
                CodexAppServerRequestCodec.builtInResolution(for: request, clock: clock)
            }
        }
    }

    private let client: AppServerClient
    private let router: CodexAppServerNotificationRouter
    private let connectionEventHub: ConnectionEventHub
    private let connectionLease: AppServerConnectionLease
    private var retainedReviewCleanupIdentitiesBySourceThreadID: [CodexThreadID: [CodexReviewIdentity]] = [:]
    private var reviewRestartContextsByTokenID: [CodexReviewRestartToken.ID: CodexReviewRestartContext] = [:]

    package nonisolated var appServerClient: AppServerClient {
        client
    }

    /// Starts a Codex app-server process and initializes the client session.
    ///
    /// The initializer completes after the app-server has accepted the
    /// `initialize` request and notification routing is ready.
    ///
    /// - Parameter configuration: Container and local-process configuration.
    /// - Throws: A transport, JSON-RPC, or app-server initialization error.
    public init(configuration: Configuration = .init()) async throws {
        let transportConfiguration = AppServerProcessTransport.Configuration(
            executable: configuration.localProcess.executable,
            arguments: configuration.localProcess.arguments,
            environment: configuration.localProcess.environment,
            codexHomeURL: configuration.localProcess.codexHomeURL
        )
        let transport: AppServerProcessTransport
        let connectionEventHub = ConnectionEventHub()
        do {
            transport = try AppServerProcessTransport(
                configuration: transportConfiguration,
                connectionEventHub: connectionEventHub
            )
        } catch let failure as CodexLaunchFailure {
            throw CodexAppServerError.launch(failure)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerError.launch(.spawn(
                executable: transportConfiguration.executable,
                errno: (error as? POSIXError)?.code.rawValue,
                message: error.localizedDescription
            ))
        }
        let connectionCloseAction = ConnectionCloseAction()
        let client = AppServerClient(
            transport: transport,
            deadlines: configuration.deadlines,
            deadlineClock: configuration.deadlineClock,
            connectionCloseAction: connectionCloseAction
        )
        let router = CodexAppServerNotificationRouter(client: client)
        let connection = AppServerConnection(
            transport: transport,
            client: client,
            router: router,
            serverRequestHandler: configuration.serverRequestHandler
                ?? Configuration.defaultServerRequestHandler(clock: configuration.clock)
        )
        let supervisor = ConnectionSupervisor(connection: connection)
        connectionCloseAction.bind(to: supervisor)
        let connectionLease = AppServerConnectionLease(
            supervisor: supervisor,
            processTerminationToken: transport.processTerminationToken
        )
        await supervisor.start()
        do {
            _ = try await client.initialize(
                clientName: configuration.clientName,
                clientVersion: configuration.clientVersion
            )
        } catch {
            await supervisor.closeConnection()
            throw error
        }
        self.client = client
        self.router = router
        self.connectionEventHub = client.connectionEventHub
        self.connectionLease = connectionLease
    }

    package init(
        transport: any JSONRPC.Transport
    ) async throws {
        let connectionCloseAction = ConnectionCloseAction()
        let client = AppServerClient(
            transport: transport,
            connectionCloseAction: connectionCloseAction
        )
        let configuration = Configuration()
        let router = CodexAppServerNotificationRouter(client: client)
        let connection = AppServerConnection(
            transport: transport,
            client: client,
            router: router,
            serverRequestHandler: Configuration.defaultServerRequestHandler(
                clock: configuration.clock
            )
        )
        let supervisor = ConnectionSupervisor(connection: connection)
        connectionCloseAction.bind(to: supervisor)
        let connectionLease = AppServerConnectionLease(
            supervisor: supervisor,
            processTerminationToken: ProcessTerminationToken()
        )
        await supervisor.start()
        do {
            _ = try await client.initialize(
                clientName: configuration.clientName,
                clientVersion: configuration.clientVersion
            )
        } catch {
            await supervisor.closeConnection()
            throw error
        }
        self.client = client
        self.router = router
        self.connectionEventHub = client.connectionEventHub
        self.connectionLease = connectionLease
    }

    package init(
        client: AppServerClient,
        router: CodexAppServerNotificationRouter,
        connectionLease: AppServerConnectionLease
    ) {
        self.client = client
        self.router = router
        self.connectionEventHub = client.connectionEventHub
        self.connectionLease = connectionLease
    }

    package static func testing(
        transport: any JSONRPC.Transport
    ) async throws -> CodexAppServer {
        try await CodexAppServer(transport: transport)
    }

    /// Closes the app-server connection and stops notification routing.
    ///
    /// Call this when the container is no longer needed. Closing is idempotent
    /// from the perspective of public callers.
    public func close() async {
        await connectionLease.closeConnection()
    }

    /// Returns connection-scoped diagnostics and the compact terminal event.
    ///
    /// This subscription does not retain the app-server connection or its lease.
    /// Call ``CodexConnectionEvents/cancel()`` to release only this subscriber.
    public func connectionEvents() -> CodexConnectionEvents {
        connectionEventHub.events()
    }

    /// Returns account-related app-server notifications as typed domain events.
    ///
    /// A malformed known current-v2 notification terminates connection-wide routing, including
    /// this sequence and active thread or turn sequences, with a typed
    /// ``CodexAppServerError/connectionTerminated(_:)`` protocol violation. Call
    /// ``CodexAccountEvents/cancel()``
    /// to release only this subscription without closing other routing.
    public func accountEvents() async -> CodexAccountEvents {
        await router.accountEvents()
    }

    /// Creates a new Codex thread in a workspace.
    ///
    /// - Parameters:
    ///   - workspace: The workspace directory for the thread.
    ///   - instructions: Optional base and developer instructions.
    ///   - options: Thread creation options, including model, approval, and sandbox settings.
    /// - Returns: A domain handle for the created thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func startThread(
        in workspace: URL,
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init()
    ) async throws -> CodexThread {
        let approvalMode = options.approvalMode ?? .autoReview
        let response = try await client.send(
            AppServerAPI.Thread.Start.Request(
                params: .init(
                    cwd: workspace.path,
                    model: options.model,
                    modelProvider: options.modelProvider,
                    ephemeral: options.ephemeral,
                    baseInstructions: instructions?.base,
                    developerInstructions: instructions?.developer,
                    approvalPolicy: approvalMode.approvalPolicy,
                    approvalsReviewer: approvalMode.approvalsReviewer,
                    sandbox: options.sandbox?.threadSandboxValue,
                    serviceName: options.serviceName,
                    serviceTier: options.serviceTier,
                    personality: options.personality?.rawValue,
                    config: options.config?.mapValues(\.appServerJSONValue),
                    permissions: options.permissions?.appServerPermissions,
                    sessionStartSource: options.sessionStartSource?.appServerSource,
                    threadSource: options.threadSource?.appServerSource
                )
            ),
            onPostWriteCancellation: { [client] response in
                let _: EmptyResponse = try await client.send(
                    AppServerAPI.Thread.Delete.Request(
                        params: .init(threadID: response.threadID)
                    )
                )
            }
        )
        return CodexThread(
            id: .init(rawValue: response.threadID),
            workspace: workspace,
            model: response.model ?? options.model,
            client: client,
            router: router,
            connectionLease: connectionLease
        )
    }

    /// Starts a Codex code review in a workspace.
    ///
    /// This creates a source thread for `workspace` and starts the app-server
    /// review lifecycle from that thread, so callers do not need to manually
    /// sequence `startThread` and `CodexThread.startReview`.
    ///
    /// - Parameters:
    ///   - workspace: The workspace directory to review.
    ///   - target: The repository changes or custom instructions to review.
    ///   - instructions: Optional base and developer instructions for the source thread.
    ///   - options: Thread creation options, including model, approval, and sandbox settings.
    ///   - delivery: Whether the app-server should run the review inline or in a detached review thread.
    /// - Returns: A live review session.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func startReview(
        in workspace: URL,
        target: CodexReviewTarget,
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init(),
        delivery: CodexReviewDelivery = .inline
    ) async throws -> CodexReviewSession {
        try Task.checkCancellation()
        let thread = try await startThread(
            in: workspace,
            instructions: instructions,
            options: options
        )
        do {
            try Task.checkCancellation()
        } catch {
            await deleteThreadIgnoringCallerCancellation(thread.id)
            throw error
        }

        let review: CodexReviewSession
        do {
            review = try await thread.startReview(
                target: target,
                delivery: delivery
            )
        } catch {
            await deleteThreadIgnoringCallerCancellation(thread.id)
            throw error
        }

        do {
            try Task.checkCancellation()
            return review
        } catch {
            await cleanupReviewIgnoringCallerCancellation(review.identity)
            throw error
        }
    }

    /// Resumes an existing Codex thread.
    ///
    /// - Parameters:
    ///   - id: The thread identifier to resume.
    ///   - options: Resume options that may override the stored thread context.
    /// - Returns: A domain handle for the resumed thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func resumeThread(
        _ id: CodexThreadID,
        options: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexThread {
        let response: AppServerAPI.Thread.Resume.Response = try await withThreadEventGeneration(
            id,
            router: router
        ) {
            try await client.send(
                AppServerAPI.Thread.Resume.Request(
                    threadID: id.rawValue,
                    params: threadStartParams(options: options)
                ))
        }
        return await thread(from: response.thread, model: response.model ?? options.model)
    }

    /// Restores a persisted app-server review run as a live review session handle.
    ///
    /// The restored session can consume review events and cancel the active
    /// review turn. The active turn thread is resumed first so app-server has
    /// the stored thread context loaded before the review handle is rebuilt.
    ///
    /// - Parameters:
    ///   - identity: Persisted review run identity.
    ///   - threadOptions: Resume options for the active turn thread. When `model` is
    ///     `nil`, `identity.model` is used.
    /// - Returns: A live review session handle for the persisted run.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func resumeReview(
        _ identity: CodexReviewIdentity,
        threadOptions: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexReviewSession {
        var threadOptions = threadOptions
        if threadOptions.model == nil {
            threadOptions.model = identity.model
        }
        let activeThread = try await resumeThread(
            identity.activeTurnThreadID,
            options: threadOptions
        )
        return await activeThread.reviewSession(
            identity,
            model: activeThread.model ?? identity.model
        )
    }

    /// Cancels a running review and prepares it for a later restart.
    ///
    /// The returned token is process-local to this ``CodexAppServer`` instance.
    /// Cleanup ownership for the interrupted review is retained internally until
    /// ``cleanupReview(_:additionalCleanupThreadIDs:)`` is called for the same
    /// source thread.
    ///
    /// - Parameters:
    ///   - identity: Persisted review run identity to interrupt.
    ///   - threadOptions: Resume options for the active turn thread. When `model` is
    ///     `nil`, `identity.model` is used.
    /// - Returns: A token that can be passed to ``restartPreparedReview(_:target:delivery:threadOptions:)``.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func prepareReviewRestart(
        _ identity: CodexReviewIdentity,
        threadOptions: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexReviewRestartToken {
        let review = try await resumeReview(identity, threadOptions: threadOptions)
        let cancellation = try await review.cancel { retryCancellation in
            if retryCancellation.turnID != Optional(identity.turnID) {
                await self.rememberReviewCleanupIdentity(
                    for: retryCancellation,
                    sourceIdentity: identity,
                    model: review.model
                )
            }
        }
        try await review.response.waitForCancelledResponse(cancellation)
        rememberReviewCleanupIdentity(identity)
        rememberReviewCleanupIdentity(
            for: cancellation,
            sourceIdentity: identity,
            model: review.model
        )
        discardReviewRestartContexts(sourceThreadID: identity.sourceThreadID)

        let token = CodexReviewRestartToken(
            id: UUID().uuidString,
            interruptedIdentity: identity
        )
        reviewRestartContextsByTokenID[token.id] = CodexReviewRestartContext(
            interruptedIdentity: identity,
            rollbackThreadID: cancellation.threadID,
            rollbackModel: review.model
        )
        return token
    }

    /// Restarts a review that was previously prepared by ``prepareReviewRestart(_:threadOptions:)``.
    ///
    /// The restart first reloads and rolls back the thread that owned the
    /// interrupted active turn, then reloads the source thread and starts a new
    /// review from that source.
    ///
    /// - Parameters:
    ///   - token: Token returned by ``prepareReviewRestart(_:threadOptions:)``.
    ///   - target: The repository changes or custom instructions to review.
    ///   - delivery: Whether the app-server should run the review inline or in a detached review thread.
    ///   - threadOptions: Resume options for the source thread. For inline
    ///     reviews, `token.interruptedIdentity.model` is used when `model` is
    ///     `nil`; detached review restarts leave source-thread model selection
    ///     to app-server unless the caller supplies an explicit model.
    /// - Returns: A live review session for the restarted review.
    /// - Throws: ``CodexAppServerError/reviewRestartUnavailable(_:)`` when the token is stale.
    public func restartPreparedReview(
        _ token: CodexReviewRestartToken,
        target: CodexReviewTarget,
        delivery: CodexReviewDelivery = .inline,
        threadOptions: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexReviewSession {
        try Task.checkCancellation()
        guard var context = reviewRestartContextsByTokenID[token.id],
              context.isRestarting == false else {
            throw CodexAppServerError.reviewRestartUnavailable(token.id)
        }
        context.isRestarting = true
        reviewRestartContextsByTokenID[token.id] = context

        do {
            if context.rollbackCompleted == false {
                let rollbackThread = try await resumeThread(
                    context.rollbackThreadID,
                    options: .init(model: context.rollbackModel)
                )
                try await rollbackThread.rollback(turnCount: 1)
                context.rollbackCompleted = true
                reviewRestartContextsByTokenID[token.id] = context
            }

            try Task.checkCancellation()
            var sourceThreadOptions = threadOptions
            if sourceThreadOptions.model == nil,
               context.interruptedIdentity.activeTurnThreadID == context.interruptedIdentity.sourceThreadID {
                sourceThreadOptions.model = context.interruptedIdentity.model
            }
            let sourceThread = try await resumeThread(
                context.interruptedIdentity.sourceThreadID,
                options: sourceThreadOptions
            )
            try Task.checkCancellation()

            let review = try await sourceThread.startReview(
                target: target,
                delivery: delivery,
                onPostWriteCancellation: { [self] review in
                    try await cleanupCancelledRestart(review, tokenID: token.id)
                }
            )
            do {
                try Task.checkCancellation()
            } catch {
                await cleanupReviewIgnoringCallerCancellation(review.identity)
                throw error
            }

            reviewRestartContextsByTokenID.removeValue(forKey: token.id)
            return review
        } catch {
            context.isRestarting = false
            if reviewRestartContextsByTokenID[token.id]?.isRestarting == true {
                reviewRestartContextsByTokenID[token.id] = context
            }
            throw error
        }
    }

    private func cleanupCancelledRestart(
        _ review: CodexReviewSession,
        tokenID: CodexReviewRestartToken.ID
    ) async throws {
        try await interruptAndAwaitTerminal(review.response)
        await cleanupReview(review.identity)
        reviewRestartContextsByTokenID.removeValue(forKey: tokenID)
    }

    /// Deletes all app-server threads owned by a review lifecycle.
    ///
    /// Retained cleanup identities from prepared restarts are included, duplicate
    /// thread identifiers are removed, and the source thread is deleted last.
    /// Delete failures are intentionally ignored to match best-effort cleanup
    /// behavior.
    ///
    /// - Parameters:
    ///   - identity: Review identity whose source thread owns the lifecycle.
    ///   - additionalCleanupThreadIDs: Extra cleanup ID sequences, in preferred
    ///     per-sequence order, to merge with retained review cleanup IDs.
    public func cleanupReview(
        _ identity: CodexReviewIdentity,
        additionalCleanupThreadIDs: [[CodexThreadID]] = []
    ) async {
        let sourceThreadID = identity.sourceThreadID
        let retainedIdentities = retainedReviewCleanupIdentitiesBySourceThreadID.removeValue(
            forKey: sourceThreadID
        ) ?? []
        discardReviewRestartContexts(sourceThreadID: sourceThreadID)

        let cleanupThreadIDs = Self.orderedReviewCleanupThreadIDs(
            sourceThreadID: sourceThreadID,
            sequences: retainedIdentities.map(\.cleanupThreadIDs)
                + [identity.cleanupThreadIDs]
                + additionalCleanupThreadIDs
        )
        for threadID in cleanupThreadIDs {
            try? await deleteThread(threadID)
        }
    }

    /// Forks an existing Codex thread into a new thread.
    ///
    /// - Parameters:
    ///   - id: The source thread identifier.
    ///   - options: Options for the forked thread.
    /// - Returns: A domain handle for the forked thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func forkThread(
        _ id: CodexThreadID,
        options: CodexThread.Options = .init()
    ) async throws -> CodexThread {
        let response = try await client.send(
            AppServerAPI.Thread.Fork.Request(
                threadID: id.rawValue,
                params: threadStartParams(options: options)
            ),
            onPostWriteCancellation: { [client] response in
                let _: EmptyResponse = try await client.send(
                    AppServerAPI.Thread.Delete.Request(
                        params: .init(threadID: response.thread.id)
                    )
                )
            }
        )
        return await thread(from: response.thread)
    }

    /// Restores an archived Codex thread.
    ///
    /// - Parameter id: The archived thread identifier.
    /// - Returns: A domain handle for the restored thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func unarchiveThread(_ id: CodexThreadID) async throws -> CodexThread {
        let response = try await sendUnarchiveThread(id)
        return await thread(from: response.thread)
    }

    package func unarchiveThreadSnapshot(_ id: CodexThreadID) async throws -> CodexThreadSnapshot {
        let response = try await sendUnarchiveThread(id)
        let snapshot = Self.threadSnapshot(from: response.thread, includesTurns: false)
        await router.seedTurns(snapshot.turns, threadID: id)
        return snapshot
    }

    private func sendUnarchiveThread(
        _ id: CodexThreadID
    ) async throws -> AppServerAPI.Thread.Unarchive.Response {
        try await client.send(
            AppServerAPI.Thread.Unarchive.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Archives a Codex thread.
    ///
    /// - Parameter id: The thread identifier to archive.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func archiveThread(_ id: CodexThreadID) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Archive.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Permanently deletes a Codex thread.
    ///
    /// - Parameter id: The thread identifier to delete.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func deleteThread(_ id: CodexThreadID) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Delete.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Lists Codex threads visible to the app-server account.
    ///
    /// - Parameter query: Paging and filtering options.
    /// - Returns: A page of thread snapshots.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func listThreads(_ query: CodexThreadQuery = .init()) async throws -> CodexThreadPage {
        let response = try await client.send(
            AppServerAPI.Thread.List.Request(
                params: .init(
                    archived: query.archived,
                    cursor: query.cursor,
                    cwd: query.workspaces.map { .paths($0.map(\.path)) },
                    limit: query.limit,
                    modelProviders: query.modelProviders,
                    searchTerm: query.searchTerm,
                    sortDirection: query.sortDirection?.rawValue,
                    sortKey: query.sortKey?.rawValue,
                    sourceKinds: query.sourceKinds?.map(\.rawValue),
                    useStateDbOnly: query.useStateDBOnly
                )))
        let snapshots = response.data.map { Self.threadSnapshot(from: $0, includesTurns: false) }
        for snapshot in snapshots {
            await router.seedTurns(snapshot.turns, threadID: snapshot.id)
        }
        return .init(
            threads: snapshots,
            nextCursor: response.nextCursor,
            backwardsCursor: response.backwardsCursor
        )
    }

    /// Lists available Codex models.
    ///
    /// - Parameter includeHidden: Whether hidden models should be included.
    /// - Returns: The complete model list across all app-server result pages.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func models(includeHidden: Bool = false) async throws -> [CodexModel] {
        var cursor: String?
        var models: [CodexModel] = []
        repeat {
            let response = try await client.send(
                AppServerAPI.Model.List.Request(
                    params: .init(cursor: cursor, includeHidden: includeHidden)
                ))
            models.append(contentsOf: response.data)
            cursor = response.nextCursor
        } while cursor != nil
        return models
    }

    /// Reads the active Codex account.
    ///
    /// - Parameter refreshToken: Whether the app-server should refresh token state before returning.
    /// - Returns: The active account, or `nil` when no account is signed in.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func account(refreshToken: Bool = false) async throws -> CodexAccount? {
        let response = try await client.send(
            AppServerAPI.Account.Read.Request(params: .init(refreshToken: refreshToken))
        )
        return response.account.map(Self.account)
    }

    /// Reads the app-server configuration visible to Codex clients.
    ///
    /// - Returns: Model, reasoning, review model, and service-tier settings.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func configuration() async throws -> CodexConfiguration {
        let response = try await client.send(AppServerAPI.Config.Read.Request())
        let reasoningEffort = response.config.modelReasoningEffort.map {
            CodexReasoningEffort(rawValue: $0)
        }
        return .init(
            model: response.config.model,
            reviewModel: response.config.reviewModel,
            reasoningEffort: reasoningEffort,
            serviceTier: response.config.serviceTier
        )
    }

    /// Applies a partial update to the app-server configuration.
    ///
    /// Fields left unchanged in the patch are not sent. Fields explicitly set
    /// to `nil` are cleared in the app-server configuration.
    ///
    /// - Parameter patch: The configuration fields to update.
    /// - Throws: A transport, JSON-RPC, or app-server configuration error.
    public func updateConfiguration(_ patch: CodexConfigurationPatch) async throws {
        var edits: [AppServerAPI.Config.Edit] = []
        if patch.updatesReviewModel {
            edits.append(.init(
                keyPath: "review_model",
                value: patch.reviewModel.map(AppServerAPI.Config.Value.string) ?? .null
            ))
        }
        if patch.updatesReasoningEffort {
            edits.append(.init(
                keyPath: "model_reasoning_effort",
                value: patch.reasoningEffort.map { .string($0.rawValue) } ?? .null
            ))
        }
        if patch.updatesServiceTier {
            edits.append(.init(
                keyPath: "service_tier",
                value: patch.serviceTier.map(AppServerAPI.Config.Value.string) ?? .null
            ))
        }
        guard edits.isEmpty == false else {
            return
        }
        let _: AppServerAPI.Config.BatchWrite.Response = try await client.send(
            AppServerAPI.Config.BatchWrite.Request(params: .init(edits: edits))
        )
    }

    /// Reads Codex account rate-limit information.
    ///
    /// - Returns: Current plan type and rate-limit windows reported by the app-server.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func rateLimits() async throws -> CodexRateLimits {
        let response = try await client.send(AppServerAPI.Account.RateLimits.Read.Request())
        await router.replaceRateLimits(with: response)
        return .init(appServer: response)
    }

    /// Starts an API-key login flow.
    ///
    /// - Parameter apiKey: The OpenAI API key to register with Codex.
    /// - Returns: The login handle reported by the app-server.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    @discardableResult
    public func loginAPIKey(_ apiKey: String) async throws -> CodexLoginHandle {
        let response = try await client.send(
            AppServerAPI.Account.Login.Start.Request(
                params: .init(type: "apiKey", apiKey: apiKey)
            ),
            onPostWriteCancellation: cancelLoginAfterPostWriteCancellation
        )
        return try Self.loginHandle(from: response)
    }

    /// Starts a ChatGPT browser login flow.
    ///
    /// - Returns: A login handle containing the browser authentication URL.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func loginChatGPT() async throws -> CodexLoginHandle {
        let response = try await client.send(
            AppServerAPI.Account.Login.Start.Request(
                params: .init(type: "chatgpt")
            ),
            onPostWriteCancellation: cancelLoginAfterPostWriteCancellation
        )
        return try Self.loginHandle(from: response)
    }

    /// Starts a ChatGPT browser login flow with native web-authentication support.
    ///
    /// - Parameter nativeWebAuthentication: The native callback scheme the host can receive.
    /// - Returns: A ChatGPT login result containing the browser authentication URL and any
    ///   native web-authentication information accepted by the app-server.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func loginChatGPT(
        nativeWebAuthentication: CodexNativeWebAuthentication
    ) async throws -> CodexChatGPTLogin {
        let response = try await client.send(
            AppServerAPI.Account.Login.Start.Request(
                params: .init(
                    type: "chatgpt",
                    nativeWebAuthentication: .init(
                        callbackURLScheme: nativeWebAuthentication.callbackURLScheme
                    )
                )
            ),
            onPostWriteCancellation: cancelLoginAfterPostWriteCancellation
        )
        return try Self.chatGPTLogin(from: response)
    }

    /// Starts a ChatGPT device-code login flow.
    ///
    /// - Returns: A login handle containing device-code instructions.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func loginChatGPTDeviceCode() async throws -> CodexLoginHandle {
        let response = try await client.send(
            AppServerAPI.Account.Login.Start.Request(
                params: .init(type: "chatgptDeviceCode")
            ),
            onPostWriteCancellation: cancelLoginAfterPostWriteCancellation
        )
        return try Self.loginHandle(from: response)
    }

    /// Cancels a pending login flow.
    ///
    /// Handles without an app-server login identifier are treated as already complete.
    ///
    /// - Parameter handle: The login handle returned from a login-start method.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func cancelLogin(_ handle: CodexLoginHandle) async throws {
        guard let id = handle.id else {
            return
        }
        try await cancelLogin(id: id)
    }

    /// Cancels a pending login flow by identifier.
    ///
    /// - Parameter id: The app-server login identifier.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func cancelLogin(id: CodexLoginHandle.ID) async throws {
        let _: AppServerAPI.Account.Login.Cancel.Response = try await client.send(
            AppServerAPI.Account.Login.Cancel.Request(params: .init(loginID: id.rawValue))
        )
    }

    private func cancelLoginAfterPostWriteCancellation(
        _ response: AppServerAPI.Account.Login.Response
    ) async throws {
        guard let loginID = response.pendingLoginID else {
            return
        }
        let _: AppServerAPI.Account.Login.Cancel.Response = try await client.send(
            AppServerAPI.Account.Login.Cancel.Request(
                params: .init(loginID: loginID)
            )
        )
    }

    /// Completes a native web-authentication login flow with the callback URL.
    ///
    /// - Parameters:
    ///   - id: The app-server login identifier.
    ///   - callbackURL: The callback URL returned by the native web-authentication session.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func completeLogin(id: CodexLoginHandle.ID, callbackURL: URL) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Account.Login.Complete.Request(params: .init(
                loginID: id.rawValue,
                callbackURL: callbackURL.absoluteString
            ))
        )
    }

    /// Logs out of the active Codex account.
    ///
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func logout() async throws {
        let _: EmptyResponse = try await client.send(AppServerAPI.Account.Logout.Request())
    }

    private func threadStartParams(options: CodexThread.Options) -> AppServerAPI.Thread.Start.Params {
        .init(
            model: options.model,
            modelProvider: options.modelProvider,
            ephemeral: options.ephemeral,
            approvalPolicy: options.approvalMode?.approvalPolicy,
            approvalsReviewer: options.approvalMode?.approvalsReviewer,
            sandbox: options.sandbox?.threadSandboxValue,
            serviceName: options.serviceName,
            serviceTier: options.serviceTier,
            personality: options.personality?.rawValue,
            config: options.config?.mapValues(\.appServerJSONValue),
            permissions: options.permissions?.appServerPermissions,
            sessionStartSource: options.sessionStartSource?.appServerSource,
            threadSource: options.threadSource?.appServerSource
        )
    }

    private func thread(
        from snapshot: AppServerAPI.Thread.Snapshot,
        model: String? = nil
    ) async -> CodexThread {
        let threadID = CodexThreadID(rawValue: snapshot.id)
        await router.seedTurns(
            snapshot.turns.map(Self.turnSnapshots(from:)),
            threadID: threadID
        )
        return CodexThread(
            id: threadID,
            workspace: snapshot.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            model: model,
            client: client,
            router: router,
            connectionLease: connectionLease
        )
    }

    private func rememberReviewCleanupIdentity(_ identity: CodexReviewIdentity) {
        let sourceThreadID = identity.sourceThreadID
        if retainedReviewCleanupIdentitiesBySourceThreadID[sourceThreadID, default: []]
            .contains(identity) == false {
            retainedReviewCleanupIdentitiesBySourceThreadID[sourceThreadID, default: []].append(identity)
        }
    }

    private func rememberReviewCleanupIdentity(
        for cancellation: CodexTurnCancellation,
        sourceIdentity: CodexReviewIdentity,
        model: String?
    ) {
        let cancelledIdentity = Self.reviewCleanupIdentity(
            for: cancellation,
            sourceIdentity: sourceIdentity,
            model: model
        )
        rememberReviewCleanupIdentity(cancelledIdentity)
    }

    private func discardReviewRestartContexts(sourceThreadID: CodexThreadID) {
        reviewRestartContextsByTokenID = reviewRestartContextsByTokenID.filter { _, context in
            context.interruptedIdentity.sourceThreadID != sourceThreadID
        }
    }

    private func deleteThreadIgnoringCallerCancellation(_ id: CodexThreadID) async {
        await Task { [self] in
            try? await deleteThread(id)
        }.value
    }

    private func cleanupReviewIgnoringCallerCancellation(_ identity: CodexReviewIdentity) async {
        await Task { [self] in
            await cleanupReview(identity)
        }.value
    }

    private nonisolated static func reviewCleanupIdentity(
        for cancellation: CodexTurnCancellation,
        sourceIdentity: CodexReviewIdentity,
        model: String?
    ) -> CodexReviewIdentity {
        CodexReviewIdentity(
            threadID: sourceIdentity.sourceThreadID,
            turnID: cancellation.turnID ?? sourceIdentity.turnID,
            reviewThreadID: cancellation.threadID == sourceIdentity.sourceThreadID ? nil : cancellation.threadID,
            model: model ?? sourceIdentity.model
        )
    }

    private nonisolated static func orderedReviewCleanupThreadIDs(
        sourceThreadID: CodexThreadID,
        sequences: [[CodexThreadID]]
    ) -> [CodexThreadID] {
        var seen: Set<CodexThreadID> = []
        var threadIDs: [CodexThreadID] = []
        for sequence in sequences {
            for threadID in sequence where threadID != sourceThreadID && seen.insert(threadID).inserted {
                threadIDs.append(threadID)
            }
        }
        if seen.insert(sourceThreadID).inserted {
            threadIDs.append(sourceThreadID)
        }
        return threadIDs
    }

    package nonisolated static func threadSnapshot(
        from snapshot: AppServerAPI.Thread.Snapshot,
        includesTurns: Bool
    ) -> CodexThreadSnapshot {
        let turns = turnSnapshots(from: snapshot.turns, includesTurns: includesTurns)
        return .init(
            id: .init(rawValue: snapshot.id),
            workspace: snapshot.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            name: snapshot.name,
            preview: snapshot.preview,
            modelProvider: snapshot.modelProvider,
            sourceKind: snapshot.sourceKind.map(CodexThreadSourceKind.init(rawValue:)),
            createdAt: snapshot.createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            updatedAt: snapshot.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            recencyAt: snapshot.recencyAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            status: snapshot.status.map {
                CodexThreadStatus(type: $0.type, activeFlags: $0.activeFlags)
            },
            ephemeral: snapshot.ephemeral,
            turns: turns,
            turnItemsAreAuthoritative: includesTurns,
            presentFields: threadSnapshotPresentFields(from: snapshot, turns: turns)
        )
    }

    private nonisolated static func threadSnapshotPresentFields(
        from snapshot: AppServerAPI.Thread.Snapshot,
        turns: [CodexTurnSnapshot]?
    ) -> Set<CodexThreadSnapshot.Field> {
        var fields: Set<CodexThreadSnapshot.Field> = []
        for field in snapshot.presentFields {
            switch field {
            case .cwd:
                fields.insert(.workspace)
            case .name:
                fields.insert(.name)
            case .preview:
                fields.insert(.preview)
            case .modelProvider:
                fields.insert(.modelProvider)
            case .sourceKind:
                fields.insert(.sourceKind)
            case .createdAt:
                fields.insert(.createdAt)
            case .updatedAt:
                fields.insert(.updatedAt)
            case .recencyAt:
                fields.insert(.recencyAt)
            case .status:
                fields.insert(.status)
            case .ephemeral:
                fields.insert(.ephemeral)
            case .turns:
                if turns != nil {
                    fields.insert(.turns)
                }
            }
        }
        if turns != nil {
            fields.insert(.turns)
        }
        return fields
    }

    package nonisolated static func turnSnapshots(
        from turns: [AppServerAPI.Turn.Payload]
    ) -> [CodexTurnSnapshot] {
        turns.map {
            let status = CodexTurnStatus(rawValue: $0.status)
            let state: CodexTurnSnapshot.State = switch status {
            case .inProgress:
                .inProgress
            case .completed:
                .completed
            case .interrupted:
                .interrupted
            case .failed:
                .failed(Self.requiredTurnError(from: $0))
            case .unknown(let rawValue):
                .unknown(rawValue: rawValue, error: $0.error.map(Self.turnError(from:)))
            }
            return CodexTurnSnapshot(
                id: .init(rawValue: $0.id),
                state: state,
                itemsLoadState: $0.itemsLoadState ?? ($0.items == nil ? .notLoaded : .full),
                items: AppServerThreadItemMapping.threadItems(from: $0.items),
                startedAt: $0.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                completedAt: $0.completedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                duration: $0.durationMS.map { .milliseconds(Int64($0)) }
            )
        }
    }

    private nonisolated static func requiredTurnError(
        from turn: AppServerAPI.Turn.Payload
    ) -> CodexTurnError {
        guard let error = turn.error else {
            preconditionFailure("Strict Turn.Payload decoding requires failed turns to carry an error.")
        }
        return turnError(from: error)
    }

    package nonisolated static func turnError(
        from error: AppServerAPI.Turn.Error
    ) -> CodexTurnError {
        .init(
            message: error.message,
            info: error.codexErrorInfo.map(Self.errorInfo(from:)),
            additionalDetails: error.additionalDetails
        )
    }

    private nonisolated static func errorInfo(
        from info: AppServerAPI.CodexErrorInfo
    ) -> CodexErrorInfo {
        switch info {
        case .contextWindowExceeded: .contextWindowExceeded
        case .sessionBudgetExceeded: .sessionBudgetExceeded
        case .usageLimitExceeded: .usageLimitExceeded
        case .serverOverloaded: .serverOverloaded
        case .cyberPolicy: .cyberPolicy
        case .httpConnectionFailed(let status): .httpConnectionFailed(httpStatusCode: status)
        case .responseStreamConnectionFailed(let status):
            .responseStreamConnectionFailed(httpStatusCode: status)
        case .internalServerError: .internalServerError
        case .unauthorized: .unauthorized
        case .badRequest: .badRequest
        case .threadRollbackFailed: .threadRollbackFailed
        case .sandboxError: .sandboxError
        case .responseStreamDisconnected(let status):
            .responseStreamDisconnected(httpStatusCode: status)
        case .responseTooManyFailedAttempts(let status):
            .responseTooManyFailedAttempts(httpStatusCode: status)
        case .activeTurnNotSteerable(let kind): .activeTurnNotSteerable(turnKind: kind)
        case .other: .other
        case .unknown(let rawValue): .unknown(rawValue: rawValue)
        }
    }

    private nonisolated static func turnSnapshots(
        from turns: [AppServerAPI.Turn.Payload]?,
        includesTurns: Bool
    ) -> [CodexTurnSnapshot]? {
        guard let turns else {
            return includesTurns ? [] : nil
        }
        guard includesTurns || turns.isEmpty == false else {
            return nil
        }
        return turnSnapshots(from: turns)
    }

    private nonisolated static func account(from snapshot: AppServerAPI.Account.Snapshot) -> CodexAccount {
        .init(
            id: snapshot.id,
            kind: .init(rawValue: snapshot.kind.rawValue) ?? .chatGPT,
            label: snapshot.label,
            planType: snapshot.planType
        )
    }

    private nonisolated static func loginHandle(
        from response: AppServerAPI.Account.Login.Response
    ) throws -> CodexLoginHandle {
        switch response {
        case .apiKey:
            return .apiKey
        case .chatgpt(let loginID, let authURL, _):
            guard let url = URL(string: authURL) else {
                throw CodexAppServerError.malformedNotification(.init(
                    method: "account/login/start response",
                    message: "Invalid ChatGPT authentication URL.",
                    rawData: nil
                ))
            }
            return .chatGPT(id: .init(rawValue: loginID), authenticationURL: url)
        case .chatgptDeviceCode(let loginID, let verificationURL, let userCode):
            guard let url = URL(string: verificationURL) else {
                throw CodexAppServerError.malformedNotification(.init(
                    method: "account/login/start response",
                    message: "Invalid ChatGPT device-code verification URL.",
                    rawData: nil
                ))
            }
            return .chatGPTDeviceCode(
                id: .init(rawValue: loginID),
                verificationURL: url,
                userCode: userCode
            )
        case .chatgptAuthTokens:
            return .apiKey
        }
    }

    private nonisolated static func chatGPTLogin(
        from response: AppServerAPI.Account.Login.Response
    ) throws -> CodexChatGPTLogin {
        guard case .chatgpt(let loginID, let authURL, let nativeWebAuthentication) = response else {
            throw CodexAppServerError.malformedNotification(.init(
                method: "account/login/start response",
                message: "Expected ChatGPT login response.",
                rawData: nil
            ))
        }
        guard let url = URL(string: authURL) else {
            throw CodexAppServerError.malformedNotification(.init(
                method: "account/login/start response",
                message: "Invalid ChatGPT authentication URL.",
                rawData: nil
            ))
        }
        return CodexChatGPTLogin(
            id: .init(rawValue: loginID),
            authenticationURL: url,
            nativeWebAuthentication: nativeWebAuthentication.map {
                CodexNativeWebAuthentication(callbackURLScheme: $0.callbackURLScheme)
            }
        )
    }

}

private struct CodexReviewRestartContext: Sendable {
    var interruptedIdentity: CodexReviewIdentity
    var rollbackThreadID: CodexThreadID
    var rollbackModel: String?
    var rollbackCompleted: Bool = false
    var isRestarting: Bool = false
}
