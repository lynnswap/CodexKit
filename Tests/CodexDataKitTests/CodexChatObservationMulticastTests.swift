import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Foundation
import Testing

@MainActor
struct CodexChatObservationMulticastTests {
    @Test("observation updates multicast to multiple consumers")
    func observationUpdatesMulticastToMultipleConsumers() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-multicast"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-multicast",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-multicast"))
        let observation = try await chat.observe()
        let secondObservation = try await chat.observe()
        defer {
            observation.cancel()
            secondObservation.cancel()
        }
        let firstRecorder = ObservationUpdateRecorder(stream: observation.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: secondObservation.updates)
        await firstRecorder.waitUntilStarted()
        await secondRecorder.waitUntilStarted()

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ObservationTestThreadItemParams(
                threadID: "thread-multicast",
                turnID: "turn-multicast",
                item: .init(
                    id: "message-multicast",
                    type: "agentMessage",
                    text: "Multicast update"
                )
            )
        )

        #expect(await firstRecorder.itemInserted(id: "message-multicast") != nil)
        #expect(await secondRecorder.itemInserted(id: "message-multicast") != nil)
    }

    @Test("observed chat advances without update consumers")
    func observedChatAdvancesWithoutUpdateConsumers() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-no-consumer"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-no-consumer",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-no-consumer"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ObservationTestThreadItemParams(
                threadID: "thread-no-consumer",
                turnID: "turn-no-consumer",
                item: .init(
                    id: "message-no-consumer",
                    type: "agentMessage",
                    text: "Pump-owned mutation"
                )
            )
        )

        #expect(await observationEventually {
            chat.items.map(\.itemID) == ["message-no-consumer"]
                && chat.items.map(\.text) == ["Pump-owned mutation"]
        })
    }

    @Test("multiple update consumers do not duplicate model mutation")
    func multipleUpdateConsumersDoNotDuplicateModelMutation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-no-duplicate"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-no-duplicate",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-no-duplicate"))
        let observation = try await chat.observe()
        let secondObservation = try await chat.observe()
        defer {
            observation.cancel()
            secondObservation.cancel()
        }
        let firstRecorder = ObservationUpdateRecorder(stream: observation.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: secondObservation.updates)
        await firstRecorder.waitUntilStarted()
        await secondRecorder.waitUntilStarted()

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ObservationTestThreadItemParams(
                threadID: "thread-no-duplicate",
                turnID: "turn-no-duplicate",
                item: .init(
                    id: "message-no-duplicate",
                    type: "agentMessage",
                    text: "One model item"
                )
            )
        )

        #expect(await firstRecorder.itemInserted(id: "message-no-duplicate") != nil)
        #expect(await secondRecorder.itemInserted(id: "message-no-duplicate") != nil)
        #expect(chat.items.map(\.itemID) == ["message-no-duplicate"])
    }

    @Test("observation update relay finishes all consumers")
    func observationUpdateRelayFinishesAllConsumers() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-finish-multicast"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-finish-multicast",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-finish-multicast"))
        let observation = try await chat.observe()
        let secondObservation = try await chat.observe()
        defer {
            observation.cancel()
            secondObservation.cancel()
        }
        let firstRecorder = ObservationUpdateRecorder(stream: observation.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: secondObservation.updates)
        await firstRecorder.waitUntilStarted()
        await secondRecorder.waitUntilStarted()

        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ObservationTestThreadClosedParams(threadID: "thread-finish-multicast")
        )

        #expect(await firstRecorder.waitUntilFinished())
        #expect(await secondRecorder.waitUntilFinished())
    }

    @Test("non-last close releases one lease and last close joins the pump")
    func observationCloseHonorsLeaseOwnership() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-close-leases"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-close-leases",
            status: .idle,
            turns: []
        ))
        let chat = context.model(for: CodexThreadID(rawValue: "thread-close-leases"))
        let first = try await chat.observe()
        let second = try await chat.observe()
        let firstRecorder = ObservationUpdateRecorder(stream: first.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: second.updates)
        await firstRecorder.waitUntilStarted()
        await secondRecorder.waitUntilStarted()

        await first.close()
        #expect(await firstRecorder.waitUntilFinished())
        #expect(await secondRecorder.waitUntilFinished(attempts: 1) == false)

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ObservationTestThreadItemParams(
                threadID: "thread-close-leases",
                turnID: "turn-close-leases",
                item: .init(id: "message-after-close", type: "agentMessage", text: "still live")
            )
        )
        #expect(await secondRecorder.itemInserted(id: "message-after-close") != nil)

        await second.close()
        #expect(await secondRecorder.waitUntilFinished())

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-close-leases"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-close-leases",
            status: .idle,
            turns: []
        ))
        let restarted = try await chat.observe()
        var restartedEvents = restarted.updates.makeAsyncIterator()
        let initial = try #require(await restartedEvents.next())
        #expect(initial.generation == 2)
        guard case .snapshot(_, let reason) = initial.payload else {
            Issue.record("Expected restarted generation snapshot")
            return
        }
        #expect(reason == .generationRestart)
        await restarted.close()
    }

    @Test("failure before first render yields one complete failure snapshot then finishes")
    func setupFailureYieldsSnapshotThenFinishes() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "offline",
            for: "thread/resume"
        )
        let chat = context.model(for: CodexThreadID(rawValue: "thread-setup-failure"))

        let observation = try await chat.observe()
        var events = observation.updates.makeAsyncIterator()
        let failureEvent = try #require(await events.next())
        guard case .snapshot(let snapshot, let reason) = failureEvent.payload else {
            Issue.record("Expected failure snapshot")
            return
        }
        #expect(reason == .upstreamFailure)
        guard case .failed(.appServer) = snapshot.phase else {
            Issue.record("Expected typed app-server failure phase")
            return
        }
        #expect(await events.next() == nil)
        await observation.close()
    }

    @Test("iterator cancellation releases its lease before a new generation starts")
    func iteratorCancellationReleasesLease() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-iterator-cancel"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-iterator-cancel",
            status: .idle,
            turns: []
        ))
        let chat = context.model(for: CodexThreadID(rawValue: "thread-iterator-cancel"))
        let observation = try await chat.observe()
        let consumer = Task { @MainActor in
            for await _ in observation.updates {}
        }
        await Task.yield()
        consumer.cancel()
        await consumer.value
        await observation.close()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-iterator-cancel"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-iterator-cancel",
            status: .idle,
            turns: []
        ))
        let restarted = try await chat.observe()
        var events = restarted.updates.makeAsyncIterator()
        let initial = try #require(await events.next())
        #expect(initial.generation == 2)
        guard case .snapshot(_, let reason) = initial.payload else {
            Issue.record("Expected generation restart snapshot")
            return
        }
        #expect(reason == .generationRestart)
        await restarted.close()
    }
}

