import Foundation

package actor TurnGenerationHandleState {
    package enum Snapshot: Equatable, Sendable {
        case live
        case terminal(CompactTurnSnapshot)
        case terminated(CodexConnectionTermination)
    }

    package enum TransitionDisposition: Equatable, Sendable {
        case transitioned
        case duplicate
        case late
    }

    private enum Phase {
        case live(AppServerConnectionLease)
        case terminal(CompactTurnSnapshot)
        case terminated(CodexConnectionTermination)
    }

    private var phase: Phase

    package init(connectionLease: AppServerConnectionLease) {
        self.phase = .live(connectionLease)
    }

    package func snapshot() -> Snapshot {
        switch phase {
        case .live:
            .live
        case .terminal(let compactSnapshot):
            .terminal(compactSnapshot)
        case .terminated(let termination):
            .terminated(termination)
        }
    }

    @discardableResult
    package func transitionToTerminal(
        _ compactSnapshot: CompactTurnSnapshot
    ) -> TransitionDisposition {
        switch phase {
        case .live:
            phase = .terminal(compactSnapshot)
            return .transitioned
        case .terminal(let existing):
            precondition(
                existing == compactSnapshot,
                "A turn generation cannot replace its terminal snapshot."
            )
            return .duplicate
        case .terminated:
            return .late
        }
    }

    @discardableResult
    package func transitionToTerminated(
        _ termination: CodexConnectionTermination
    ) -> TransitionDisposition {
        switch phase {
        case .live:
            phase = .terminated(termination)
            return .transitioned
        case .terminal:
            return .late
        case .terminated(let existing):
            precondition(
                existing == termination,
                "A turn generation cannot replace its connection termination."
            )
            return .duplicate
        }
    }

    package func cachedOutcome() throws -> CodexTurnOutcome? {
        switch phase {
        case .live:
            nil
        case .terminal(let compactSnapshot):
            compactSnapshot.outcome
        case .terminated(let termination):
            throw CodexAppServerError.connectionTerminated(termination)
        }
    }

    package func terminalEvents() throws -> TurnReplayEvents? {
        switch phase {
        case .live:
            nil
        case .terminal(let compactSnapshot):
            .replaying(compactSnapshot)
        case .terminated(let termination):
            .failing(.connectionTerminated(termination))
        }
    }

    package func terminalProgressEvents() throws -> TurnReplayProgressEvents? {
        switch phase {
        case .live:
            nil
        case .terminal(let compactSnapshot):
            .replaying(compactSnapshot)
        case .terminated(let termination):
            .failing(.connectionTerminated(termination))
        }
    }

    package func closeConnection() async {
        guard case .live(let connectionLease) = phase else {
            return
        }
        await connectionLease.closeConnection()
    }
}

