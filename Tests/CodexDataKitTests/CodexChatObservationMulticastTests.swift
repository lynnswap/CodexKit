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
        defer {
            observation.cancel()
        }
        let firstRecorder = ObservationUpdateRecorder(stream: observation.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: observation.updates)
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
        defer {
            observation.cancel()
        }
        let firstRecorder = ObservationUpdateRecorder(stream: observation.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: observation.updates)
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
        defer {
            observation.cancel()
        }
        let firstRecorder = ObservationUpdateRecorder(stream: observation.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: observation.updates)
        await firstRecorder.waitUntilStarted()
        await secondRecorder.waitUntilStarted()

        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ObservationTestThreadClosedParams(threadID: "thread-finish-multicast")
        )

        #expect(await firstRecorder.waitUntilFinished())
        #expect(await secondRecorder.waitUntilFinished())
    }
}

private struct ObservationTestThreadItemParams: Encodable, Sendable {
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
            for await change in stream {
                self?.append(change)
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
            if case .itemInserted(let changeID, _) = change {
                return changeID == id
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
