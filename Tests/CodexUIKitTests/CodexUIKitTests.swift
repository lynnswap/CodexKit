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
}

private struct TurnCompletedParams: Encodable, Sendable {
    var turn: Turn

    struct Turn: Encodable, Sendable {
        var id: String
        var status: String?
    }
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