package actor TurnReplayStore {
    package enum PendingCancellationDisposition: Equatable, Sendable {
        case removedBeforeWrite
        case retainedAfterWrite
        case notRegistered
    }

    package struct Snapshot: Equatable, Sendable {
        package var pendingOperationCount: Int
        package var postWritePendingOperationCount: Int
        package var activeGenerationCount: Int
        package var orphanGenerationCount: Int
        package var terminalOrphanCount: Int
        package var weakStateRegistrationCount: Int
        package var termination: CodexConnectionTermination?
    }

    private enum StorePhase {
        case open
        case terminating(CodexConnectionTermination)
        case terminated(CodexConnectionTermination)
    }

    private enum PendingPhase {
        case beforeWrite
        case afterWrite
    }

    private struct PendingOperation {
        var kind: TurnReplayPendingOperationKind
        var phase: PendingPhase
        var state: WeakTurnGenerationHandleState
    }

    private final class Generation {
        enum Phase {
            case active
            case terminalPendingBind(CompactTurnSnapshot)
            case finalizing(CompactTurnSnapshot)
            case terminating(CodexConnectionTermination)
        }

        let turnID: CodexTurnID
        var operationKind: TurnReplayPendingOperationKind?
        var phase = Phase.active
        var accumulator: TurnReplayAccumulator
        let relay = TurnReplayRelay()
        var state: WeakTurnGenerationHandleState?

        init(turnID: CodexTurnID) {
            self.turnID = turnID
            self.accumulator = TurnReplayAccumulator(turnID: turnID)
        }

        func register(_ state: TurnGenerationHandleState) {
            if let existing = self.state?.value {
                precondition(
                    existing === state,
                    "Every handle copy for a generation must share one state identity."
                )
                return
            }
            self.state = .init(state)
        }

        func liveState() -> TurnGenerationHandleState? {
            state?.value
        }
    }

    private var phase = StorePhase.open
    private var pendingOperations: [TurnReplayPendingToken: PendingOperation] = [:]
    private var generations: [CodexTurnID: Generation] = [:]
    private var orphanGenerations: [CodexTurnID: Generation] = [:]
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func registerPendingOperation(
        kind: TurnReplayPendingOperationKind,
        state: TurnGenerationHandleState
    ) -> TurnReplayPendingToken {
        requireOpen()
        let token = TurnReplayPendingToken()
        pendingOperations[token] = .init(
            kind: kind,
            phase: .beforeWrite,
            state: .init(state)
        )
        return token
    }

    package func markWriteAccepted(_ token: TurnReplayPendingToken) {
        requireOpen()
        guard var operation = pendingOperations[token] else {
            preconditionFailure("A write-accepted turn operation must still be registered.")
        }
        guard case .beforeWrite = operation.phase else {
            preconditionFailure("A turn operation write may be accepted exactly once.")
        }
        precondition(
            operation.state.value != nil,
            "The structured request scope must retain generation state after write acceptance."
        )
        operation.phase = .afterWrite
        pendingOperations[token] = operation
    }

    @discardableResult
    package func cancelPendingOperation(
        _ token: TurnReplayPendingToken
    ) -> PendingCancellationDisposition {
        requireOpen()
        guard let operation = pendingOperations[token] else {
            return .notRegistered
        }
        switch operation.phase {
        case .beforeWrite:
            pendingOperations.removeValue(forKey: token)
            return .removedBeforeWrite
        case .afterWrite:
            return .retainedAfterWrite
        }
    }

    package func bind(
        _ token: TurnReplayPendingToken,
        to turnID: CodexTurnID,
        initialSnapshot: CodexTurnSnapshot
    ) async {
        requireOpen()
        precondition(
            initialSnapshot.id == turnID,
            "A generation binding snapshot must identify its bound turn."
        )
        guard let operation = pendingOperations[token] else {
            preconditionFailure("A turn generation may bind only from a pending operation.")
        }
        guard case .afterWrite = operation.phase else {
            preconditionFailure("A turn generation cannot bind before its request write.")
        }
        guard let state = operation.state.value else {
            preconditionFailure(
                "The structured request scope released generation state before binding."
            )
        }
        precondition(
            generations[turnID] == nil,
            "A turn generation identity may be bound exactly once."
        )

        pendingOperations.removeValue(forKey: token)
        if let orphan = orphanGenerations[turnID] {
            orphan.operationKind = operation.kind
            orphan.register(state)
            switch orphan.phase {
            case .active:
                orphan.accumulator.seed(initialSnapshot)
                orphanGenerations.removeValue(forKey: turnID)
                generations[turnID] = orphan
            case .terminalPendingBind(let compactSnapshot):
                _ = await state.transitionToTerminal(compactSnapshot)
                if orphanGenerations[turnID] === orphan {
                    orphanGenerations.removeValue(forKey: turnID)
                } else if case .open = phase {
                    preconditionFailure("A terminal orphan changed identity during handoff.")
                }
            case .finalizing:
                preconditionFailure("An unbound generation cannot already be finalizing.")
            case .terminating:
                preconditionFailure("A terminating store cannot bind an orphan generation.")
            }
            return
        }

        let remainingPostWriteCount = pendingOperations.values.reduce(into: 0) {
            count, pending in
            if case .afterWrite = pending.phase {
                count += 1
            }
        }
        precondition(
            orphanGenerations.count <= remainingPostWriteCount,
            "A bound response identity cannot strand an early orphan generation."
        )

        let generation = Generation(turnID: turnID)
        generation.operationKind = operation.kind
        generation.accumulator.seed(initialSnapshot)
        generation.register(state)
        generations[turnID] = generation
    }

    package func register(
        _ state: TurnGenerationHandleState,
        for turnID: CodexTurnID
    ) {
        requireOpen()
        guard let generation = generations[turnID] else {
            preconditionFailure("A live handle may register only to a bound generation.")
        }
        guard case .active = generation.phase else {
            preconditionFailure("A finalizing generation cannot accept a live handle.")
        }
        generation.register(state)
    }

    package func events(
        for turnID: CodexTurnID,
        state: TurnGenerationHandleState
    ) async throws -> TurnReplayEvents {
        if let generation = generations[turnID] {
            switch generation.phase {
            case .active:
                generation.register(state)
                return generation.relay.events(
                    initialSnapshot: generation.accumulator.snapshot
                )
            case .finalizing(let compactSnapshot):
                return .replaying(compactSnapshot)
            case .terminating(let termination):
                return .failing(.connectionTerminated(termination))
            case .terminalPendingBind:
                preconditionFailure("A bound generation cannot be pending its initial bind.")
            }
        }
        return try await terminalEventsAfterFinalization(for: turnID, state: state)
    }

    package func progressEvents(
        for turnID: CodexTurnID,
        state: TurnGenerationHandleState
    ) async throws -> TurnReplayProgressEvents {
        if let generation = generations[turnID] {
            switch generation.phase {
            case .active:
                generation.register(state)
                return generation.relay.progressEvents(
                    initialProgress: generation.accumulator.progress
                )
            case .finalizing(let compactSnapshot):
                return .replaying(compactSnapshot)
            case .terminating(let termination):
                return .failing(.connectionTerminated(termination))
            case .terminalPendingBind:
                preconditionFailure("A bound generation cannot be pending its initial bind.")
            }
        }
        return try await terminalProgressEventsAfterFinalization(
            for: turnID,
            state: state
        )
    }

    @discardableResult
    package func yield(
        _ event: CodexTurnEvent,
        for turnID: CodexTurnID
    ) -> Int {
        requireOpen()
        if case .terminal = event {
            preconditionFailure("Turn replay terminal delivery must use finish(_:).")
        }
        let generation = generationForRouting(turnID)
        guard case .active = generation.phase else {
            preconditionFailure("A terminal generation cannot accept another event.")
        }
        generation.accumulator.apply(event)
        let overflowCount = generation.relay.yield(
            event,
            accumulatedSnapshot: generation.accumulator.snapshot
        )
        generation.relay.yieldProgress(generation.accumulator.progress)
        return overflowCount
    }

    package func finish(_ outcome: CodexTurnOutcome) async {
        requireOpen()
        let turnID = outcome.response.turnID
        let generation = generationForRouting(turnID)
        switch generation.phase {
        case .active:
            break
        case .terminalPendingBind(let existing), .finalizing(let existing):
            let duplicate = generation.accumulator.compact(outcome)
            precondition(existing == duplicate, "A turn generation terminal cannot be replaced.")
            return
        case .terminating:
            preconditionFailure("A terminating generation cannot accept a terminal outcome.")
        }

        let compactSnapshot = generation.accumulator.compact(outcome)
        if orphanGenerations[turnID] === generation {
            generation.phase = .terminalPendingBind(compactSnapshot)
            generation.relay.finish(with: compactSnapshot)
            return
        }

        generation.phase = .finalizing(compactSnapshot)
        generation.relay.finish(with: compactSnapshot)
        if let state = generation.liveState() {
            _ = await state.transitionToTerminal(compactSnapshot)
        }
        if generations[turnID] === generation {
            generations.removeValue(forKey: turnID)
        } else if case .open = phase {
            preconditionFailure("A finalizing turn generation changed identity.")
        }
    }

    package func terminateAll(with termination: CodexConnectionTermination) async {
        switch phase {
        case .open:
            phase = .terminating(termination)
        case .terminating(let existing):
            precondition(existing == termination, "Turn replay termination cannot be replaced.")
            await withCheckedContinuation { continuation in
                terminationWaiters.append(continuation)
            }
            return
        case .terminated(let existing):
            precondition(existing == termination, "Turn replay termination cannot be replaced.")
            return
        }

        var statesToTerminate: [ObjectIdentifier: TurnGenerationHandleState] = [:]
        var terminalTransitions: [
            ObjectIdentifier: (TurnGenerationHandleState, CompactTurnSnapshot)
        ] = [:]
        for operation in pendingOperations.values {
            if let state = operation.state.value {
                statesToTerminate[ObjectIdentifier(state)] = state
            }
        }
        for generation in generations.values {
            switch generation.phase {
            case .active:
                generation.phase = .terminating(termination)
                generation.relay.finish(throwing: .connectionTerminated(termination))
                if let state = generation.liveState() {
                    statesToTerminate[ObjectIdentifier(state)] = state
                }
            case .finalizing(let compactSnapshot):
                if let state = generation.liveState() {
                    terminalTransitions[ObjectIdentifier(state)] = (state, compactSnapshot)
                }
            case .terminating(let existing):
                precondition(existing == termination)
            case .terminalPendingBind:
                preconditionFailure("A bound generation cannot be pending bind.")
            }
        }
        for generation in orphanGenerations.values {
            switch generation.phase {
            case .active:
                generation.phase = .terminating(termination)
                generation.relay.finish(throwing: .connectionTerminated(termination))
                if let state = generation.liveState() {
                    statesToTerminate[ObjectIdentifier(state)] = state
                }
            case .terminalPendingBind(let compactSnapshot):
                if let state = generation.liveState() {
                    terminalTransitions[ObjectIdentifier(state)] = (state, compactSnapshot)
                }
            case .terminating(let existing):
                precondition(existing == termination)
            case .finalizing:
                preconditionFailure("An orphan generation cannot be finalizing.")
            }
        }

        for (id, transition) in terminalTransitions {
            statesToTerminate.removeValue(forKey: id)
            _ = await transition.0.transitionToTerminal(transition.1)
        }
        for state in statesToTerminate.values {
            _ = await state.transitionToTerminated(termination)
        }
        pendingOperations.removeAll(keepingCapacity: false)
        generations.removeAll(keepingCapacity: false)
        orphanGenerations.removeAll(keepingCapacity: false)
        phase = .terminated(termination)
        let waiters = terminationWaiters
        terminationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    package func snapshotForTesting() -> Snapshot {
        let postWriteCount = pendingOperations.values.reduce(into: 0) { count, operation in
            if case .afterWrite = operation.phase {
                count += 1
            }
        }
        let weakStateCount = generations.values.reduce(into: 0) { count, generation in
            if generation.state?.value != nil {
                count += 1
            }
        }
        let terminalOrphanCount = orphanGenerations.values.reduce(into: 0) {
            count, generation in
            if case .terminalPendingBind = generation.phase {
                count += 1
            }
        }
        let termination: CodexConnectionTermination?
        switch phase {
        case .open:
            termination = nil
        case .terminating(let reason), .terminated(let reason):
            termination = reason
        }
        return .init(
            pendingOperationCount: pendingOperations.count,
            postWritePendingOperationCount: postWriteCount,
            activeGenerationCount: generations.count,
            orphanGenerationCount: orphanGenerations.count,
            terminalOrphanCount: terminalOrphanCount,
            weakStateRegistrationCount: weakStateCount,
            termination: termination
        )
    }

    private func generationForRouting(_ turnID: CodexTurnID) -> Generation {
        if let generation = generations[turnID] ?? orphanGenerations[turnID] {
            return generation
        }
        let unboundPostWriteCount = pendingOperations.values.reduce(into: 0) {
            count, operation in
            guard case .afterWrite = operation.phase else {
                return
            }
            precondition(
                operation.state.value != nil,
                "Post-write generation state must remain alive until binding or termination."
            )
            count += 1
        }
        precondition(
            orphanGenerations.count < unboundPostWriteCount,
            "An unbound early turn generation must correspond to a post-write pending operation."
        )
        let generation = Generation(turnID: turnID)
        orphanGenerations[turnID] = generation
        return generation
    }

    private func terminalEventsAfterFinalization(
        for turnID: CodexTurnID,
        state: TurnGenerationHandleState
    ) async throws -> TurnReplayEvents {
        if let terminalEvents = try await state.terminalEvents() {
            return terminalEvents
        }
        if let generation = generations[turnID] {
            guard case .active = generation.phase else {
                preconditionFailure("Generation finalization did not publish handle state.")
            }
            generation.register(state)
            return generation.relay.events(
                initialSnapshot: generation.accumulator.snapshot
            )
        }
        preconditionFailure("A live handle has no active turn replay generation.")
    }

    private func terminalProgressEventsAfterFinalization(
        for turnID: CodexTurnID,
        state: TurnGenerationHandleState
    ) async throws -> TurnReplayProgressEvents {
        if let terminalEvents = try await state.terminalProgressEvents() {
            return terminalEvents
        }
        if let generation = generations[turnID] {
            guard case .active = generation.phase else {
                preconditionFailure("Generation finalization did not publish handle state.")
            }
            generation.register(state)
            return generation.relay.progressEvents(
                initialProgress: generation.accumulator.progress
            )
        }
        preconditionFailure("A live handle has no active turn replay generation.")
    }

    private func requireOpen() {
        guard case .open = phase else {
            preconditionFailure("A terminated turn replay store cannot accept new work.")
        }
    }
}

private final class WeakTurnGenerationHandleState {
    weak var value: TurnGenerationHandleState?

    init(_ value: TurnGenerationHandleState) {
        self.value = value
    }
}

private struct TurnReplayAccumulator {
    private(set) var snapshot: CodexTurnSnapshot
    private(set) var usage: CodexTokenUsage?
    private var hasRoutedEvent = false

    init(turnID: CodexTurnID) {
        self.snapshot = .init(id: turnID, state: .inProgress)
    }

    var progress: CodexReviewProgress {
        .running(transcript: .init(items: snapshot.items), usage: usage)
    }

    mutating func seed(_ initialSnapshot: CodexTurnSnapshot) {
        precondition(initialSnapshot.id == snapshot.id)
        guard hasRoutedEvent else {
            snapshot = initialSnapshot
            return
        }

        var items = initialSnapshot.items
        var indexes = Dictionary(uniqueKeysWithValues: items.indices.map { (items[$0].id, $0) })
        for item in snapshot.items {
            if let index = indexes[item.id] {
                items[index] = item
            } else {
                indexes[item.id] = items.count
                items.append(item)
            }
        }
        snapshot = .init(
            id: snapshot.id,
            state: snapshot.state,
            itemsLoadState: initialSnapshot.itemsLoadState,
            items: items,
            startedAt: snapshot.startedAt ?? initialSnapshot.startedAt,
            completedAt: snapshot.completedAt ?? initialSnapshot.completedAt,
            duration: snapshot.duration ?? initialSnapshot.duration
        )
    }

    mutating func apply(_ event: CodexTurnEvent) {
        hasRoutedEvent = true
        switch event {
        case .started(let turnID):
            precondition(turnID == snapshot.id)
        case .snapshot(let newSnapshot):
            precondition(newSnapshot.id == snapshot.id)
            snapshot = newSnapshot
        case .itemStarted(let item), .itemUpdated(let item), .itemCompleted(let item):
            upsert(item)
        case .message(let message):
            upsert(.init(
                id: message.id,
                kind: message.role == .user ? .userMessage : .agentMessage,
                content: .message(message)
            ))
        case .messageDelta(let delta):
            upsert(requiredCurrentItem(delta.currentItem, eventName: "message delta"))
        case .reasoningSummaryPartAdded(let part):
            upsert(requiredCurrentItem(part.currentItem, eventName: "reasoning part"))
        case .reasoningDelta(let delta):
            upsert(requiredCurrentItem(delta.currentItem, eventName: "reasoning delta"))
        case .tokenUsageUpdated(let newUsage):
            usage = newUsage
        case .unknown:
            break
        case .terminal:
            preconditionFailure("Terminal events must be compacted by finish(_:).")
        }
    }

    func compact(_ outcome: CodexTurnOutcome) -> CompactTurnSnapshot {
        precondition(outcome.response.turnID == snapshot.id)
        let finalizedOutcome = finalized(outcome)
        let response = finalizedOutcome.response
        let state: CodexTurnSnapshot.State
        switch finalizedOutcome {
        case .completed:
            state = .completed
        case .interrupted:
            state = .interrupted
        case .failed(let failedTurn):
            state = .failed(failedTurn.error)
        case .invalidTerminalStatus(let rawStatus, let error, _):
            state = .unknown(rawValue: rawStatus, error: error)
        }
        return .init(
            snapshot: .init(
                id: response.turnID,
                state: state,
                itemsLoadState: .full,
                items: response.transcript.items,
                startedAt: response.startedAt,
                completedAt: response.completedAt,
                duration: response.duration
            ),
            outcome: finalizedOutcome
        )
    }

    private func finalized(_ outcome: CodexTurnOutcome) -> CodexTurnOutcome {
        switch outcome {
        case .completed(let response):
            .completed(finalized(response))
        case .interrupted(let response):
            .interrupted(finalized(response))
        case .failed(let failedTurn):
            .failed(.init(response: finalized(failedTurn.response), error: failedTurn.error))
        case .invalidTerminalStatus(let rawStatus, let error, let response):
            .invalidTerminalStatus(
                rawStatus: rawStatus,
                error: error,
                response: finalized(response)
            )
        }
    }

    private func finalized(_ response: CodexResponse) -> CodexResponse {
        var response = response
        if response.transcript.items.isEmpty {
            response.transcript = .init(items: snapshot.items)
        } else if response.transcript.reviewOutputText == nil,
                  let reviewOutput = snapshot.items.last(where: {
                      $0.kind == .exitedReviewMode && $0.text?.isEmpty == false
                  })
        {
            var items = response.transcript.items
            if let index = items.firstIndex(where: { $0.id == reviewOutput.id }) {
                if items[index].text?.isEmpty != false {
                    items[index] = reviewOutput
                }
            } else {
                items.append(reviewOutput)
            }
            response.transcript = .init(items: items)
        }
        if response.usage == nil {
            response.usage = usage
        }
        return response
    }

    private mutating func upsert(_ item: CodexThreadItem) {
        if let index = snapshot.items.firstIndex(where: { $0.id == item.id }) {
            snapshot.items[index] = item
        } else {
            snapshot.items.append(item)
        }
    }

    private func requiredCurrentItem(
        _ item: CodexThreadItem?,
        eventName: StaticString
    ) -> CodexThreadItem {
        guard let item else {
            preconditionFailure("A reduced \(eventName) must carry its current item.")
        }
        return item
    }
}
