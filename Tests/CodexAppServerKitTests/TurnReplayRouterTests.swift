import Testing

@testable import CodexAppServerKit
import CodexAppServerKitTesting

@Suite("Turn replay router integration")
struct TurnReplayRouterTests {
    @Test func duplicateAndConflictingExplicitThreadTerminalsPublishOnce() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        let completed = TurnCompletedParams(
            threadID: "thread-1",
            turn: .init(id: "turn-external", status: "completed")
        )
        let events = await harness.router.liveEvents(for: "thread-1")
        var eventIterator = events.makeAsyncIterator()

        try await transport.emitServerNotification(method: "turn/completed", params: completed)
        try await transport.emitServerNotification(method: "turn/completed", params: completed)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-1",
                turn: .init(id: "turn-external", status: "interrupted")
            )
        )

        guard case .terminal(let outcome)? = try await eventIterator.next() else {
            Issue.record("Expected the first explicit-thread terminal on its thread stream.")
            await harness.close()
            return
        }
        let eventCount = await harness.router.threadEventGenerationCursor("thread-1")
        await harness.close()
        #expect(outcome.response.turnID == "turn-external")
        #expect(outcome == .completed(.init(turnID: "turn-external")))
        #expect(eventCount == 1)
    }

    @Test func resumedReviewCapturesTerminalBeforeResumeResponse() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let gate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        await runtime.transport.holdNext(method: "thread/resume", gate: gate)
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        let resume = Task {
            try await runtime.server.resumeReview(identity)
        }

        await runtime.transport.waitForRequest(method: "thread/resume")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-review",
                turn: .init(id: "turn-review", status: "completed")
            )
        )
        await gate.open()

        let review = try await resume.value
        let outcome = try await review.collect(timeout: .seconds(1))
        #expect(outcome == .completed(.init(turnID: "turn-review")))
    }
}

private struct TurnCompletedParams: Encodable, Sendable {
    var threadID: String
    var turn: TurnPayload

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

private struct TurnPayload: Encodable, Sendable {
    var id: String
    var status: String
    var items: [TurnItem] = []
}

private struct TurnItem: Encodable, Sendable {}
