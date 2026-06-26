import CodexAppServerKit
import CodexAppServerKitTesting
import CodexUIKit
import Foundation
import Testing

@MainActor
struct CodexThreadLibraryTests {
    @Test("refresh connects to thread/list and preserves thread object identity")
    func refreshConnectsAndMutatesExistingThreads() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-1", name: "First", turns: [
                    .init(id: "turn-1", status: .running)
                ]),
            ],
            nextCursor: "next"
        ))

        let library = CodexThreadLibrary(server: runtime.server)
        await library.refresh()

        let section = try #require(library.sections.first)
        let first = try #require(section.threads.first)
        #expect(first.title == "First")
        #expect(first.latestTurnStatus == .running)
        #expect(library.nextCursor == "next")

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-1", name: "First renamed", turns: [
                .init(id: "turn-1", status: .completed)
            ]),
            .init(id: "thread-2", name: "Second"),
        ]))

        await library.refresh()

        #expect(section.threads.count == 2)
        #expect(section.threads[0] === first)
        #expect(section.threads[0].title == "First renamed")
        #expect(section.threads[0].latestTurnStatus == .completed)

        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/list" }.count == 2)
    }

    @Test("selectedConversation resumes the selected thread without exposing DTOs")
    func selectedConversationConnectsThroughServer() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-selected", name: "Selected")
        ]))
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-selected",
            workspace: URL(fileURLWithPath: "/tmp/selected", isDirectory: true)
        ))

        let library = CodexThreadLibrary(server: runtime.server)
        await library.refresh()
        library.selectThread("thread-selected")

        let conversation = try await library.selectedConversation()

        #expect(conversation.id == "thread-selected")
        #expect(conversation.workspace?.path == "/tmp/selected")
        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/resume"))
    }

    @Test("archive is a server-level list action and does not resume the thread")
    func archiveDoesNotResumeThread() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", name: "Archive me")
        ]))
        try await runtime.transport.enqueueEmpty(for: "thread/archive")

        let library = CodexThreadLibrary(server: runtime.server)
        await library.refresh()
        try await library.archive("thread-archive")

        #expect(library.sections.first?.threads.isEmpty == true)
        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/archive"))
        #expect(methods.contains("thread/resume") == false)
    }

    @Test("archive refreshes server-filtered libraries")
    func archiveRefreshesServerFilteredLibrary() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(
            threads: [.init(id: "thread-archive", name: "Archive me")],
            nextCursor: "old-next"
        ))
        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await runtime.transport.enqueueThreadList(.init(
            threads: [.init(id: "thread-replacement", name: "Replacement")],
            nextCursor: "new-next"
        ))

        let library = CodexThreadLibrary(
            server: runtime.server,
            configuration: .init(query: .init(limit: 1))
        )
        await library.refresh()
        library.selectThread("thread-archive")

        try await library.archive("thread-archive")

        #expect(library.sections.first?.threads.map(\.id) == ["thread-replacement"])
        #expect(library.selectedThreadID == nil)
        #expect(library.nextCursor == "new-next")
        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/list" }.count == 2)
    }

    @Test("archive refreshes when the loaded list is paginated")
    func archiveRefreshesPaginatedLoadedLibrary() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(
            threads: [.init(id: "thread-archive", name: "Archive me")],
            nextCursor: "old-next"
        ))
        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await runtime.transport.enqueueThreadList(.init(
            threads: [.init(id: "thread-replacement", name: "Replacement")],
            nextCursor: "new-next"
        ))

        let library = CodexThreadLibrary(server: runtime.server)
        await library.refresh()

        try await library.archive("thread-archive")

        #expect(library.sections.first?.threads.map(\.id) == ["thread-replacement"])
        #expect(library.nextCursor == "new-next")
        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/list" }.count == 2)
    }

    @Test("archive refreshes archived-only libraries")
    func archiveRefreshesArchivedOnlyLibrary() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", name: "Archived")
        ]))

        let library = CodexThreadLibrary(
            server: runtime.server,
            configuration: .init(query: .init(archived: true))
        )
        await library.refresh()

        try await library.archive("thread-archive")

        #expect(library.sections.first?.threads.map(\.id) == ["thread-archive"])
        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/list" }.count == 2)
    }

    @Test("unarchive removes a thread from an archived-only library")
    func unarchiveRemovesThreadFromArchivedQuery() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archived", name: "Archived")
        ]))
        try await runtime.transport.enqueueThreadUnarchive(.init(
            id: "thread-archived",
            name: "Restored"
        ))

        let library = CodexThreadLibrary(
            server: runtime.server,
            configuration: .init(query: .init(archived: true))
        )
        await library.refresh()
        library.selectThread("thread-archived")

        try await library.unarchive("thread-archived")

        #expect(library.sections.first?.threads.isEmpty == true)
        #expect(library.selectedThreadID == nil)
    }

    @Test("unarchive preserves metadata for a visible restored thread")
    func unarchivePreservesVisibleThreadMetadata() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let restored = CodexThreadSnapshot(
            id: "thread-restored",
            workspace: URL(fileURLWithPath: "/tmp/restored", isDirectory: true),
            name: "Restored",
            preview: "Preview",
            turns: [.init(id: "turn-restored", status: .completed)]
        )
        try await runtime.transport.enqueueThreadUnarchive(restored)
        try await runtime.transport.enqueueThreadRead(restored)

        let library = CodexThreadLibrary(server: runtime.server)
        await library.refresh()

        try await library.unarchive("thread-restored")

        let thread = try #require(library.sections.first?.threads.first)
        #expect(thread.id == "thread-restored")
        #expect(thread.title == "Restored")
        #expect(thread.preview == "Preview")
        #expect(thread.turnCount == 1)
        #expect(thread.latestTurnStatus == .completed)

        let request = try #require(await runtime.transport.recordedRequests(method: "thread/read").first)
        let params = try request.decodeParams(ThreadReadParams.self)
        #expect(params.threadID == "thread-restored")
        #expect(params.includeTurns == true)
    }

    @Test("startConversation does not insert threads outside the workspace query")
    func startConversationHonorsWorkspaceQuery() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await runtime.transport.enqueueThreadStart(threadID: "thread-other")

        let queryWorkspace = URL(fileURLWithPath: "/tmp/query", isDirectory: true)
        let otherWorkspace = URL(fileURLWithPath: "/tmp/other", isDirectory: true)
        let library = CodexThreadLibrary(
            server: runtime.server,
            configuration: .init(query: .init(workspace: queryWorkspace))
        )
        await library.refresh()

        let conversation = try await library.startConversation(in: otherWorkspace)

        #expect(conversation.id == "thread-other")
        #expect(library.sections.first?.threads.isEmpty == true)
        #expect(library.selectedThreadID == nil)
    }

    @Test("startConversation refreshes instead of inserting into server-filtered queries")
    func startConversationRefreshesServerFilteredQuery() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await runtime.transport.enqueueThreadStart(threadID: "thread-filtered")
        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let workspace = URL(fileURLWithPath: "/tmp/query", isDirectory: true)
        let library = CodexThreadLibrary(
            server: runtime.server,
            configuration: .init(query: .init(searchTerm: "needle"))
        )
        await library.refresh()

        let conversation = try await library.startConversation(in: workspace)

        #expect(conversation.id == "thread-filtered")
        #expect(library.sections.first?.threads.isEmpty == true)
        #expect(library.selectedThreadID == nil)
        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/list" }.count == 2)
    }

    @Test("delete refreshes server-filtered libraries")
    func deleteRefreshesServerFilteredLibrary() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(
            threads: [.init(id: "thread-delete", name: "Delete me")],
            nextCursor: "old-next"
        ))
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueThreadList(.init(
            threads: [.init(id: "thread-replacement", name: "Replacement")],
            nextCursor: "new-next"
        ))

        let library = CodexThreadLibrary(
            server: runtime.server,
            configuration: .init(query: .init(limit: 1))
        )
        await library.refresh()
        library.selectThread("thread-delete")

        try await library.delete("thread-delete")

        #expect(library.sections.first?.threads.map(\.id) == ["thread-replacement"])
        #expect(library.selectedThreadID == nil)
        #expect(library.nextCursor == "new-next")
        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/list" }.count == 2)
    }

    @Test("refresh preserves configured thread-list cursor")
    func refreshPreservesConfiguredCursor() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-cursor", name: "Cursor page")
        ]))

        let library = CodexThreadLibrary(
            server: runtime.server,
            configuration: .init(query: .init(cursor: "configured-cursor", limit: 1))
        )
        await library.refresh()

        let request = try #require(await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try request.decodeParams(ThreadListParams.self)
        #expect(params.cursor == "configured-cursor")
        #expect(params.limit == 1)
    }
}

