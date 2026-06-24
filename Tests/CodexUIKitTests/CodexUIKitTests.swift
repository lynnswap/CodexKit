import CodexAppServerKit
import CodexAppServerKitTesting
import CodexUIKit
import Foundation
import Testing

@MainActor
struct CodexThreadLibraryTests {
    @Test("thread/list refresh preserves item identity across updates")
    func threadListRefreshPreservesThreadItemIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadList(
            CodexThreadPage(
                threads: [
                    .init(
                        id: "thread-1",
                        name: "Thread One"
                    )
                ],
                nextCursor: "next",
                backwardsCursor: "prev"
            )
        )

        let library = CodexThreadLibrary(
            server: runtime.server,
            configuration: .init(query: .init(), sectionTitle: "Threads")
        )
        await library.refresh()

        let section = try #require(library.sections.first)
        let first = try #require(section.items.first)
        #expect(first.title == "Thread One")
        #expect(library.nextCursor == "next")

        try await runtime.transport.enqueueThreadList(
            CodexThreadPage(
                threads: [
                    .init(
                        id: "thread-2",
                        name: "Thread Two"
                    ),
                    .init(
                        id: "thread-1",
                        name: "Thread One Updated"
                    ),
                ],
                nextCursor: nil,
                backwardsCursor: "prev2"
            )
        )
        await library.loadNextPage()

        #expect(section.items.count == 2)
        #expect(section.items[0].id == "thread-2")
        #expect(section.items[1] === first)
        #expect(section.items[1].title == "Thread One Updated")
        #expect(section.items[1].id == "thread-1")
        #expect(library.nextCursor == nil)
        #expect(library.backwardsCursor == "prev2")

        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/list" }.count == 2)
    }

    @Test("thread actions call lifecycle APIs")
    func threadActionsCallExpectedMethods() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let library = CodexThreadLibrary(server: runtime.server)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-created", model: "gpt-5")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-selected"))
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-created"))
        try await runtime.transport.enqueueThreadUnarchive(.init(id: "thread-selected"))
        try await runtime.transport.enqueueEmpty(for: "thread/delete")

        _ = try await library.startThread(in: URL(fileURLWithPath: "/tmp/project"))

        #expect(library.selectedThreadID == "thread-created")

        library.selectThread("thread-selected")
        _ = try await library.resumeSelectedThread()
        try await library.archive("thread-created")
        try await library.unarchive("thread-selected")
        try await library.delete("thread-selected")

        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/start"))
        #expect(methods.filter { $0 == "thread/resume" }.count == 2)
        #expect(methods.contains("thread/archive"))
        #expect(methods.contains("thread/unarchive"))
        #expect(methods.contains("thread/delete"))
    }
}

@MainActor
struct CodexConversationTests {
    @Test("conversation refresh uses thread/read")
    func conversationRefreshReadsThreadState() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(
            .init(
                id: "conversation-thread",
                name: "Conversation thread",
                turns: [
                    .init(id: "turn-1", status: .running),
                ]
            )
        )
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: "conversation-thread",
                name: "Conversation thread",
                preview: "Ready for review",
                turns: [
                    .init(id: "turn-1", status: .completed),
                ]
            )
        )

        let conversation = try await CodexConversation.resume(
            "conversation-thread",
            server: runtime.server
        )

        try await conversation.refresh()

        #expect(conversation.snapshot.name == "Conversation thread")
        #expect(conversation.snapshot.turns.count == 1)
        #expect(conversation.phase == .loaded)

        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/resume"))
        #expect(methods.contains("thread/read"))
    }

    @Test("conversation send completes after turn completion")
    func conversationSendCompletesWithTurnCompletionNotification() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "conversation-send-thread"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-send", status: "running")

        let conversation = try await CodexConversation.resume(
            "conversation-send-thread",
            server: runtime.server
        )

        let sendTask = Task {
            try await conversation.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: [
                "turn": [
                    "id": "turn-send",
                    "status": "completed",
                ],
            ]
        )

        let response = try await sendTask.value
        #expect(response.turnID == "turn-send")
        #expect(conversation.phase == .loaded)

        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.contains("turn/start"))
    }
}

@MainActor
struct CodexAccountStatusTests {
    @Test("account refresh reads account, config and rate limits")
    func accountRefreshReadsThreeEndpoints() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueAccount(
            .init(id: "acct", kind: .chatGPT, label: "ChatGPT")
        )
        try await runtime.transport.enqueueRateLimits(
            .init(
                planType: "plus",
                windows: [
                    .init(windowDurationMinutes: 300, usedPercent: 10)
                ]
            )
        )
        try await runtime.transport.enqueueConfiguration(
            .init(model: "gpt-5", serviceTier: "plus")
        )

        let status = CodexAccountStatus(server: runtime.server)
        await status.refresh()

        #expect(status.phase == .loaded)
        #expect(status.account?.id == "chatgpt")
        #expect(status.configuration.model == "gpt-5")
        #expect(status.rateLimits.planType == "plus")

        let methods = await runtime.transport.recordedRequests().map(\.method)
        #expect(methods.contains("account/read"))
        #expect(methods.contains("account/rateLimits/read"))
        #expect(methods.contains("config/read"))
    }
}