private struct ObservationTestThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var startedAtMs: Int64 = 0
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case startedAtMs
        case item
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String
    }
}

private struct ObservationTestThreadClosedParams: Encodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

@MainActor
private func observationEventually(
    attempts: Int = 50,
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
private final class ObservationUpdateRecorder {
    private var changes: [CodexChatUpdate] = []
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var isStarted = false
    private var isFinished = false
    private var task: Task<Void, Never>?

    init(stream: CodexChatUpdates) {
        task = Task { @MainActor [weak self] in
            self?.markStarted()
            for await event in stream {
                if case .update(let change) = event.payload {
                    self?.append(change)
                }
            }
            self?.markFinished()
        }
    }

    deinit {
        task?.cancel()
    }

    func waitUntilStarted() async {
        if isStarted {
            return
        }
        await withCheckedContinuation { continuation in
            if isStarted {
                continuation.resume()
            } else {
                startedContinuations.append(continuation)
            }
        }
    }

    func itemInserted(id: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemInserted(let item, _, _) = change {
                return item.id == id
            }
            if case .turnInserted(let turn, _) = change {
                return turn.items.contains { $0.id == id }
            }
            return false
        }
    }

    func waitUntilFinished(attempts: Int = 50) async -> Bool {
        if isFinished {
            return true
        }
        for _ in 0..<attempts {
            if isFinished {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isFinished
    }

    private func append(_ change: CodexChatUpdate) {
        changes.append(change)
    }

    private func markStarted() {
        guard isStarted == false else {
            return
        }
        isStarted = true
        let continuations = startedContinuations
        startedContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func markFinished() {
        guard isFinished == false else {
            return
        }
        isFinished = true
    }

    private func popFirst(
        matching predicate: (CodexChatUpdate) -> Bool
    ) -> CodexChatUpdate? {
        guard let index = changes.firstIndex(where: predicate) else {
            return nil
        }
        return changes.remove(at: index)
    }

    private func next(
        matching predicate: (CodexChatUpdate) -> Bool
    ) async -> CodexChatUpdate? {
        for _ in 0..<50 {
            if let change = popFirst(matching: predicate) {
                return change
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return popFirst(matching: predicate)
    }
}
