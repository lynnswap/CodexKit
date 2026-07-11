import Testing

@testable import CodexAppServerKit
import CodexAppServerKitTesting

@Suite("Turn replay router integration")
struct TurnReplayRouterTests {
    @Test func duplicateExplicitThreadTerminalsPublishOnce() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        let completed = TurnCompletedParams(
            threadID: "thread-1",
            turn: .init(id: "turn-external", status: "completed")
        )
        let events = harness.router.events(for: "thread-1")
        var eventIterator = events.makeAsyncIterator()

        try await transport.emitServerNotification(method: "turn/completed", params: completed)
        try await transport.emitServerNotification(method: "turn/completed", params: completed)
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-1")
        )

        var terminals: [CodexTurnOutcome] = []
        while let event = try await eventIterator.next() {
            if case .terminal(let outcome) = event {
                terminals.append(outcome)
            }
        }
        await harness.close()
        #expect(terminals == [.completed(.init(turnID: "turn-external"))])
    }

    @Test func conflictingExplicitThreadTerminalClosesConnectionWithContractViolation() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-1",
                turn: .init(id: "turn-external", status: "completed")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-1",
                turn: .init(id: "turn-external", status: "interrupted")
            )
        )

        let termination = await harness.supervisor.waitForTerminationForTesting()
        guard case .transportFailure(.contractViolation(let message)) = termination else {
            Issue.record("Expected a typed thread-terminal contract violation, got \(termination).")
            return
        }
        #expect(message.contains("turn-external"))
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

private struct ThreadClosedParams: Encodable, Sendable {
    var threadID: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct TurnItem: Encodable, Sendable {}
