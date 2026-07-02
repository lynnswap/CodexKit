import Foundation
import Testing

import CodexAppServerKitTesting
@testable import CodexAppServerKit

@Suite("CodexAppServerKit")
struct CodexAppServerKitTests {
    @Test func localProcessConfigurationOwnsDefaultCodexHome() {
        let fromHome = CodexAppServer.Configuration.LocalProcess(environment: [
            "HOME": "/tmp/user-home",
        ])
        #expect(fromHome.codexHomeURL.path == "/tmp/user-home/.codex")

        let fromCodexHome = CodexAppServer.Configuration.LocalProcess(environment: [
            "CODEX_HOME": "/tmp/codex-home",
            "HOME": "/tmp/user-home",
        ])
        #expect(fromCodexHome.codexHomeURL.path == "/tmp/codex-home")

        let appSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)
        let containerDefault = CodexAppServer.Configuration.LocalProcess.defaultCodexHomeURL(
            environment: [:],
            homeDirectoryForCurrentUser: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            applicationSupportDirectory: appSupport
        )
        #expect(containerDefault.path == "/tmp/app-support/Codex")

        let homeFallback = CodexAppServer.Configuration.LocalProcess.defaultCodexHomeURL(
            environment: [:],
            homeDirectoryForCurrentUser: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            applicationSupportDirectory: nil
        )
        #expect(homeFallback.path == "/tmp/home/Library/Application Support/Codex")
    }

    @Test func reasoningTextCoalescesDuplicateFragmentsAndKeepsMarkdownBlocks() {
        let review = """
        **Reviewing inspection needs**

        I need to inspect the changes.
        """
        let slowness = """
        **Investigating potential slowness**

        I need to inspect the running command.
        """

        let reasoning = CodexReasoning(
            summary: [
                review,
                review,
                slowness,
                slowness,
            ],
            content: ["raw", "raw"]
        )

        #expect(reasoning.summary == [review, slowness])
        #expect(reasoning.content == ["raw"])
        #expect(reasoning.text == "\(review)\n\n\(slowness)")
    }

    @Test func localProcessConfigurationResolvesExplicitExecutableCommandNames() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let executableURL = binURL.appendingPathComponent("codex")
        try """
            #!/bin/sh
            exit 0
            """
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let configuration = AppServerProcessTransport.Configuration(
            executable: "codex",
            environment: ["PATH": binURL.path],
            codexHomeURL: rootURL.appendingPathComponent("codex-home", isDirectory: true)
        )

        #expect(configuration.executable == executableURL.path)
        #expect(configuration.arguments == [
            "-c",
            CodexAppServerExecutable.fileBackedAuthConfiguration,
            "app-server",
            "--listen",
            "stdio://",
        ])
    }

    @Test func processTransportAnswersServerInitiatedRequestsThroughConfiguredHandler() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let responseURL = rootURL.appendingPathComponent("response.json")
        let executableURL = rootURL.appendingPathComponent("fake-app-server")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try """
            #!/bin/sh
            printf '%s\\n' '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1"}}'
            IFS= read -r line
            printf '%s\\n' "$line" > "$RESPONSE_PATH"
            """
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let recorder = ServerRequestRecorder()
        let transport = try AppServerProcessTransport(
            configuration: .init(
                executable: executableURL.path,
                arguments: [],
                environment: ["RESPONSE_PATH": responseURL.path],
                codexHomeURL: rootURL.appendingPathComponent("codex-home", isDirectory: true),
                serverRequestHandler: { request in
                    await recorder.append(request)
                    return try .result(["decision": "accept"])
                }
            )
        )
        defer {
            Task {
                await transport.close()
            }
        }

        let wroteResponse = await eventually(attempts: 100) {
            FileManager.default.fileExists(atPath: responseURL.path)
        }
        #expect(wroteResponse)

        let request = try #require(await recorder.requests().first)
        #expect(request.id == .string("approval-1"))
        #expect(request.method == "item/commandExecution/requestApproval")
        let requestParams = try #require(
            JSONSerialization.jsonObject(with: request.params) as? [String: Any]
        )
        #expect(requestParams["threadId"] as? String == "thread-1")

        let responseData = try Data(contentsOf: responseURL)
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        #expect(response["id"] as? String == "approval-1")
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["decision"] as? String == "accept")
    }

    @Test func processSpawnClosePlanPreservesStandardIOFileDescriptors() {
        let closeDescriptors = AppServerProcessFileDescriptorPlan
            .childPipeDescriptorsToClose([0, 1, 2, 3, 4, 5])

        #expect(closeDescriptors == [3, 4, 5])
    }

    @Test func testRuntimeStartsAppServerWithoutLaunchingProcess() async throws {
        let runtime = try await CodexAppServerTestRuntime.start(codexHome: "/tmp/codex")
        try await runtime.transport.enqueueThreadStart(threadID: "thread-test", model: "gpt-5")

        let thread = try await runtime.server.startThread(
            in: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            options: .init(model: "gpt-5")
        )

        #expect(thread.id == "thread-test")
        #expect(await runtime.transport.recordedRequests().map(\.method) == [
            "initialize",
            "thread/start",
        ])
        #expect(await runtime.transport.recordedNotifications().map(\.method) == [
            "initialized"
        ])
    }

    @Test func testTransportHoldsRequestsAtExplicitGate() async throws {
        let transport = CodexAppServerTestTransport()
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "ping", gate: gate)
        let client = AppServerClient(transport: transport)

        let task = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
        }

        await transport.waitForRequest(method: "ping")
        #expect(await transport.maxActiveCount(for: "ping") == 1)

        await gate.open()
        try await task.value
    }

    @Test func initializeSendsHandshakeAndInitializedNotification() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"), for: "initialize")
        let client = AppServerClient(transport: transport)

        let response = try await client.initialize(clientName: "TestClient", clientVersion: "1")

        #expect(response.codexHome == "/tmp/codex")
        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
        #expect(await transport.recordedNotifications().map(\.method) == ["initialized"])
        let params = try #require(await transport.recordedRequests().first?.params)
        let decoded = try JSONDecoder().decode(AppServerAPI.Initialize.Params.self, from: params)
        #expect(decoded.clientInfo.name == "TestClient")
        #expect(decoded.clientInfo.version == "1")
    }

    @Test func appServerClosesTransportWhenInitializationFails() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(code: -32000, message: "initialize failed", for: "initialize")

        do {
            _ = try await CodexAppServer.testing(transport: transport)
            Issue.record("Expected initialization failure.")
        } catch {
            #expect(await transport.isClosedForTesting())
        }
    }

    @Test func appServerStartThreadSerializesDomainOptions() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let thread = try await server.startThread(
            in: workspace,
            instructions: .init(base: "Base", developer: "Developer"),
            options: .init(
                model: "gpt-5",
                sandbox: .workspaceWrite,
                permissions: .profile(id: "codex-default"),
                ephemeral: true,
                config: ["experimental": .bool(true)],
                personality: .pragmatic,
                serviceName: "app-server-kit-test",
                sessionStartSource: .startup,
                threadSource: "automation"
            )
        )

        #expect(thread.id == "thread-1")
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "thread/start")
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.Start.Params.self, from: request.params)
        #expect(params.cwd == workspace.path)
        #expect(params.model == "gpt-5")
        #expect(params.ephemeral == true)
        #expect(params.baseInstructions == "Base")
        #expect(params.developerInstructions == "Developer")
        #expect(params.approvalPolicy == "on-request")
        #expect(params.approvalsReviewer == "auto_review")
        #expect(params.sandbox == "workspace-write")
        #expect(params.permissions == .profileID("codex-default"))
        #expect(params.config == ["experimental": .bool(true)])
        #expect(params.personality == "pragmatic")
        #expect(params.serviceName == "app-server-kit-test")
        #expect(params.sessionStartSource == .startup)
        #expect(params.threadSource?.rawValue == "automation")
    }

    @Test func threadOptionWireValuesUseAppServerConfigSchema() {
        #expect(CodexApprovalMode.autoReview.approvalPolicy == "on-request")
        #expect(CodexApprovalMode.denyAll.approvalPolicy == "never")
        #expect(CodexSandbox.readOnly.threadSandboxValue == "read-only")
        #expect(CodexSandbox.workspaceWrite.threadSandboxValue == "workspace-write")
        #expect(CodexSandbox.fullAccess.threadSandboxValue == "danger-full-access")
    }

    @Test func appServerResumeThreadPreservesServerReturnedModel() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(
            .init(
                id: "thread-1",
                workspace: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
            ),
            model: "gpt-5"
        )

        let thread = try await runtime.server.resumeThread("thread-1")

        #expect(thread.id == "thread-1")
        #expect(thread.model == "gpt-5")
        let request = try #require(await runtime.transport.recordedRequests().last)
        let params = try request.decodeParams(AppServerAPI.Thread.Resume.Params.self)
        #expect(params.threadID == "thread-1")
        #expect(params.model == nil)
    }

    @Test func appServerStartReviewStartsThreadThenReview() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-review")
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let review = try await runtime.server.startReview(
            in: workspace,
            target: .baseBranch("main"),
            instructions: .init(base: "Base", developer: "Developer"),
            options: .init(model: "gpt-5"),
            transcriptErrorHandlingPolicy: .revertTranscript
        )

        #expect(review.threadID == "thread-source")
        #expect(review.turnID == "turn-review")
        #expect(review.reviewThreadID == "thread-source")
        #expect(review.identity == CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            model: "gpt-5"
        ))

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/start",
            "review/start",
        ])
        let threadStart = try requests[1].decodeParams(AppServerAPI.Thread.Start.Params.self)
        #expect(threadStart.cwd == workspace.path)
        #expect(threadStart.model == "gpt-5")
        #expect(threadStart.baseInstructions == "Base")
        #expect(threadStart.developerInstructions == "Developer")

        let reviewStart = try requests[2].decodeParams(AppServerAPI.Review.Start.Params.self)
        #expect(reviewStart.threadID == "thread-source")
        #expect(reviewStart.target == .baseBranch("main"))
        #expect(reviewStart.delivery == .inline)
    }

    @Test func threadStartReviewTreatsReturnedSourceThreadIDAsInline() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-1"
            ),
            for: "review/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(id: "thread-1", model: "gpt-5", client: client, router: router)

        let review = try await thread.startReview(target: .baseBranch("main"))

        #expect(review.threadID == "thread-1")
        #expect(review.reviewThreadID == "thread-1")
        #expect(review.model == "gpt-5")
        #expect(review.identity.reviewThreadID == nil)
        #expect(review.identity.model == "gpt-5")
    }

    @Test func appServerStartReviewDeletesSourceThreadWhenReviewStartFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "invalid review target",
            for: "review/start"
        )
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        do {
            _ = try await runtime.server.startReview(
                in: workspace,
                target: .baseBranch("missing")
            )
            Issue.record("Expected review start failure.")
        } catch {
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/start",
                "review/start",
                "thread/delete",
            ])
            let delete = try requests[3].decodeParams(AppServerAPI.Thread.Delete.Params.self)
            #expect(delete.threadID == "thread-source")
        }
    }

    @Test func appServerStartReviewDeletesSourceThreadWhenCancelledDuringThreadStart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let threadStartGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/start",
            gate: threadStartGate
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let task = Task {
            try await runtime.server.startReview(
                in: workspace,
                target: .baseBranch("main")
            )
        }
        await runtime.transport.waitForRequest(method: "thread/start")
        task.cancel()
        await threadStartGate.open()

        do {
            _ = try await withTimeout {
                try await task.value
            }
            Issue.record("Expected cancelled thread start failure.")
        } catch is CancellationError {
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/start",
                "thread/delete",
            ])
            let delete = try requests[2].decodeParams(AppServerAPI.Thread.Delete.Params.self)
            #expect(delete.threadID == "thread-source")
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }

    @Test func appServerStartReviewDeletesSourceThreadWhenCancelledAfterThreadStart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let reviewStartGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "cancelled review start",
            for: "review/start"
        )
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: reviewStartGate
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let task = Task {
            try await runtime.server.startReview(
                in: workspace,
                target: .baseBranch("main")
            )
        }
        await runtime.transport.waitForRequest(method: "review/start")
        task.cancel()
        await reviewStartGate.open()

        do {
            _ = try await withTimeout {
                try await task.value
            }
            Issue.record("Expected cancelled review start failure.")
        } catch {
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/start",
                "review/start",
                "thread/delete",
            ])
            let delete = try requests[3].decodeParams(AppServerAPI.Thread.Delete.Params.self)
            #expect(delete.threadID == "thread-source")
        }
    }

    @Test func appServerStartReviewCleansDetachedReviewWhenCancelledAfterReviewStart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let reviewStartGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: reviewStartGate
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let task = Task {
            try await runtime.server.startReview(
                in: workspace,
                target: .baseBranch("main"),
                delivery: .detached
            )
        }
        await runtime.transport.waitForRequest(method: "review/start")
        task.cancel()
        await reviewStartGate.open()

        do {
            _ = try await withTimeout {
                try await task.value
            }
            Issue.record("Expected cancelled detached review start failure.")
        } catch is CancellationError {
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/start",
                "review/start",
                "thread/delete",
                "thread/delete",
            ])
            let deletedThreadIDs = try requests.suffix(2).map {
                try $0.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
            }
            #expect(deletedThreadIDs == ["thread-review", "thread-source"])
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }

    @Test func appServerListThreadsSerializesQueryOptions() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: [], nextCursor: "next"),
            for: "thread/list"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let page = try await server.listThreads(.init(
            archived: false,
            cursor: "cursor",
            workspace: workspace,
            limit: 10,
            searchTerm: "review",
            modelProviders: ["openai"],
            sortDirection: .descending,
            sortKey: .recencyAt,
            sourceKinds: [.appServer, .subAgentReview],
            useStateDBOnly: true
        ))

        #expect(page.nextCursor == "next")
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "thread/list")
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.List.Params.self,
            from: request.params
        )
        #expect(params.archived == false)
        #expect(params.cursor == "cursor")
        #expect(params.cwd == .paths([workspace.path]))
        #expect(params.limit == 10)
        #expect(params.searchTerm == "review")
        #expect(params.modelProviders == ["openai"])
        #expect(params.sortDirection == "desc")
        #expect(params.sortKey == "recency_at")
        #expect(params.sourceKinds == ["appServer", "subAgentReview"])
        #expect(params.useStateDbOnly == true)
    }

    @Test func appServerListThreadsSerializesMultipleWorkspaceFilters() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: []),
            for: "thread/list"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )
        let app = URL(fileURLWithPath: "/tmp/project/App", isDirectory: true)
        let tools = URL(fileURLWithPath: "/tmp/project/Tools", isDirectory: true)

        _ = try await server.listThreads(.init(workspaces: [app, tools]))

        let request = try #require(await transport.recordedRequests().first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.List.Params.self,
            from: request.params
        )
        #expect(params.cwd == .paths([app.path, tools.path]))
    }

    @Test func appServerListThreadsTreatsClearedWorkspaceFiltersAsNoFilter() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: []),
            for: "thread/list"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )
        var query = CodexThreadQuery(
            workspaces: [URL(fileURLWithPath: "/tmp/project", isDirectory: true)]
        )
        query.workspaces = []

        _ = try await server.listThreads(query)

        let request = try #require(await transport.recordedRequests().first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.List.Params.self,
            from: request.params
        )
        #expect(params.cwd == nil)
    }

    @Test func appServerListThreadsMapsStatusAndRecency() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "data": [
                {
                  "id": "thread-active",
                  "recencyAt": 1234,
                  "status": {
                    "type": "active",
                    "activeFlags": ["waitingOnApproval"]
                  }
                }
              ]
            }
            """,
            for: "thread/list"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let page = try await server.listThreads()
        let snapshot = try #require(page.threads.first)

        #expect(snapshot.hasField(.recencyAt))
        #expect(snapshot.recencyAt == Date(timeIntervalSince1970: 1234))
        #expect(snapshot.hasField(.status))
        #expect(snapshot.status == .active(activeFlags: [.waitingOnApproval]))
    }

    @Test func threadListTreatsEmptyTurnsAsUnloaded() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: [
                .init(id: "thread-empty", turns: [])
            ]),
            for: "thread/list"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let page = try await server.listThreads()

        #expect(page.threads.first?.turns == nil)
    }

    @Test func threadSnapshotEqualityIgnoresTurnAuthorityFlag() {
        let turns = [CodexTurnSnapshot(id: "turn-1", status: .completed)]
        let publicSnapshot = CodexThreadSnapshot(id: "thread-1", turns: turns)
        let summarySnapshot = CodexThreadSnapshot(
            id: "thread-1",
            turns: turns,
            turnItemsAreAuthoritative: false
        )

        #expect(publicSnapshot == summarySnapshot)
    }

    @Test func threadSnapshotsTrackOmittedAndNullFields() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "data": [
                {
                  "id": "thread-partial",
                  "name": null,
                  "updatedAt": 1000
                }
              ]
            }
            """,
            for: "thread/list"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let page = try await server.listThreads()
        let snapshot = try #require(page.threads.first)

        #expect(snapshot.hasField(.name))
        #expect(snapshot.name == nil)
        #expect(snapshot.hasField(.updatedAt))
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 1000))
        #expect(!snapshot.hasField(.workspace))
        #expect(!snapshot.hasField(.modelProvider))
    }

    @Test func threadSnapshotEncodingPreservesPresentNullFields() throws {
        let snapshot = AppServerAPI.Thread.Snapshot(
            id: "thread-partial",
            name: nil,
            updatedAt: nil,
            presentFields: [.name, .updatedAt]
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["id"] as? String == "thread-partial")
        #expect(object["name"] is NSNull)
        #expect(object["updatedAt"] is NSNull)
        #expect(object["cwd"] == nil)
    }

    @Test func threadReadUsesIncludeTurnsToInterpretEmptyTurns() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.Read.Response(thread: .init(id: "thread-empty", turns: [])),
            for: "thread/read"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Read.Response(thread: .init(id: "thread-empty", turns: [])),
            for: "thread/read"
        )
        let client = AppServerClient(transport: transport)
        let thread = CodexThread(
            id: .init(rawValue: "thread-empty"),
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let metadataOnly = try await thread.read(includeTurns: false)
        let withTurns = try await thread.read(includeTurns: true)

        #expect(metadataOnly.turns == nil)
        #expect(!metadataOnly.hasField(.turns))
        #expect(withTurns.turns == [])
        #expect(withTurns.hasField(.turns))
    }

    @Test func threadReadTreatsOmittedTurnsAsEmptyWhenIncluded() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "thread": {
                "id": "thread-empty"
              }
            }
            """,
            for: "thread/read"
        )
        let client = AppServerClient(transport: transport)
        let thread = CodexThread(
            id: .init(rawValue: "thread-empty"),
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let snapshot = try await thread.read(includeTurns: true)

        #expect(snapshot.turns == [])
        #expect(snapshot.hasField(.turns))
    }

    @Test func threadReadDoesNotTreatSummaryTurnsAsAuthoritative() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "thread": {
                "id": "thread-summary",
                "turns": [
                  {
                    "id": "turn-summary",
                    "itemsView": "summary",
                    "items": [
                      {
                        "id": "message-summary",
                        "type": "agentMessage",
                        "text": "Summary"
                      }
                    ]
                  }
                ]
              }
            }
            """,
            for: "thread/read"
        )
        let client = AppServerClient(transport: transport)
        let thread = CodexThread(
            id: .init(rawValue: "thread-summary"),
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let snapshot = try await thread.read(includeTurns: true)

        #expect(snapshot.turns?.first?.itemsLoadState == .summary)
        #expect(snapshot.turnItemsAreAuthoritative == false)
    }

    @Test func threadStoreDrivesRuntimeThreadStubsAfterStart() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let initial = CodexThreadSnapshot(
            id: "thread-a",
            workspace: workspace,
            name: "A",
            modelProvider: "openai"
        )
        let store = CodexAppServerTestThreadStore(threads: [initial])
        let runtime = try await CodexAppServerTestRuntime.start(threadStore: store)

        let firstPage = try await runtime.server.listThreads()
        #expect(firstPage.threads == [initial])
        #expect(firstPage.nextCursor == nil)
        #expect(firstPage.backwardsCursor == nil)

        let updated = CodexThreadSnapshot(
            id: "thread-b",
            workspace: workspace,
            name: "B",
            preview: "Updated",
            modelProvider: "openai",
            turns: [CodexTurnSnapshot(id: "turn-b", status: .completed)]
        )
        await store.upsert(updated)

        #expect(await store.snapshot(id: "thread-b") == updated)
        #expect(await store.snapshots().map(\.id.rawValue) == ["thread-b", "thread-a"])

        let secondPage = try await runtime.server.listThreads()
        #expect(secondPage.threads == [updated, initial])

        let resumed = try await runtime.server.resumeThread("thread-b")
        let read = try await resumed.read(includeTurns: true)
        #expect(read == updated)

        await store.remove(id: "thread-a")
        let removedPage = try await runtime.server.listThreads()
        #expect(removedPage.threads == [updated])

        let startedWorkspace = URL(fileURLWithPath: "/tmp/started", isDirectory: true)
        let started = try await runtime.server.startThread(
            in: startedWorkspace,
            options: .init(model: "gpt-5", modelProvider: "openai", ephemeral: true)
        )
        let startedSnapshot = try #require(await store.snapshot(id: started.id))
        #expect(startedSnapshot.workspace == startedWorkspace)
        #expect(startedSnapshot.modelProvider == "openai")
        #expect(startedSnapshot.ephemeral == true)
        #expect(started.model == "gpt-5")
    }

    @Test func threadStoreHonorsThreadListPagination() async throws {
        let threads = [
            CodexThreadSnapshot(id: "thread-a", name: "A"),
            CodexThreadSnapshot(id: "thread-b", name: "B"),
            CodexThreadSnapshot(id: "thread-c", name: "C"),
        ]
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)

        let firstPage = try await runtime.server.listThreads(.init(limit: 2))
        #expect(firstPage.threads.map(\.id.rawValue) == ["thread-a", "thread-b"])
        let nextCursor = try #require(firstPage.nextCursor)
        #expect(firstPage.backwardsCursor == nil)

        let secondPage = try await runtime.server.listThreads(.init(
            cursor: nextCursor,
            limit: 2
        ))
        #expect(secondPage.threads.map(\.id.rawValue) == ["thread-c"])
        #expect(secondPage.nextCursor == nil)
        #expect(secondPage.backwardsCursor != nil)
    }

    @Test func transportStubThreadsAcceptsMutableThreadStore() async throws {
        let store = CodexAppServerTestThreadStore()
        let transport = CodexAppServerTestTransport()
        try await transport.stubThreads(store)
        let runtime = try await CodexAppServerTestRuntime.start(transport: transport)

        let snapshot = CodexThreadSnapshot(id: "thread-transport", name: "Transport")
        await store.upsert(snapshot)

        let page = try await runtime.server.listThreads()
        #expect(page.threads == [snapshot])
    }

    @Test func appServerArchiveThreadSerializesThreadID() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueEmpty(for: "thread/archive")
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        try await server.archiveThread("thread-archive")

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "thread/archive")
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.Archive.Params.self,
            from: request.params
        )
        #expect(params.threadID == "thread-archive")
    }

    @Test func reviewNotificationMethodsClassifyReviewEvents() {
        #expect(AppServerReviewNotification.Method(rawValue: "turn/started").isReviewNotificationMethod)
        #expect(AppServerReviewNotification.Method(rawValue: "item/started").isReviewNotificationMethod)
        #expect(
            AppServerReviewNotification.Method(rawValue: "item/commandExecution/outputDelta")
                .isReviewNotificationMethod
        )
        #expect(AppServerReviewNotification.Method(rawValue: "thread/status/changed").isReviewNotificationMethod)
        #expect(AppServerReviewNotification.Method(rawValue: "model/verification").isReviewNotificationMethod)
        #expect(AppServerReviewNotification.Method(rawValue: "review/futureEvent").isReviewNotificationMethod == false)
    }

    @Test func reviewNotificationMethodsClassifyThreadlessBroadcasts() {
        #expect(AppServerReviewNotification.Method(rawValue: "warning").isThreadlessReviewBroadcast)
        #expect(AppServerReviewNotification.Method(rawValue: "deprecationNotice").isThreadlessReviewBroadcast)
        #expect(AppServerReviewNotification.Method(rawValue: "configWarning").isThreadlessReviewBroadcast)
        #expect(AppServerReviewNotification.Method(rawValue: "error").isThreadlessReviewBroadcast)
        #expect(AppServerReviewNotification.Method(rawValue: "diagnostic").isThreadlessReviewBroadcast == false)
        #expect(AppServerReviewNotification.Method(rawValue: "turn/started").isThreadlessReviewBroadcast == false)
    }

    @Test func reviewNotificationDecodePreservesUnknownRawPayloads() throws {
        let objectData = Data("""
            {
              "threadId": "thread-review",
              "turnId": "turn-review",
              "future": { "enabled": true },
              "count": 2
            }
            """.utf8)
        let objectNotification = try AppServerReviewNotification(
            method: "review/futureEvent",
            paramsData: objectData
        )

        #expect(objectNotification.method.rawValue == "review/futureEvent")
        #expect(objectNotification.payload.threadID == "thread-review")
        #expect(objectNotification.payload.turnID == "turn-review")
        #expect(objectNotification.rawNotification.threadID == "thread-review")
        #expect(objectNotification.rawNotification.turnID == "turn-review")
        #expect(objectNotification.rawNotification.params == objectData)
        #expect(objectNotification.rawPayload == .object([
            "threadId": .string("thread-review"),
            "turnId": .string("turn-review"),
            "future": .object(["enabled": .bool(true)]),
            "count": .int(2),
        ]))

        let nonObjectData = Data(#""future schema""#.utf8)
        let nonObjectNotification = try AppServerReviewNotification(
            method: "review/futureEvent",
            paramsData: nonObjectData
        )

        #expect(nonObjectNotification.payload.threadID == nil)
        #expect(nonObjectNotification.payload.turnID == nil)
        #expect(nonObjectNotification.rawPayload == .string("future schema"))
        #expect(nonObjectNotification.rawNotification.params == nonObjectData)
    }

    @Test func reviewNotificationDecodeReadsOfficialItemPayload() throws {
        let notification = try AppServerReviewNotification(
            method: "item/completed",
            paramsData: Data("""
                {
                  "threadId": "thread-review",
                  "turnId": "turn-review",
                  "item": {
                    "id": "command-1",
                    "type": "commandExecution",
                    "command": "swift test",
                    "aggregatedOutput": "passed",
                    "status": "completed"
                  }
                }
                """.utf8)
        )

        #expect(notification.method.isReviewNotificationMethod)
        #expect(notification.payload.threadID == "thread-review")
        #expect(notification.payload.resolvedTurnID == "turn-review")
        #expect(notification.payload.item?.id == "command-1")
        #expect(notification.payload.item?.resolvedType == "commandExecution")
        #expect(notification.payload.item?.command == "swift test")
        #expect(notification.payload.item?.aggregatedOutput == "passed")
        #expect(notification.payload.item?.status == "completed")
    }

    @Test func threadStartReviewSerializesTargetAndStreamsReviewEvents() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let review = try await thread.startReview(
            target: .baseBranch("main"),
            delivery: .detached
        )

        #expect(review.threadID == "thread-1")
        #expect(review.turnID == "turn-review")
        #expect(review.reviewThreadID == "thread-review")

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "review/start")
        let params = try JSONDecoder().decode(
            AppServerAPI.Review.Start.Params.self,
            from: request.params
        )
        #expect(params.threadID == "thread-1")
        #expect(params.target == .baseBranch("main"))
        #expect(params.delivery == .detached)

        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "swift test",
                    aggregatedOutput: "passed",
                    status: "completed"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    id: "reasoning-1",
                    type: "reasoning",
                    summary: ["Checked the diff"],
                    content: ["trace"]
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    id: "tool-1",
                    type: "mcpToolCall",
                    text: "ok",
                    status: "completed",
                    tool: "review_read"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    id: "file-1",
                    type: "fileChange",
                    text: "updated",
                    status: "completed",
                    path: "Sources/File.swift"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-review")
        )

        let events = try await collect(review.events)
        let completedItems = events.compactMap { event -> (item: CodexThreadItem, turnID: CodexTurnID?)? in
            guard case .itemCompleted(let item, let turnID) = event else {
                return nil
            }
            return (item, turnID)
        }
        #expect(completedItems.count == 4)
        #expect(completedItems.first?.turnID == "turn-review")
        #expect(completedItems.first?.item.kind == .commandExecution)
        #expect(completedItems.first?.item.text == "passed")
        #expect(completedItems.contains {
            if case .reasoning(let reasoning) = $0.item.content {
                reasoning.summary == ["Checked the diff"]
            } else {
                false
            }
        })
        #expect(completedItems.contains {
            if case .toolCall(let toolCall) = $0.item.content {
                toolCall.name == "review_read"
            } else {
                false
            }
        })
        #expect(completedItems.contains {
            if case .fileChange(let fileChange) = $0.item.content {
                fileChange.path == "Sources/File.swift"
            } else {
                false
            }
        })

        let logs = try await collect(review.logEntries)
        #expect(logs.map(\.id) == ["command-1", "reasoning-1", "tool-1", "file-1"])
        #expect(logs.allSatisfy { $0.turnID == "turn-review" })
        #expect(logs.contains {
            if case .command(let command) = $0.item?.content {
                command.command == "swift test"
            } else {
                false
            }
        })
        #expect(logs.contains {
            if case .toolCall(let toolCall) = $0.item?.content {
                toolCall.name == "review_read"
            } else {
                false
            }
        })
        #expect(logs.contains {
            if case .fileChange(let fileChange) = $0.item?.content {
                fileChange.path == "Sources/File.swift"
            } else {
                false
            }
        })
    }

    @Test func reviewSessionExposesPersistableLifecycleIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )

        let thread = try await runtime.server.startThread(
            in: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            options: .init(model: "gpt-5")
        )
        let review = try await thread.startReview(
            target: .baseBranch("main"),
            delivery: .detached
        )

        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        #expect(review.identity == identity)
        #expect(review.model == nil)
        #expect(review.sourceThreadID == "thread-source")
        #expect(review.activeTurnThreadID == "thread-review")
        #expect(review.associatedThreadIDs == ["thread-source", "thread-review"])
        #expect(review.cleanupThreadIDs == ["thread-review", "thread-source"])
        #expect(identity.associatedThreadIDs == ["thread-source", "thread-review"])
        #expect(identity.cleanupThreadIDs == ["thread-review", "thread-source"])

        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(CodexReviewIdentity.self, from: encoded)
        #expect(decoded == identity)
    }

    @Test func inlineReviewIdentityKeepsDetachedReviewThreadNil() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-review")

        let thread = try await runtime.server.startThread(
            in: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            options: .init(model: "gpt-5")
        )
        let review = try await thread.startReview(target: .baseBranch("main"))

        #expect(review.reviewThreadID == "thread-source")
        #expect(review.identity == CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            model: "gpt-5"
        ))
        #expect(review.identity.reviewThreadID == nil)
        #expect(review.identity.activeTurnThreadID == "thread-source")
        #expect(review.identity.cleanupThreadIDs == ["thread-source"])
    }

    @Test func appServerResumeReviewRestoresEventsAndCancellationFromIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-review",
            workspace: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        ))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )

        let review = try await runtime.server.resumeReview(identity)
        let cancellation = try await review.cancel()
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-review", status: "completed"))
        )

        #expect(review.identity == identity)
        #expect(cancellation.threadID == "thread-review")
        #expect(cancellation.turnID == "turn-review")
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/resume",
            "turn/interrupt",
        ])
        let resumeParams = try requests[1].decodeParams(AppServerAPI.Thread.Resume.Params.self)
        #expect(resumeParams.threadID == "thread-review")
        #expect(resumeParams.model == "gpt-5")
        let interruptParams = try requests[2].decodeParams(AppServerAPI.Turn.Interrupt.Params.self)
        #expect(interruptParams.threadID == "thread-review")
        #expect(interruptParams.turnID == "turn-review")

        var iterator = review.events.makeAsyncIterator()
        let event = try await iterator.next()
        if case .turnCompleted(let response) = event {
            #expect(response.turnID == "turn-review")
        } else {
            Issue.record("Expected resumed review.events to receive turn-only completion.")
        }
        #expect(try await iterator.next() == nil)
    }

    @Test func appServerResumeReviewUsesThreadOptionModelOverride() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )

        let review = try await runtime.server.resumeReview(
            identity,
            threadOptions: .init(model: "gpt-5.1")
        )

        #expect(review.model == "gpt-5.1")
        #expect(review.identity.model == "gpt-5.1")
        let request = try #require(await runtime.transport.recordedRequests().last)
        let params = try request.decodeParams(AppServerAPI.Thread.Resume.Params.self)
        #expect(params.threadID == "thread-review")
        #expect(params.model == "gpt-5.1")
    }

    @Test func reviewSessionCancelHookReceivesCurrentActiveTurn() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-review but found turn-new",
            for: "turn/interrupt"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let recorder = CancellationRecorder()

        let review = try await runtime.server.resumeReview(identity)
        let cancellation = try await review.cancel { cancellation in
            await recorder.append(cancellation)
        }

        #expect(cancellation.threadID == "thread-review")
        #expect(cancellation.turnID == "turn-new")
        #expect(await recorder.values() == [
            CodexTurnCancellation(threadID: "thread-review", turnID: "turn-new")
        ])
        let turnIDs = try await runtime.transport.recordedRequests(method: "turn/interrupt")
            .map { request in
                try request.decodeParams(AppServerAPI.Turn.Interrupt.Params.self).turnID
        }
        #expect(turnIDs == ["turn-review", "turn-new"])
    }

    @Test func reviewSequencesFilterEventsOutsideTerminalTurn() async throws {
        let oldMessage = CodexMessage(
            id: "old-message",
            role: .assistant,
            text: "Old review"
        )
        let currentMessage = CodexMessage(
            id: "current-message",
            role: .assistant,
            text: "Current review"
        )
        let followUpMessage = CodexMessage(
            id: "follow-up-message",
            role: .assistant,
            text: "Follow-up turn"
        )
        let events = [
            CodexThreadEvent.message(oldMessage, turnID: "turn-old"),
            .statusChanged(.active(activeFlags: [])),
            .message(currentMessage, turnID: "turn-current"),
            .turnCompleted(.init(turnID: "turn-old", status: .completed)),
            .turnCompleted(.init(turnID: "turn-current", status: .completed)),
            .message(followUpMessage, turnID: "turn-follow-up"),
        ]
        let eventSequence = CodexThreadEventSequence {
            AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        let reviewEvents = try await collect(CodexReviewEventSequence(
            events: eventSequence,
            terminalTurnID: "turn-current"
        ))
        let progress = try await collect(CodexReviewProgressSequence(
            events: eventSequence,
            terminalTurnID: "turn-current"
        ))
        let logs = try await collect(CodexThreadLogSequence(
            events: eventSequence,
            terminalTurnID: "turn-current"
        ))

        #expect(reviewEvents.count == 3)
        #expect(reviewEvents.contains(.statusChanged(.active(activeFlags: []))))
        #expect(progress.count == 3)
        #expect(progress.last?.result?.turnID == "turn-current")
        #expect(progress.last?.transcript.responseText == "Current review")
        #expect(logs.map(\.id) == ["current-message"])
        #expect(logs.allSatisfy { $0.turnID == "turn-current" })
    }

    @Test func threadTurnsListRequestUsesThreadScope() {
        let request = AppServerAPI.Thread.Turns.List.Request(params: .init(threadID: "thread-1"))

        #expect(request.scope == .thread("thread-1"))
    }

    @Test func appServerPrepareAndRestartReviewUsesLifecycleControlSequence() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-review-restarted"
        )
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )

        let prepareTask = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-review", status: "interrupted"))
        )
        let token = try await withTimeout {
            try await prepareTask.value
        }
        let review = try await runtime.server.restartPreparedReview(
            token,
            target: .baseBranch("main"),
            delivery: .detached
        )

        #expect(token.interruptedIdentity == identity)
        #expect(review.identity == CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-restarted",
            reviewThreadID: "thread-review-restarted"
        ))
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/resume",
            "turn/interrupt",
            "thread/resume",
            "thread/rollback",
            "thread/resume",
            "review/start",
        ])
        let resumeThreadIDs = try requests.filter { $0.method == "thread/resume" }.map {
            try $0.decodeParams(AppServerAPI.Thread.Resume.Params.self).threadID
        }
        #expect(resumeThreadIDs == ["thread-review", "thread-review", "thread-source"])
        let resumeModels = try requests.filter { $0.method == "thread/resume" }.map {
            try $0.decodeParams(AppServerAPI.Thread.Resume.Params.self).model
        }
        #expect(resumeModels == ["gpt-5", "gpt-5", nil])
        let interrupt = try #require(requests.first { $0.method == "turn/interrupt" })
        let interruptParams = try interrupt.decodeParams(AppServerAPI.Turn.Interrupt.Params.self)
        #expect(interruptParams.threadID == "thread-review")
        #expect(interruptParams.turnID == "turn-review")
        let rollback = try #require(requests.first { $0.method == "thread/rollback" })
        let rollbackParams = try rollback.decodeParams(AppServerAPI.Thread.Rollback.Params.self)
        #expect(rollbackParams.threadID == "thread-review")
        #expect(rollbackParams.numTurns == 1)
        let reviewStart = try #require(requests.last)
        let reviewStartParams = try reviewStart.decodeParams(AppServerAPI.Review.Start.Params.self)
        #expect(reviewStartParams.threadID == "thread-source")
        #expect(reviewStartParams.target == .baseBranch("main"))
        #expect(reviewStartParams.delivery == .detached)
    }

    @Test func cleanupReviewKeepsCancellationRetryCleanupForPreparedRestart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-review but found turn-new",
            for: "turn/interrupt"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let restartedIdentity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-restarted",
            reviewThreadID: "thread-review-restarted",
            model: "gpt-5"
        )

        let prepareTask = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt", count: 2)
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-new", status: "interrupted"))
        )
        _ = try await withTimeout {
            try await prepareTask.value
        }
        await runtime.server.cleanupReview(restartedIdentity)

        let interruptTurnIDs = try await runtime.transport.recordedRequests(method: "turn/interrupt").map {
            try $0.decodeParams(AppServerAPI.Turn.Interrupt.Params.self).turnID
        }
        #expect(interruptTurnIDs == ["turn-review", "turn-new"])
        let deletedThreadIDs = try await runtime.transport.recordedRequests(method: "thread/delete").map {
            try $0.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
        }
        #expect(deletedThreadIDs == [
            "thread-review",
            "thread-review-restarted",
            "thread-source",
        ])
    }

    @Test func cleanupReviewDeletesDetachedThreadsBeforeSourceAndDedupes() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )

        await runtime.server.cleanupReview(
            identity,
            additionalCleanupThreadIDs: [
                ["thread-source", "thread-extra", "thread-review"],
                ["thread-extra", "thread-extra-2", "thread-source"],
            ]
        )

        let deletedThreadIDs = try await runtime.transport.recordedRequests(method: "thread/delete").map {
            try $0.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
        }
        #expect(deletedThreadIDs == [
            "thread-review",
            "thread-extra",
            "thread-extra-2",
            "thread-source",
        ])
    }

    @Test func restartPreparedReviewRejectsStaleTokenWithMeaningfulError() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let token = CodexReviewRestartToken(
            id: "stale-token",
            interruptedIdentity: .init(threadID: "thread-source", turnID: "turn-review")
        )

        do {
            _ = try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
            Issue.record("Expected stale restart token to throw.")
        } catch let error as CodexAppServerError {
            #expect(error == .reviewRestartUnavailable("stale-token"))
            #expect(error.localizedDescription.contains("stale-token"))
        } catch {
            Issue.record("Expected CodexAppServerError, got \(error).")
        }
    }

    @Test func restartPreparedReviewKeepsTokenForRetryAfterPartialFailure() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let prepareTask = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-review", status: "interrupted"))
        )
        let token = try await withTimeout {
            try await prepareTask.value
        }

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        await runtime.transport.enqueueFailure(
            code: -32000,
            message: "source resume failed",
            for: "thread/resume"
        )
        do {
            _ = try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
            Issue.record("Expected source resume failure.")
        } catch {
            #expect(String(describing: error).contains("source resume failed"))
        }

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(turnID: "turn-restarted")
        let review = try await runtime.server.restartPreparedReview(
            token,
            target: .baseBranch("main")
        )

        #expect(review.identity == CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-restarted"
        ))
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/resume",
            "turn/interrupt",
            "thread/resume",
            "thread/rollback",
            "thread/resume",
            "thread/resume",
            "review/start",
        ])
        #expect(requests.filter { $0.method == "thread/rollback" }.count == 1)
        let resumeThreadIDs = try requests.filter { $0.method == "thread/resume" }.map {
            try $0.decodeParams(AppServerAPI.Thread.Resume.Params.self).threadID
        }
        #expect(resumeThreadIDs == [
            "thread-review",
            "thread-review",
            "thread-source",
            "thread-source",
        ])
    }

    @Test func restartPreparedReviewKeepsTokenWhenCancelledAfterSourceResume() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)

        let rollbackGate = CodexAppServerTestGate()
        let sourceResumeGate = CodexAppServerTestGate()
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/rollback",
            gate: rollbackGate
        )
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        let restart = Task {
            try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
        }
        defer {
            restart.cancel()
        }

        await runtime.transport.waitForRequest(method: "thread/rollback")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/resume",
            gate: sourceResumeGate
        )
        await rollbackGate.open()
        await runtime.transport.waitForRequest(method: "thread/resume", count: 3)
        restart.cancel()
        await sourceResumeGate.open()

        do {
            _ = try await withTimeout {
                try await restart.value
            }
            Issue.record("Expected cancelled source resume failure.")
        } catch is CancellationError {
            #expect(await runtime.transport.recordedRequests(method: "review/start").isEmpty)
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(turnID: "turn-restarted")
        let review = try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))

        #expect(review.identity == CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-restarted"
        ))
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/resume",
            "turn/interrupt",
            "thread/resume",
            "thread/rollback",
            "thread/resume",
            "thread/resume",
            "review/start",
        ])
        #expect(requests.filter { $0.method == "thread/rollback" }.count == 1)
    }

    @Test func restartPreparedReviewCleansDetachedReviewWhenCancelledDuringReviewStart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)
        let reviewStartGate = CodexAppServerTestGate()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-review-restarted"
        )
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: reviewStartGate
        )

        let restart = Task {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main"),
                delivery: .detached
            )
        }
        defer {
            restart.cancel()
        }
        await runtime.transport.waitForRequest(method: "review/start")
        restart.cancel()
        await reviewStartGate.open()

        do {
            _ = try await withTimeout {
                try await restart.value
            }
            Issue.record("Expected cancelled review start failure.")
        } catch is CancellationError {
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/resume",
                "turn/interrupt",
                "thread/resume",
                "thread/rollback",
                "thread/resume",
                "review/start",
                "thread/delete",
                "thread/delete",
                "thread/delete",
            ])
            let deletedThreadIDs = try requests.suffix(3).map {
                try $0.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
            }
            #expect(deletedThreadIDs == [
                "thread-review",
                "thread-review-restarted",
                "thread-source",
            ])
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }

        do {
            _ = try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
            Issue.record("Expected cleaned up restart token to throw.")
        } catch let error as CodexAppServerError {
            #expect(error == .reviewRestartUnavailable(token.id))
        } catch {
            Issue.record("Expected CodexAppServerError, got \(error).")
        }
    }

    @Test func restartPreparedReviewRejectsConcurrentTokenReuse() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let prepareTask = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-review", status: "interrupted"))
        )
        let token = try await withTimeout {
            try await prepareTask.value
        }

        let resumeGate = CodexAppServerTestGate()
        await runtime.transport.holdNext(method: "thread/resume", gate: resumeGate)
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(turnID: "turn-restarted")
        let firstRestart = Task {
            try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
        }
        defer {
            firstRestart.cancel()
        }
        await runtime.transport.waitForRequest(method: "thread/resume", count: 2)

        do {
            _ = try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
            Issue.record("Expected concurrent token reuse to throw.")
        } catch let error as CodexAppServerError {
            #expect(error == .reviewRestartUnavailable(token.id))
        } catch {
            Issue.record("Expected CodexAppServerError, got \(error).")
        }

        await resumeGate.open()
        let review = try await withTimeout {
            try await firstRestart.value
        }

        #expect(review.turnID == "turn-restarted")
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.filter { $0.method == "thread/rollback" }.count == 1)
        #expect(requests.filter { $0.method == "review/start" }.count == 1)
        let resumeThreadIDs = try requests.filter { $0.method == "thread/resume" }.map {
            try $0.decodeParams(AppServerAPI.Thread.Resume.Params.self).threadID
        }
        #expect(resumeThreadIDs == ["thread-review", "thread-review", "thread-source"])
    }

    @Test func reviewStartSeedsDetachedTurnRoutingForTurnOnlyTerminalNotifications() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let review = try await thread.startReview(
            target: .baseBranch("main"),
            delivery: .detached
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-review", status: "completed"))
        )

        var eventIterator = review.events.makeAsyncIterator()
        let event = try await eventIterator.next()
        if case .turnCompleted(let response) = event {
            #expect(response.turnID == "turn-review")
        } else {
            Issue.record("Expected review.events to receive turn-only completion.")
        }
        #expect(try await eventIterator.next() == nil)

        var progressIterator = review.progress.makeAsyncIterator()
        let progress = try #require(try await progressIterator.next())
        #expect(progress.phase == .completed)
        #expect(progress.result?.turnID == "turn-review")
        #expect(try await progressIterator.next() == nil)
    }

    @Test func normalTurnSeedsThreadRoutingForTurnOnlyTerminalNotifications() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)
        let eventTask = Task { () -> CodexThreadEvent? in
            var iterator = thread.events.makeAsyncIterator()
            return try await iterator.next()
        }
        defer {
            eventTask.cancel()
        }
        #expect(await eventually {
            await router.threadSubscriberCountForTesting(for: "thread-1") == 1
        })

        _ = try await thread.streamResponse(to: "Run checks.")
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )

        let event = try await withTimeout {
            try await eventTask.value
        }
        if case .turnCompleted(let response) = event {
            #expect(response.turnID == "turn-1")
        } else {
            Issue.record("Expected thread.events to receive turn-only completion.")
        }
    }

    @Test func reviewEventsPreserveUnknownNotificationsAsRawDomainEvents() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let review = try await thread.startReview(
            target: .baseBranch("main"),
            delivery: .detached
        )
        try await transport.emitServerNotification(
            method: "review/futureEvent",
            params: TurnIDParams(turnID: "turn-review")
        )

        var iterator = review.events.makeAsyncIterator()
        let event = try await iterator.next()
        if case .unknown(let raw) = event {
            #expect(raw.method == "review/futureEvent")
            #expect(raw.threadID == "thread-review")
            #expect(raw.turnID == "turn-review")
        } else {
            Issue.record("Expected unknown review notification to be preserved.")
        }
    }

    @Test func reviewEventsRouteThreadlessBroadcastsToSeededReviewThread() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let review = try await thread.startReview(
            target: .baseBranch("main"),
            delivery: .detached
        )
        try await transport.emitServerNotification(
            method: "warning",
            params: ReviewWarningParams(message: "model warning")
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-review")
        )

        let events = try await collect(review.events)
        #expect(
            events.contains {
                if case .unknown(let raw) = $0 {
                    let text = String(data: raw.params, encoding: .utf8) ?? ""
                    return raw.method == "warning"
                        && raw.threadID == "thread-review"
                        && text.contains("model warning")
                }
                return false
            })
    }

    @Test func reviewEventsRouteIdentifiedBroadcastMethodsThroughTurnSeed() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let review = try await thread.startReview(
            target: .baseBranch("main"),
            delivery: .detached
        )
        try await transport.emitServerNotification(
            method: "error",
            params: ReviewErrorParams(turnID: "turn-review", message: "recoverable")
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-review")
        )

        let events = try await collect(review.events)
        #expect(
            events.contains {
                if case .unknown(let raw) = $0 {
                    return raw.method == "error"
                        && raw.threadID == "thread-review"
                        && raw.turnID == "turn-review"
                }
                return false
            })
    }

    @Test func promptPartsEncodeToAppServerInputItems() {
        let prompt = CodexPrompt(parts: [
            .text("Describe these files."),
            .imageURL(URL(string: "https://example.test/diagram.png")!),
            .localImage(URL(fileURLWithPath: "/tmp/screenshot.png")),
            .skill(name: "checks", path: URL(fileURLWithPath: "/tmp/skills/checks")),
            .mention(name: "repo", path: URL(fileURLWithPath: "/tmp/repo")),
            .mention(name: "app", path: URL(string: "app://demo-app")!),
            .mention(name: "plugin", path: URL(string: "plugin://sample@test")!),
        ])

        #expect(
            prompt.appServerInput == [
                .text("Describe these files."),
                .image(url: "https://example.test/diagram.png"),
                .localImage(path: "/tmp/screenshot.png"),
                .skill(name: "checks", path: "/tmp/skills/checks"),
                .mention(name: "repo", path: "/tmp/repo"),
                .mention(name: "app", path: "app://demo-app"),
                .mention(name: "plugin", path: "plugin://sample@test"),
            ])
    }

    @Test func threadStatusNormalizesAppServerLiveStates() {
        #expect(CodexThreadStatus(rawValue: "active") == .active(activeFlags: []))
        #expect(CodexThreadStatus(rawValue: "idle") == .idle)
        #expect(CodexThreadStatus(rawValue: "notLoaded") == .notLoaded)
        #expect(CodexThreadStatus(rawValue: "systemError") == .systemError)
    }

    @Test func clientRetriesOverloadedRequestsThenSucceeds() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(code: -32001, message: "server busy", for: "ping")
        try await transport.enqueue(EmptyResponse(), for: "ping")
        let client = AppServerClient(
            transport: transport,
            overloadRetryDelay: { $0 == 0 ? .zero : nil },
            retrySleep: { _ in }
        )

        let _: EmptyResponse = try await client.send(
            method: "ping",
            params: EmptyResponse(),
            responseType: EmptyResponse.self
        )

        #expect(await transport.recordedRequests().map(\.method) == ["ping", "ping"])
    }

    @Test func scopedRequestCancelledWhileQueuedDoesNotSend() async throws {
        let transport = CodexAppServerTestTransport()
        let gate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(method: "turn/start", gate: gate)
        try await transport.enqueueTurnStart(turnID: "turn-1", status: "running")
        let client = AppServerClient(transport: transport)

        let first = Task {
            try await client.send(AppServerAPI.Turn.Start.Request(
                params: .init(threadID: "thread-1", input: [.text("first")])
            ))
        }
        await transport.waitForRequest(method: "turn/start")

        let second = Task {
            try await client.send(AppServerAPI.Turn.Start.Request(
                params: .init(threadID: "thread-1", input: [.text("second")])
            ))
        }
        try await Task.sleep(for: .milliseconds(20))
        second.cancel()

        await gate.open()
        _ = try await first.value
        do {
            _ = try await withTimeout {
                try await second.value
            }
            Issue.record("Expected the queued scoped request to throw CancellationError.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }

        #expect(await transport.recordedRequests(method: "turn/start").count == 1)
    }

    @Test func turnResultReplaysEarlyNotificationsAndKeepsUnknownEvents() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "future/notification",
            params: TurnIDParams(turnID: "turn-1")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", delta: "Done")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        let turn = CodexTurn(
            id: "turn-1",
            threadID: "thread-1",
            client: client,
            router: router
        )

        let events = try await collect(turn.events)
        #expect(
            events.contains {
                if case .unknown(let raw) = $0 {
                    raw.method == "future/notification"
                } else {
                    false
                }
            })
        let result = try await CodexResponseCollector.collect(
            from: .init {
                AsyncThrowingStream { continuation in
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            })
        #expect(result.turnID == "turn-1")
        #expect(result.status == .completed)
        #expect(result.finalAnswer == "Done")
    }

    @Test func threadEventStreamCancellationRemovesRouterSubscriber() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let consumer = Task {
            var iterator = thread.events.makeAsyncIterator()
            _ = try await iterator.next()
        }

        #expect(await eventually {
            await router.threadSubscriberCountForTesting(for: "thread-1") == 1
        })
        consumer.cancel()
        let removed = await eventually {
            await router.threadSubscriberCountForTesting(for: "thread-1") == 0
        }
        #expect(removed)
        if removed {
            try await consumer.value
        }
    }

    @Test func directThreadEventStreamCancellationRemovesRouterSubscriber() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let stream = await router.events(for: CodexThreadID(rawValue: "thread-1"))
        #expect(await router.threadSubscriberCountForTesting(for: "thread-1") == 1)

        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        }

        consumer.cancel()
        let removed = await eventually {
            await router.threadSubscriberCountForTesting(for: "thread-1") == 0
        }
        #expect(removed)
    }

    @Test func liveThreadEventStreamFinishesWhenHistoryIsAlreadyTerminal() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let replayStream = await router.events(for: CodexThreadID(rawValue: "thread-1"))
        let replayEvents = try await withTimeout {
            try await collect(replayStream)
        }
        #expect(replayEvents.contains { event in
            if case .closed = event {
                return true
            }
            return false
        })

        let stream = await router.liveEvents(for: CodexThreadID(rawValue: "thread-1"))
        #expect(await router.threadSubscriberCountForTesting(for: "thread-1") == 0)

        let events = try await withTimeout {
            try await collect(stream)
        }
        #expect(events.isEmpty)
    }

    @Test func threadEventStreamsReplayOnlyCurrentGenerationAfterNewGenerationStarts() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let firstGeneration = try await withTimeout {
            try await collect(await router.events(for: CodexThreadID(rawValue: "thread-1")))
        }
        #expect(firstGeneration.contains { event in
            if case .closed = event {
                return true
            }
            return false
        })

        await router.beginThreadEventGeneration("thread-1")
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-2",
                delta: "Current"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let currentGeneration = try await withTimeout {
            try await collect(await router.observationEvents(for: "thread-1"))
        }
        #expect(currentGeneration.count == 2)
        #expect(currentGeneration.contains { event in
            if case .messageDelta(let delta, let turnID) = event {
                return delta.text == "Current" && turnID == "turn-2"
            }
            return false
        })
        #expect(currentGeneration.last == .closed)
    }

    @Test func resumeThreadCapturesEventsReceivedDuringResume() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let gate = CodexAppServerTestGate()
        await runtime.transport.holdNext(method: "thread/resume", gate: gate)
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-resume-events"))

        let resumeTask = Task {
            try await runtime.server.resumeThread("thread-resume-events")
        }
        await runtime.transport.waitForRequest(method: "thread/resume")
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-resume-events",
                turnID: "turn-resume-events",
                delta: "During resume"
            )
        )
        await gate.open()

        let thread = try await resumeTask.value
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-resume-events")
        )

        let events = try await collect(thread.events)
        #expect(events.contains { event in
            if case .messageDelta(let delta, let turnID) = event {
                return delta.text == "During resume" && turnID == "turn-resume-events"
            }
            return false
        })
    }

    @Test func failedResumeDoesNotAdvanceThreadEventGeneration() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-resume-failure"))
        let thread = try await runtime.server.resumeThread("thread-resume-failure")
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-resume-failure",
                turnID: "turn-resume-failure",
                delta: "Before failed resume"
            )
        )

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "resume failed",
            for: "thread/resume"
        )
        do {
            _ = try await runtime.server.resumeThread("thread-resume-failure")
            Issue.record("Expected resume failure.")
        } catch {
            // Expected failure; the existing generation must remain replayable.
        }
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-resume-failure")
        )

        let events = try await collect(thread.events)
        #expect(events.contains { event in
            if case .messageDelta(let delta, let turnID) = event {
                return delta.text == "Before failed resume" && turnID == "turn-resume-failure"
            }
            return false
        })
    }

    @Test func turnEventStreamCancellationRemovesRouterSubscriber() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let turn = CodexTurn(
            id: "turn-1",
            threadID: "thread-1",
            client: client,
            router: router
        )

        let consumer = Task {
            var iterator = turn.events.makeAsyncIterator()
            _ = try await iterator.next()
        }

        #expect(await eventually {
            await router.turnSubscriberCountForTesting(for: "turn-1") == 1
        })
        consumer.cancel()
        let removed = await eventually {
            await router.turnSubscriberCountForTesting(for: "turn-1") == 0
        }
        #expect(removed)
        if removed {
            try await consumer.value
        }
    }

    @Test func directTurnEventStreamCancellationRemovesRouterSubscriber() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let stream = await router.events(for: CodexTurnID(rawValue: "turn-1"))
        #expect(await router.turnSubscriberCountForTesting(for: "turn-1") == 1)

        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        }

        consumer.cancel()
        let removed = await eventually {
            await router.turnSubscriberCountForTesting(for: "turn-1") == 0
        }
        #expect(removed)
    }

    @Test func threadStreamsReplayMessagesTranscriptLogsAndUsage() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "message-1",
                    type: "agentMessage",
                    text: "Interim",
                    phase: "commentary"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "message-2",
                    type: "agentMessage",
                    text: "Final",
                    phase: "final_answer"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "swift test",
                    aggregatedOutput: "passed",
                    status: "completed"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "thread/tokenUsage/updated",
            params: TokenUsageParams(
                threadID: "thread-1",
                turnID: "turn-1",
                tokenUsage: .init(
                    total: .init(inputTokens: 1, outputTokens: 2, totalTokens: 3)
                )
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let messages = try await collect(thread.messages)
        #expect(messages.map(\.text) == ["Interim", "Final"])
        #expect(messages.last?.phase == .finalAnswer)

        let transcripts = try await collect(thread.transcriptUpdates)
        #expect(transcripts.last?.finalAnswer == "Final")
        #expect(transcripts.last?.items.count == 3)

        let logs = try await collect(thread.logEntries)
        #expect(logs.contains { $0.item?.kind == .commandExecution })
        #expect(logs.contains { $0.item?.text == "Final" })

        let events = try await collect(thread.events)
        #expect(
            events.contains {
                if case .tokenUsageUpdated(let usage, let turnID) = $0 {
                    turnID == "turn-1" && usage.totalTokens == 3
                } else {
                    false
                }
            })
    }

    @Test func threadItemDecodeReadsTextObjectContentFragments() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "message-1",
                    type: "userMessage",
                    contentItems: [
                        .init(text: "hello"),
                        .init(text: "world"),
                    ]
                )
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let transcripts = try await collect(thread.transcriptUpdates)

        #expect(transcripts.last?.items.first?.text == "hello\nworld")
    }

    @Test func threadTranscriptScopesFallbackMessageDeltaIDsByTurn() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-1", turnID: "turn-1")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", delta: "First")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-1", turnID: "turn-2")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-2", delta: "Second")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-2", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let transcripts = try await collect(thread.transcriptUpdates)

        #expect(transcripts.last?.items.compactMap(\.text) == ["First", "Second"])
    }

    @Test func responseStreamYieldsSnapshotsAndCollectsFinalResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse {
            "Summarize this."
            CodexPrompt.Part.mention(name: "repo", path: URL(fileURLWithPath: "/tmp/repo"))
        }

        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", delta: "Final")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.turnID == "turn-1")
        #expect(first?.content == "Final")

        let response = try await stream.collect()
        #expect(response.turnID == "turn-1")
        #expect(response.finalAnswer == "Final")

        let request = try #require(await transport.recordedRequests().first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Start.Params.self, from: request.params)
        #expect(
            params.input == [
                .text("Summarize this."),
                .mention(name: "repo", path: "/tmp/repo"),
            ])
    }

    @Test func responseStreamCollectsTranscriptFromCompletedTurnItems() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let stream = try await thread.streamResponse(to: "Summarize this.")
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-1",
                status: "completed",
                items: [
                    .object([
                        "id": .string("message-1"),
                        "type": .string("agentMessage"),
                        "text": .string("Final from payload"),
                        "phase": .string("final_answer"),
                    ]),
                ]
            ))
        )

        let response = try await stream.collect()

        #expect(response.finalAnswer == "Final from payload")
        #expect(response.transcript.items.first?.text == "Final from payload")
    }

    @Test func responseStreamSnapshotsIncludeIncrementalTokenUsage() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let stream = try await thread.streamResponse(to: "Summarize usage.")
        try await transport.emitServerNotification(
            method: "thread/tokenUsage/updated",
            params: TokenUsageParams(
                threadID: "thread-1",
                turnID: "turn-1",
                tokenUsage: .init(
                    total: .init(inputTokens: 5, outputTokens: 8, totalTokens: 13)
                )
            )
        )

        var iterator = stream.makeAsyncIterator()
        let snapshot = try await iterator.next()

        #expect(snapshot?.turnID == "turn-1")
        #expect(snapshot?.usage?.inputTokens == 5)
        #expect(snapshot?.usage?.outputTokens == 8)
        #expect(snapshot?.usage?.totalTokens == 13)
        #expect(snapshot?.response == nil)
    }

    @Test func responseStreamFailureCarriesPartialResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let stream = try await thread.streamResponse(to: "Try this.")
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", delta: "Partial")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-1",
                status: "failed",
                error: .init(message: "Tool failed."),
                startedAt: 1_700_000_000,
                completedAt: 1_700_000_001,
                durationMS: 1_000
            ))
        )

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.content == "Partial")
        let terminal = try await iterator.next()
        #expect(terminal?.response?.status == .failed)
        #expect(terminal?.response?.errorMessage == "Tool failed.")
        #expect(terminal?.response?.transcript.responseText == "Partial")
        #expect(terminal?.response?.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(terminal?.response?.duration == .milliseconds(1_000))
        do {
            _ = try await iterator.next()
            Issue.record("Expected failed stream to throw after terminal snapshot.")
        } catch let error as CodexAppServerError {
            #expect(error.response?.status == .failed)
            #expect(error.response?.transcript.responseText == "Partial")
        }

        do {
            _ = try await stream.collect()
            Issue.record("Expected collect() to throw for failed turn.")
        } catch let error as CodexAppServerError {
            #expect(error.response?.status == .failed)
            #expect(error.response?.transcript.responseText == "Partial")
        }
    }

    @Test func responseStreamSerializesReasoningOptions() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        _ = try await thread.streamResponse(
            to: "Explain the patch.",
            options: .init(
                effort: .high,
                summary: .detailed,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["summary": .object(["type": .string("string")])]),
                ]),
                personality: .pragmatic,
                clientUserMessageID: "client-message-1"
            )
        )

        let request = try #require(await transport.recordedRequests().first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Start.Params.self,
            from: request.params
        )
        #expect(params.effort == "high")
        #expect(params.summary == "detailed")
        #expect(params.outputSchema == .object([
            "type": .string("object"),
            "properties": .object(["summary": .object(["type": .string("string")])]),
        ]))
        #expect(params.personality == "pragmatic")
        #expect(params.clientUserMessageID == "client-message-1")
    }

    @Test func responseStreamSerializesSandboxPolicyWithAppServerSchema() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        _ = try await thread.streamResponse(
            to: "Explain the patch.",
            options: .init(sandbox: .workspaceWrite)
        )

        let request = try #require(await transport.recordedRequests().first)
        let params = try #require(
            JSONSerialization.jsonObject(with: request.params) as? [String: Any]
        )
        let sandboxPolicy = try #require(params["sandboxPolicy"] as? [String: Any])
        #expect(sandboxPolicy["type"] as? String == "workspaceWrite")
        #expect((sandboxPolicy["writableRoots"] as? [Any])?.isEmpty == true)
        #expect(sandboxPolicy["networkAccess"] as? Bool == false)
        #expect(sandboxPolicy["excludeTmpdirEnvVar"] as? Bool == false)
        #expect(sandboxPolicy["excludeSlashTmp"] as? Bool == false)
        #expect(sandboxPolicy.keys.contains("writable_roots") == false)
        #expect(sandboxPolicy.keys.contains("network_access") == false)
    }

    @Test func responseStreamSerializesApprovalPolicyWithAppServerSchema() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        _ = try await thread.streamResponse(
            to: "Explain the patch.",
            options: .init(approvalMode: .autoReview)
        )

        let request = try #require(await transport.recordedRequests().first)
        let params = try #require(
            JSONSerialization.jsonObject(with: request.params) as? [String: Any]
        )
        #expect(params["approvalPolicy"] as? String == "on-request")
        #expect(params["approvalPolicy"] as? String != "onRequest")
    }

    @Test func messageDeltaLogEntriesUseUniqueEntryIDs() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(threadID: "thread-1", turnID: "turn-1", delta: "First")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(threadID: "thread-1", turnID: "turn-1", delta: "Second")
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let thread = CodexThread(id: "thread-1", client: client, router: router)
        let logs = try await collect(thread.logEntries)
        #expect(logs.map(\.id) == ["agent-message-delta:0", "agent-message-delta:1"])
        #expect(logs.compactMap(\.messageDelta).map(\.text) == ["First", "Second"])
    }

    @Test func threadLogEntriesContinueAfterTurnCompletionUntilThreadClosed() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(threadID: "thread-1", turnID: "turn-1", delta: "First")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(threadID: "thread-1", turnID: "turn-2", delta: "Second")
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let thread = CodexThread(id: "thread-1", client: client, router: router)
        let logs = try await collect(thread.logEntries)
        #expect(logs.map(\.id) == ["agent-message-delta:0", "agent-message-delta:1"])
        #expect(logs.compactMap(\.messageDelta).map(\.text) == ["First", "Second"])
    }

    @Test func threadLogEntriesIncludeProgressDeltaNotifications() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)

        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: ItemOutputDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "command-1",
                delta: "Compiling"
            )
        )
        try await transport.emitServerNotification(
            method: "item/fileChange/outputDelta",
            params: ItemOutputDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "file-1",
                delta: "diff --git"
            )
        )
        try await transport.emitServerNotification(
            method: "item/fileChange/patchUpdated",
            params: ItemPatchUpdatedParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "patch-1",
                changes: .array([
                    .object([
                        "kind": .string("update"),
                        "path": .string("Sources/File.swift"),
                    ]),
                ])
            )
        )
        try await transport.emitServerNotification(
            method: "item/mcpToolCall/progress",
            params: ItemProgressParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "tool-1",
                message: "Reviewing"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let thread = CodexThread(id: "thread-1", client: client, router: router)
        let logs = try await collect(thread.logEntries)

        #expect(logs.count == 4)
        #expect(logs.allSatisfy { $0.phase == .updated && $0.turnID == "turn-1" })
        #expect(logs.contains { $0.item?.kind == .commandExecution && $0.item?.text == "Compiling" })
        #expect(logs.contains { $0.item?.kind == .fileChange && $0.item?.text == "diff --git" })
        #expect(
            logs.contains {
                if case .fileChange(let fileChange) = $0.item?.content {
                    fileChange.output?.contains("File.swift") == true
                } else {
                    false
                }
            })
        #expect(
            logs.contains {
                if case .toolCall(let toolCall) = $0.item?.content {
                    toolCall.result == "Reviewing"
                } else {
                    false
                }
            })
    }

    @Test func completedFileChangeItemsPreserveChangesOutput() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "file-1",
                    type: "fileChange",
                    changes: .array([
                        .object([
                            "kind": .string("update"),
                            "path": .string("Sources/File.swift"),
                        ]),
                    ])
                )
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let logs = try await collect(thread.logEntries)

        #expect(logs.first?.item?.kind == .fileChange)
        #expect(logs.first?.item?.text?.contains("File.swift") == true)
    }

    @Test func reasoningNotificationsRouteAsTypedEventsLogsAndTranscript() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)

        try await transport.emitServerNotification(
            method: "item/reasoning/summaryPartAdded",
            params: ReasoningSummaryPartParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                summaryIndex: 0
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: ReasoningSummaryDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                summaryIndex: 0,
                delta: "Checking"
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/textDelta",
            params: ReasoningTextDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                contentIndex: 1,
                delta: "Raw trace"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "reasoning-1",
                    type: "reasoning",
                    summary: ["Final summary"],
                    content: ["Final raw"]
                )
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let thread = CodexThread(id: "thread-1", client: client, router: router)
        let events = try await collect(thread.events)
        #expect(
            events.contains {
                if case .reasoningSummaryPartAdded(let part, let turnID) = $0 {
                    part.id == "reasoning-1:summary:0" && turnID == "turn-1"
                } else {
                    false
                }
            })
        #expect(
            events.contains {
                if case .reasoningDelta(let delta, let turnID) = $0 {
                    delta.id == "reasoning-1:content:1"
                        && delta.delta == "Raw trace"
                        && turnID == "turn-1"
                } else {
                    false
                }
            })

        let logs = try await collect(thread.logEntries)
        #expect(logs.contains { $0.id == "reasoning-1:summary:0" && $0.phase == .started })
        #expect(
            logs.contains {
                $0.reasoningDelta?.id == "reasoning-1:summary:0"
                    && $0.reasoningDelta?.delta == "Checking"
            })
        #expect(
            logs.contains {
                $0.reasoningDelta?.id == "reasoning-1:content:1"
                    && $0.reasoningDelta?.delta == "Raw trace"
            })

        let transcripts = try await collect(thread.transcriptUpdates)
        let finalTranscript = try #require(transcripts.last)
        #expect(finalTranscript.items.map(\.id) == ["reasoning-1"])
        #expect(finalTranscript.items.first?.content == .reasoning(
            .init(summary: ["Final summary"], content: ["Final raw"])
        ))
    }

    @Test func modelAndConfigurationDecodeReasoningTypes() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "data": [
                {
                  "id": "gpt-5-codex",
                  "model": "gpt-5-codex",
                  "displayName": "GPT-5 Codex",
                  "hidden": false,
                  "supportedReasoningEfforts": [
                    {"reasoningEffort": "medium", "description": "Balanced"},
                    {"reasoningEffort": "xhigh", "description": "Maximum"}
                  ],
                  "defaultReasoningEffort": "xhigh",
                  "additionalSpeedTiers": [],
                  "isDefault": true
                }
              ],
              "nextCursor": null
            }
            """,
            for: "model/list"
        )
        try await transport.enqueueJSON(
            """
            {
              "config": {
                "model": "gpt-5-codex",
                "model_reasoning_effort": "high",
                "service_tier": "flex"
              }
            }
            """,
            for: "config/read"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let models = try await server.models()
        let reasoningEfforts = models.first?.supportedReasoningEfforts.map(\.reasoningEffort)
        #expect(reasoningEfforts == [.medium, .xhigh])
        #expect(models.first?.defaultReasoningEffort == .xhigh)

        let configuration = try await server.configuration()
        #expect(configuration.reasoningEffort == .high)
    }

    @Test func updateConfigurationSendsBatchWriteEdits() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(#"{"status":"ok"}"#, for: "config/batchWrite")
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        var patch = CodexConfigurationPatch()
        patch.setReviewModel("gpt-5-codex-review")
        patch.setReasoningEffort(.high)
        patch.setServiceTier("flex")
        try await server.updateConfiguration(patch)

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "config/batchWrite")
        let params = try request.decodeParams(ConfigBatchWriteParams.self)
        #expect(params.reloadUserConfig == true)
        #expect(params.edits == [
            .init(keyPath: "review_model", value: .string("gpt-5-codex-review")),
            .init(keyPath: "model_reasoning_effort", value: .string("high")),
            .init(keyPath: "service_tier", value: .string("flex")),
        ])
    }

    @Test func updateConfigurationSkipsEmptyPatch() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        try await server.updateConfiguration(.init())

        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test func testRuntimeEnqueuesRateLimitResetTimesInAppServerSeconds() async throws {
        let transport = CodexAppServerTestTransport()
        let resetDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await transport.enqueueRateLimits(.init(
            planType: "pro",
            windows: [
                .init(
                    windowDurationMinutes: 300,
                    usedPercent: 42,
                    resetsAt: resetDate
                ),
            ]
        ))
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let rateLimits = try await server.rateLimits()

        #expect(rateLimits.planType == "pro")
        #expect(rateLimits.windows == [
            .init(
                windowDurationMinutes: 300,
                usedPercent: 42,
                resetsAt: resetDate
            ),
        ])
    }

    @Test func rateLimitsDecodeCoreWindowWireShape() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "planType": "pro",
                "primary": {
                  "used_percent": 87.5,
                  "window_minutes": 60,
                  "resets_at": 1700000000
                }
              }
            }
            """,
            for: "account/rateLimits/read"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let rateLimits = try await server.rateLimits()

        #expect(rateLimits.planType == "pro")
        #expect(rateLimits.windows == [
            .init(
                windowDurationMinutes: 60,
                usedPercent: 88,
                resetsAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ])
    }

    @Test func accountReadAcceptsChatGPTAccountWithoutEmail() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "account": {
                "type": "chatgpt",
                "email": null,
                "planType": "plus"
              },
              "requiresOpenaiAuth": false
            }
            """,
            for: "account/read"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let account = try #require(try await server.account())

        #expect(account.kind == .chatGPT)
        #expect(account.id == "chatgpt")
        #expect(account.label == "ChatGPT")
        #expect(account.planType == "plus")
    }

    @Test func loginFlowUsesSupportedRequestsAndCompletionNotification() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        try await transport.enqueue(
            AppServerAPI.Account.Login.Cancel.Response(),
            for: "account/login/cancel"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )
        let accountEvents = await server.accountEvents()
        await transport.waitForNotificationStreamCount(1)

        let handle = try await server.loginChatGPT()

        #expect(handle == .chatGPT(
            id: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        ))
        let loginRequest = try #require(await transport.recordedRequests().first)
        #expect(loginRequest.method == "account/login/start")
        let loginParams = try loginRequest.decodeParams(AppServerAPI.Account.Login.Params.self)
        #expect(loginParams.type == "chatgpt")
        #expect(loginParams.codexStreamlinedLogin == true)

        try await server.cancelLogin(handle)
        let cancelRequest = try #require(await transport.recordedRequests().last)
        #expect(cancelRequest.method == "account/login/cancel")
        let cancelParams = try cancelRequest.decodeParams(
            AppServerAPI.Account.Login.Cancel.Params.self
        )
        #expect(cancelParams.loginID == "login-1")

        try await transport.emitServerNotification(
            method: "account/login/completed",
            params: LoginCompletedParams(loginID: "login-1", success: true)
        )
        var iterator = accountEvents.makeAsyncIterator()
        #expect(try await iterator.next() == .loginCompleted(.init(
            loginID: "login-1",
            success: true
        )))
        #expect(await transport.recordedRequests().map(\.method) == [
            "account/login/start",
            "account/login/cancel",
        ])
    }

    @Test func responseStreamCancelSendsTurnInterrupt() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        try await stream.cancel()

        #expect(
            await transport.recordedRequests().map(\.method) == [
                "turn/start",
                "turn/interrupt",
            ])
        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Interrupt.Params.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.turnID == "turn-1")
    }

    @Test func threadCancelActiveTurnSendsExpectedTurnID() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let cancellation = try await thread.cancelActiveTurn(expectedTurnID: "turn-1")

        #expect(cancellation.threadID == "thread-1")
        #expect(cancellation.turnID == "turn-1")
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "turn/interrupt")
        let params = try request.decodeParams(AppServerAPI.Turn.Interrupt.Params.self)
        #expect(params.threadID == "thread-1")
        #expect(params.turnID == "turn-1")
    }

    @Test func responseStreamCancelRetriesWithCurrentActiveTurnID() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-old", status: "running")),
            for: "turn/start"
        )
        await transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-old but found turn-new",
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        let cancellation = try await stream.cancel()

        #expect(cancellation.threadID == "thread-1")
        #expect(cancellation.turnID == "turn-new")
        let cancelRequests = await transport.recordedRequests().filter {
            $0.method == "turn/interrupt"
        }
        let turnIDs = try cancelRequests.map { request in
            try request.decodeParams(AppServerAPI.Turn.Interrupt.Params.self).turnID
        }
        #expect(turnIDs == ["turn-old", "turn-new"])
    }

    @Test func responseStreamCancelRetriesUntilExpectedTurnIsActive() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        await transport.enqueueFailure(
            code: -32602,
            message: "no active turn to interrupt",
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        let cancellation = try await stream.cancel()

        #expect(cancellation.threadID == "thread-1")
        #expect(cancellation.turnID == "turn-1")
        let turnIDs = try await transport.recordedRequests(method: "turn/interrupt").map {
            try $0.decodeParams(AppServerAPI.Turn.Interrupt.Params.self).turnID
        }
        #expect(turnIDs == ["turn-1", "turn-1"])
    }

    @Test func responseStreamSteerSubmitsInputToCurrentTurn() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        try await transport.enqueue(
            AppServerAPI.Turn.Steer.Response(turnID: "turn-1"),
            for: "turn/steer"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        try await stream.steer(with: "Prefer the smallest fix.")

        #expect(
            await transport.recordedRequests().map(\.method) == [
                "turn/start",
                "turn/steer",
            ])
        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Steer.Params.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.expectedTurnID == "turn-1")
        #expect(params.input == [.text("Prefer the smallest fix.")])
    }

    @Test func responseStreamQueueStartsFollowUpAfterCurrentResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-2", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse(to: "First request.")
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )

        _ = try await stream.submit(
            "Second request.",
            mode: .queueAfterCurrentResponse,
            options: .init(model: "gpt-5")
        )

        #expect(
            await transport.recordedRequests().map(\.method) == [
                "turn/start",
                "turn/start",
            ])
        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Start.Params.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.input == [.text("Second request.")])
        #expect(params.model == "gpt-5")
    }

    @Test func responseStreamCancelStartsFollowUpAfterServerTerminalEvent() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-2", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse(to: "Long request.")
        let followUpTask = Task {
            try await stream.submit(
                "Use the shorter path.",
                mode: .cancelCurrentResponse
            )
        }
        await transport.waitForRequestCount(2)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "interrupted"))
        )
        _ = try await followUpTask.value

        #expect(
            await transport.recordedRequests().map(\.method) == [
                "turn/start",
                "turn/interrupt",
                "turn/start",
            ])
        let interruptRequest = try #require(await transport.recordedRequests().dropLast().last)
        let interruptParams = try JSONDecoder().decode(
            AppServerAPI.Turn.Interrupt.Params.self, from: interruptRequest.params)
        #expect(interruptParams.threadID == "thread-1")
        #expect(interruptParams.turnID == "turn-1")

        let followUpRequest = try #require(await transport.recordedRequests().last)
        let followUpParams = try JSONDecoder().decode(
            AppServerAPI.Turn.Start.Params.self, from: followUpRequest.params)
        #expect(followUpParams.threadID == "thread-1")
        #expect(followUpParams.input == [.text("Use the shorter path.")])
    }

    @Test func responseStreamCancelFollowUpWaitsForRetriedActiveTurn() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-old", status: "running")),
            for: "turn/start"
        )
        await transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-old but found turn-new",
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-follow-up", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let stream = try await thread.streamResponse(to: "Long request.")
        let followUpTask = Task {
            try await stream.submit(
                "Continue after the active turn stops.",
                mode: .cancelCurrentResponse
            )
        }
        defer {
            followUpTask.cancel()
        }
        await transport.waitForRequestCount(3)
        #expect(await transport.recordedRequests().map(\.method) == [
            "turn/start",
            "turn/interrupt",
            "turn/interrupt",
        ])
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-new", status: "interrupted"))
        )
        _ = try await withTimeout {
            try await followUpTask.value
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "turn/start",
            "turn/interrupt",
            "turn/interrupt",
            "turn/start",
        ])
        let followUpParams = try #require(
            try requests.last?.decodeParams(AppServerAPI.Turn.Start.Params.self)
        )
        #expect(followUpParams.threadID == "thread-1")
        #expect(followUpParams.input == [.text("Continue after the active turn stops.")])
    }
}

private func collect<Sequence: AsyncSequence>(
    _ sequence: Sequence
) async throws -> [Sequence.Element] {
    var elements: [Sequence.Element] = []
    for try await element in sequence {
        elements.append(element)
    }
    return elements
}

private struct ConfigBatchWriteParams: Decodable, Equatable {
    var edits: [Edit]
    var reloadUserConfig: Bool

    struct Edit: Decodable, Equatable {
        var keyPath: String
        var value: AppServerJSONValue
        var mergeStrategy: String

        init(
            keyPath: String,
            value: AppServerJSONValue,
            mergeStrategy: String = "replace"
        ) {
            self.keyPath = keyPath
            self.value = value
            self.mergeStrategy = mergeStrategy
        }
    }
}

private struct TurnIDParams: Encodable, Sendable {
    var turnID: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
    }
}

private struct ThreadIDParams: Encodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct LoginCompletedParams: Encodable, Sendable {
    var loginID: String?
    var success: Bool
    var error: String?

    enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
        case success
        case error
    }

    init(loginID: String? = nil, success: Bool, error: String? = nil) {
        self.loginID = loginID
        self.success = success
        self.error = error
    }
}

private struct ReviewWarningParams: Encodable, Sendable {
    var message: String
}

private struct ReviewErrorParams: Encodable, Sendable {
    var turnID: String
    var message: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
        case message
    }
}

private struct TurnDeltaParams: Encodable, Sendable {
    var threadID: String? = nil
    var turnID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case delta
    }
}

private struct TurnStartedParams: Encodable, Sendable {
    var threadID: String
    var turnID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
    }
}

private struct ItemOutputDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

private struct ItemPatchUpdatedParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var changes: AppServerJSONValue

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case changes
    }
}

private struct ItemProgressParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var message: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case message
    }
}

private struct TurnCompletedParams: Encodable, Sendable {
    var turn: AppServerAPI.Turn.Payload
}

private struct ThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String?
        var phase: String?
        var command: String?
        var aggregatedOutput: String?
        var status: String?
        var path: String?
        var tool: String?
        var summary: [String]?
        var content: [String]?
        var contentItems: [TextContent]?
        var changes: AppServerJSONValue?

        init(
            id: String,
            type: String,
            text: String? = nil,
            phase: String? = nil,
            command: String? = nil,
            aggregatedOutput: String? = nil,
            status: String? = nil,
            path: String? = nil,
            tool: String? = nil,
            summary: [String]? = nil,
            content: [String]? = nil,
            contentItems: [TextContent]? = nil,
            changes: AppServerJSONValue? = nil
        ) {
            self.id = id
            self.type = type
            self.text = text
            self.phase = phase
            self.command = command
            self.aggregatedOutput = aggregatedOutput
            self.status = status
            self.path = path
            self.tool = tool
            self.summary = summary
            self.content = content
            self.contentItems = contentItems
            self.changes = changes
        }

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case text
            case phase
            case command
            case aggregatedOutput
            case status
            case path
            case tool
            case summary
            case content
            case changes
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(phase, forKey: .phase)
            try container.encodeIfPresent(command, forKey: .command)
            try container.encodeIfPresent(aggregatedOutput, forKey: .aggregatedOutput)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encodeIfPresent(path, forKey: .path)
            try container.encodeIfPresent(tool, forKey: .tool)
            try container.encodeIfPresent(summary, forKey: .summary)
            try container.encodeIfPresent(changes, forKey: .changes)
            if let contentItems {
                try container.encode(contentItems, forKey: .content)
            } else {
                try container.encodeIfPresent(content, forKey: .content)
            }
        }

        struct TextContent: Encodable, Sendable {
            var type = "text"
            var text: String
        }
    }
}

private struct ReasoningSummaryPartParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var summaryIndex: Int

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case summaryIndex
    }
}

private struct ReasoningSummaryDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var summaryIndex: Int
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case summaryIndex
        case delta
    }
}

private struct ReasoningTextDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var contentIndex: Int
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case contentIndex
        case delta
    }
}

private struct TokenUsageParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var tokenUsage: TokenUsage

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case tokenUsage
    }

    struct TokenUsage: Encodable, Sendable {
        var total: Breakdown
        var modelContextWindow: Int?
    }

    struct Breakdown: Encodable, Sendable {
        var cachedInputTokens: Int = 0
        var inputTokens: Int
        var outputTokens: Int
        var reasoningOutputTokens: Int = 0
        var totalTokens: Int
    }
}

private actor CancellationRecorder {
    private var cancellations: [CodexTurnCancellation] = []

    func append(_ cancellation: CodexTurnCancellation) {
        cancellations.append(cancellation)
    }

    func values() -> [CodexTurnCancellation] {
        cancellations
    }
}

private actor ServerRequestRecorder {
    private var recordedRequests: [CodexAppServerRequest] = []

    func append(_ request: CodexAppServerRequest) {
        recordedRequests.append(request)
    }

    func requests() -> [CodexAppServerRequest] {
        recordedRequests
    }
}

private func eventually(
    attempts: Int = 50,
    _ condition: () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private enum TestTimeoutError: Error {
    case timedOut
}

private func prepareRestartToken(
    runtime: CodexAppServerTestRuntime,
    identity: CodexReviewIdentity
) async throws -> CodexReviewRestartToken {
    try await runtime.transport.enqueueThreadResume(.init(id: identity.activeTurnThreadID))
    try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
    let prepareTask = Task {
        try await runtime.server.prepareReviewRestart(identity)
    }
    defer {
        prepareTask.cancel()
    }
    await runtime.transport.waitForRequest(method: "turn/interrupt")
    try await runtime.transport.emitServerNotification(
        method: "turn/completed",
        params: TurnCompletedParams(turn: .init(id: identity.turnID.rawValue, status: "interrupted"))
    )
    return try await withTimeout {
        try await prepareTask.value
    }
}

private func withTimeout<Value: Sendable>(
    _ timeout: Duration = .seconds(1),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestTimeoutError.timedOut
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