@MainActor
struct CodexConversationTests {
    @Test("refresh reads thread state into semantic observable properties")
    func refreshMutatesSemanticState() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-1",
            workspace: URL(fileURLWithPath: "/tmp/thread", isDirectory: true)
        ))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-1",
            workspace: URL(fileURLWithPath: "/tmp/thread", isDirectory: true),
            name: "Conversation",
            preview: "Preview",
            turns: [
                .init(id: "turn-1", status: .running),
            ]
        ))

        let conversation = try await CodexConversation.resume("thread-1", server: runtime.server)
        try await conversation.refresh()

        let turn = try #require(conversation.turns.first)
        #expect(conversation.title == "Conversation")
        #expect(conversation.preview == "Preview")
        #expect(turn.status == .running)
    }

    @Test("refresh preserves turn identity for the same semantic turn")
    func refreshPreservesTurnIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-1"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-1",
            turns: [.init(id: "turn-1", status: .running)]
        ))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-1",
            turns: [.init(id: "turn-1", status: .completed)]
        ))

        let conversation = try await CodexConversation.resume("thread-1", server: runtime.server)
        try await conversation.refresh()
        let firstTurn = try #require(conversation.turns.first)
        try await conversation.refresh()

        #expect(conversation.turns.first === firstTurn)
        #expect(firstTurn.status == .completed)
    }

    @Test("refresh populates transcript items from turn history")
    func refreshPopulatesTranscriptItemsFromTurnHistory() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-1"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-1",
            turns: [
                .init(
                    id: "turn-1",
                    status: .completed,
                    items: [
                        .init(
                            id: "message-1",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-1",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Done"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let conversation = try await CodexConversation.resume("thread-1", server: runtime.server)
        try await conversation.refresh()

        let item = try #require(conversation.items.first)
        #expect(conversation.items.count == 1)
        #expect(item.id == "message-1")
        #expect(item.turnID == "turn-1")
        #expect(item.text == "Done")
        #expect(conversation.transcript.finalAnswer == "Done")
    }

    @Test("metadata-only refresh preserves existing turns")
    func metadataOnlyRefreshPreservesExistingTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-1"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-1",
            name: "Conversation",
            turns: [.init(id: "turn-1", status: .running)]
        ))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-1",
            name: "Conversation renamed",
            turns: []
        ))

        let conversation = try await CodexConversation.resume("thread-1", server: runtime.server)
        try await conversation.refresh()
        let firstTurn = try #require(conversation.turns.first)
        try await conversation.refresh(includeTurns: false)

        #expect(conversation.title == "Conversation renamed")
        #expect(conversation.turns.first === firstTurn)
        #expect(firstTurn.status == .running)
        let requests = await runtime.transport.recordedRequests(method: "thread/read")
        let params = try requests.map { try $0.decodeParams(ThreadReadParams.self) }
        #expect(params.map(\.includeTurns) == [true, false])
    }

    @Test("send merges transcript items into observable item objects")
    func sendMergesTranscriptItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-send"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-send", status: "running")

        let conversation = try await CodexConversation.resume("thread-send", server: runtime.server)
        let sendTask = Task {
            try await conversation.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-send",
                turnID: "turn-send",
                item: .init(
                    id: "message-1",
                    type: "agentMessage",
                    text: "Done",
                    phase: "final_answer"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-send", status: "completed"))
        )

        let response = try await sendTask.value
        let item = try #require(conversation.items.first)
        #expect(response.turnID == "turn-send")
        #expect(conversation.turns.first?.status == .completed)
        #expect(item.text == "Done")
        #expect(item.turnID == "turn-send")
        #expect(conversation.transcript.finalAnswer == "Done")
    }

    @Test("send scopes generated transcript item IDs by turn")
    func sendScopesGeneratedTranscriptItemsByTurn() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-send"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-1", status: "running")
        try await runtime.transport.enqueueTurnStart(turnID: "turn-2", status: "running")

        let conversation = try await CodexConversation.resume("thread-send", server: runtime.server)
        let firstSend = Task {
            try await conversation.send("first")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", delta: "First")
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        _ = try await firstSend.value

        let firstItem = try #require(conversation.items.first)
        let secondSend = Task {
            try await conversation.send("second")
        }

        await runtime.transport.waitForRequest(method: "turn/start", count: 2)
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-2", delta: "Second")
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-2", status: "completed"))
        )
        _ = try await secondSend.value

        #expect(conversation.items.count == 2)
        #expect(conversation.items[0] === firstItem)
        #expect(conversation.items[0].id == "agent-message-delta")
        #expect(conversation.items[0].turnID == "turn-1")
        #expect(conversation.items[0].text == "First")
        #expect(conversation.items[1].id == "agent-message-delta")
        #expect(conversation.items[1].turnID == "turn-2")
        #expect(conversation.items[1].text == "Second")
        #expect(conversation.transcript.messages.map(\.text) == ["First", "Second"])
    }

    @Test("send preserves failed response transcript before rethrowing")
    func sendPreservesFailedResponseTranscript() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-failed"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-failed", status: "running")

        let conversation = try await CodexConversation.resume("thread-failed", server: runtime.server)
        let sendTask = Task {
            try await conversation.send("fail")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-failed", delta: "Partial failure")
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-failed", status: "failed"))
        )

        do {
            _ = try await sendTask.value
            Issue.record("Expected a failed turn to throw.")
        } catch let error as CodexAppServerError {
            #expect(error.response?.turnID == "turn-failed")
        }

        let turn = try #require(conversation.turns.first)
        let item = try #require(conversation.items.first)
        #expect(turn.id == "turn-failed")
        #expect(turn.status == .failed)
        #expect(item.turnID == "turn-failed")
        #expect(item.text == "Partial failure")
        #expect(conversation.transcript.finalAnswer == "Partial failure")
    }

    @Test("send skips failed response transcript after rollback policy")
    func sendSkipsFailedResponseTranscriptAfterRollbackPolicy() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-revert"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-revert", status: "running")
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")

        let conversation = try await CodexConversation.resume("thread-revert", server: runtime.server)
        let sendTask = Task {
            try await conversation.send(
                "fail",
                options: .init(transcriptErrorHandlingPolicy: .revertTranscript)
            )
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-revert", delta: "Rolled back")
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-revert", status: "failed"))
        )

        do {
            _ = try await sendTask.value
            Issue.record("Expected a failed turn to throw.")
        } catch let error as CodexAppServerError {
            #expect(error.response?.turnID == "turn-revert")
        }

        #expect(conversation.turns.isEmpty)
        #expect(conversation.items.isEmpty)
        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/rollback"))
    }
}

private struct TurnCompletedParams: Encodable, Sendable {
    var turn: Turn

    struct Turn: Encodable, Sendable {
        var id: String
        var status: String?
    }
}

private struct TurnDeltaParams: Encodable, Sendable {
    var turnID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
        case delta
    }
}

private struct ThreadReadParams: Decodable, Sendable {
    var threadID: String
    var includeTurns: Bool

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case includeTurns
    }
}

private struct ThreadListParams: Decodable, Sendable {
    var cursor: String?
    var limit: Int?
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
    }
}
