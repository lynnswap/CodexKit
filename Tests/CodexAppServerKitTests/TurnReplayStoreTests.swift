import Foundation
import Testing

@testable import CodexAppServerKit
import CodexAppServerKitTesting

@Suite("Turn replay store")
struct TurnReplayStoreTests {
    @Test func terminalTransitionReleasesConcreteConnectionLeaseAndCachesOutcome() async throws {
        var lease: AppServerConnectionLease?
        let terminationToken: ProcessTerminationToken
        (lease, terminationToken) = makeConnectionLease()
        let weakLease = WeakReference(lease)
        let state = TurnGenerationHandleState(connectionLease: try #require(lease))
        lease = nil
        let compact = makeCompactSnapshot()

        #expect(weakLease.value != nil)
        #expect(await state.snapshot() == .live)
        #expect(await state.transitionToTerminal(compact) == .transitioned)
        #expect(weakLease.value == nil)
        #expect(terminationToken.didRequestTermination)
        #expect(await state.snapshot() == .terminal(compact))
        #expect(try await state.cachedOutcome() == compact.outcome)
        #expect(await state.transitionToTerminal(compact) == .duplicate)
        await state.closeConnection()
    }

    @Test func connectionTerminationReleasesLeaseAndIsReplayedAsTypedFailure() async throws {
        var lease: AppServerConnectionLease?
        let terminationToken: ProcessTerminationToken
        (lease, terminationToken) = makeConnectionLease()
        let weakLease = WeakReference(lease)
        let state = TurnGenerationHandleState(connectionLease: try #require(lease))
        lease = nil
        let termination = CodexConnectionTermination.processExited(status: 9)

        #expect(await state.transitionToTerminated(termination) == .transitioned)
        #expect(weakLease.value == nil)
        #expect(terminationToken.didRequestTermination)
        #expect(await state.snapshot() == .terminated(termination))
        do {
            _ = try await state.cachedOutcome()
            Issue.record("Expected cached outcome lookup to fail after connection termination.")
        } catch let error as CodexAppServerError {
            #expect(error == .connectionTerminated(termination))
        } catch {
            Issue.record("Unexpected cached outcome error: \(error)")
        }

        var events = try #require(try await state.terminalEvents()).makeAsyncIterator()
        do {
            _ = try await events.next()
            Issue.record("Expected late events to fail with connection termination.")
        } catch let error as CodexAppServerError {
            #expect(error == .connectionTerminated(termination))
        } catch {
            Issue.record("Unexpected late event error: \(error)")
        }
    }

    @Test func preWriteCancellationRemovesRegistrationWhilePostWriteRetainsIt() async throws {
        let store = TurnReplayStore()
        let state = makeState()
        let beforeWrite = await store.registerPendingOperation(
            kind: .turn(threadID: "thread-1"),
            state: state
        )

        #expect(await store.cancelPendingOperation(beforeWrite) == .removedBeforeWrite)
        #expect(await store.snapshotForTesting().pendingOperationCount == 0)

        let afterWrite = await store.registerPendingOperation(
            kind: .turn(threadID: "thread-1"),
            state: state
        )
        afterWrite.acceptWrite()
        #expect(await store.cancelPendingOperation(afterWrite) == .retainedAfterWrite)
        #expect(await store.snapshotForTesting().postWritePendingOperationCount == 1)

        await store.bind(
            afterWrite,
            to: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress)
        )
        let snapshot = await store.snapshotForTesting()
        #expect(snapshot.pendingOperationCount == 0)
        #expect(snapshot.activeGenerationCount == 1)
        #expect(snapshot.weakStateRegistrationCount == 1)
    }

    @Test func rejectedWriteAttemptReturnsPendingOperationToPreWriteCancellation() async {
        let store = TurnReplayStore()
        let state = makeState()
        let pending = await store.registerPendingOperation(
            kind: .turn(threadID: "thread-1"),
            state: state
        )

        pending.acceptWrite()
        pending.rejectAcceptedWrite()

        #expect(await store.cancelPendingOperation(pending) == .removedBeforeWrite)
        #expect(await store.snapshotForTesting().pendingOperationCount == 0)
    }

    @Test func restoredHandleCopiesResolveOneCanonicalGenerationState() async {
        let store = TurnReplayStore()
        let (lease, _) = makeConnectionLease()
        let initialSnapshot = CodexTurnSnapshot(id: "turn-1", state: .inProgress)

        let first = await store.restoreGeneration(
            turnID: "turn-1",
            initialSnapshot: initialSnapshot,
            connectionLease: lease
        )
        let second = await store.restoreGeneration(
            turnID: "turn-1",
            initialSnapshot: initialSnapshot,
            connectionLease: lease
        )

        #expect(first === second)
        #expect(await store.snapshotForTesting().weakStateRegistrationCount == 1)
    }

    @Test func soleFailedRestoreReservationRemovesItsProvisionalGeneration() async {
        let store = TurnReplayStore()
        let (lease, _) = makeConnectionLease()
        let reservation = await store.reserveRestoredGeneration(
            turnID: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress),
            connectionLease: lease
        )

        #expect(await store.discardRestoredGeneration(reservation))
        #expect(await store.snapshotForTesting().activeGenerationCount == 0)
    }

    @Test func failedRestoreReservationPreservesAnExistingCanonicalHandle() async {
        let store = TurnReplayStore()
        let (lease, _) = makeConnectionLease()
        let existing = await store.restoreGeneration(
            turnID: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress),
            connectionLease: lease
        )
        let reservation = await store.reserveRestoredGeneration(
            turnID: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress),
            connectionLease: lease
        )

        #expect(reservation.state === existing)
        #expect(await store.discardRestoredGeneration(reservation) == false)
        #expect(await store.snapshotForTesting().activeGenerationCount == 1)
        await store.finish(.completed(.init(turnID: "turn-1")))
    }

    @Test func concurrentRestoreFailureCannotDiscardCommittedReservation() async {
        let store = TurnReplayStore()
        let (lease, _) = makeConnectionLease()
        let failed = await store.reserveRestoredGeneration(
            turnID: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress),
            connectionLease: lease
        )
        let committed = await store.reserveRestoredGeneration(
            turnID: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress),
            connectionLease: lease
        )

        #expect(failed.state === committed.state)
        #expect(await store.discardRestoredGeneration(failed) == false)
        await store.commitRestoredGeneration(committed)
        #expect(await store.snapshotForTesting().activeGenerationCount == 1)
        await store.finish(.completed(.init(turnID: "turn-1")))
    }

    @Test func earlyTerminalMakesRestoreCommitAndDiscardFinalizedNoOps() async throws {
        for shouldCommit in [false, true] {
            let store = TurnReplayStore()
            let (lease, _) = makeConnectionLease()
            let reservation = await store.reserveRestoredGeneration(
                turnID: "turn-1",
                initialSnapshot: .init(id: "turn-1", state: .inProgress),
                connectionLease: lease
            )

            await store.finish(.completed(.init(turnID: "turn-1")))
            if shouldCommit {
                await store.commitRestoredGeneration(reservation)
            } else {
                #expect(await store.discardRestoredGeneration(reservation) == false)
            }

            #expect(try await reservation.state.cachedOutcome()?.response.turnID == "turn-1")
            #expect(await store.snapshotForTesting().activeGenerationCount == 0)
        }
    }

    @Test func untrackedThreadEventsDoNotCreatePerTurnReplayState() async {
        let store = TurnReplayStore()

        #expect(
            await store.routeIfTracked(.started("turn-external"), for: "turn-external")
                == .untracked
        )
        #expect(
            await store.finishIfTracked(.completed(.init(turnID: "turn-external"))) == .untracked
        )
        let snapshot = await store.snapshotForTesting()
        #expect(snapshot.pendingOperationCount == 0)
        #expect(snapshot.activeGenerationCount == 0)
        #expect(snapshot.orphanGenerationCount == 0)
    }

    @Test func terminalHandoffTransitionsStateBeforeDeletingRawGeneration() async throws {
        let store = TurnReplayStore()
        let state = makeState()
        let pending = await store.registerPendingOperation(
            kind: .review(sourceThreadID: "thread-1", delivery: .inline),
            state: state
        )
        pending.acceptWrite()
        await store.bind(
            pending,
            to: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress)
        )
        let events = try await store.events(for: "turn-1", state: state)
        var iterator = events.makeAsyncIterator()
        let item = makeItem(id: "live-item")

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress
        )))
        _ = await store.yield(.itemCompleted(item), for: "turn-1")
        await store.finish(.completed(.init(turnID: "turn-1")))

        let terminalState = try #require(await state.snapshot().terminalSnapshot)
        #expect(terminalState.snapshot.items == [item])
        #expect(await store.snapshotForTesting().activeGenerationCount == 0)
        #expect(try await iterator.next() == .snapshot(terminalState.snapshot))
        #expect(try await iterator.next() == .terminal(terminalState.outcome))
        #expect(try await iterator.next() == nil)

        var lateIterator = try await store.events(
            for: "turn-1",
            state: state
        ).makeAsyncIterator()
        #expect(try await lateIterator.next() == .snapshot(terminalState.snapshot))
        #expect(try await lateIterator.next() == .terminal(terminalState.outcome))
        #expect(try await lateIterator.next() == nil)
    }

    @Test func lateTranscriptSubscriptionReplaysTerminalSnapshot() async throws {
        let store = TurnReplayStore()
        let state = makeState()
        let pending = await store.registerPendingOperation(
            kind: .turn(threadID: "thread-1"),
            state: state
        )
        pending.acceptWrite()
        await store.bind(
            pending,
            to: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress)
        )
        let item = makeItem(id: "terminal-message")
        _ = await store.yield(.itemCompleted(item), for: "turn-1")
        await store.finish(.completed(.init(turnID: "turn-1")))

        let events = CodexTurnEventSequence(
            turnID: "turn-1",
            store: store,
            state: state
        )
        var transcripts = CodexTurnTranscriptSequence(events: events).makeAsyncIterator()

        #expect(try await transcripts.next() == .init(items: [item]))
        #expect(try await transcripts.next() == nil)
    }

    @Test func earlyDetachedTerminalIsBoundedUntilResponseBindsItsState() async throws {
        let store = TurnReplayStore()
        let state = makeState()
        let pending = await store.registerPendingOperation(
            kind: .review(sourceThreadID: "source-thread", delivery: .detached),
            state: state
        )
        pending.acceptWrite()
        let item = makeItem(id: "early-item")

        _ = await store.yield(.itemCompleted(item), for: "early-turn")
        await store.finish(.completed(.init(turnID: "early-turn")))
        var snapshot = await store.snapshotForTesting()
        #expect(snapshot.pendingOperationCount == 1)
        #expect(snapshot.orphanGenerationCount == 1)
        #expect(snapshot.terminalOrphanCount == 1)

        await store.bind(
            pending,
            to: "early-turn",
            initialSnapshot: .init(id: "early-turn", state: .inProgress)
        )
        snapshot = await store.snapshotForTesting()
        #expect(snapshot.pendingOperationCount == 0)
        #expect(snapshot.orphanGenerationCount == 0)
        #expect(snapshot.activeGenerationCount == 0)
        let compact = try #require(await state.snapshot().terminalSnapshot)
        #expect(compact.snapshot.items == [item])
    }

    @Test func orphanCapacityEqualsUnboundPostWriteOperationCount() async {
        let store = TurnReplayStore()
        let firstState = makeState()
        let secondState = makeState()
        let first = await store.registerPendingOperation(
            kind: .review(sourceThreadID: "source-1", delivery: .detached),
            state: firstState
        )
        let second = await store.registerPendingOperation(
            kind: .review(sourceThreadID: "source-2", delivery: .detached),
            state: secondState
        )
        first.acceptWrite()
        second.acceptWrite()

        _ = await store.yield(.started("early-1"), for: "early-1")
        _ = await store.yield(.started("early-2"), for: "early-2")
        let snapshot = await store.snapshotForTesting()
        #expect(snapshot.postWritePendingOperationCount == 2)
        #expect(snapshot.orphanGenerationCount == 2)

        await store.terminateAll(with: .closedByCaller)
    }

    @Test func orphanGenerationNPlusOneFailsFast() async {
        await #expect(processExitsWith: .failure) {
            let store = TurnReplayStore()
            let state = makeTurnReplayExitTestState()
            let pending = await store.registerPendingOperation(
                kind: .review(sourceThreadID: "source", delivery: .detached),
                state: state
            )
            pending.acceptWrite()
            _ = await store.yield(.started("early-1"), for: "early-1")
            _ = await store.yield(.started("early-2"), for: "early-2")
        }
    }

    @Test func storeKeepsOnlyWeakHandleStateRegistrations() async throws {
        let store = TurnReplayStore()
        var state: TurnGenerationHandleState? = makeState()
        let weakState = WeakReference(state)
        let pending = await store.registerPendingOperation(
            kind: .turn(threadID: "thread-1"),
            state: try #require(state)
        )
        pending.acceptWrite()
        await store.bind(
            pending,
            to: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress)
        )

        state = nil
        #expect(weakState.value == nil)
        #expect(await store.snapshotForTesting().weakStateRegistrationCount == 0)
        await store.finish(.completed(.init(turnID: "turn-1")))
        #expect(await store.snapshotForTesting().activeGenerationCount == 0)
    }

    @Test func distinctStateRegistrationFailsFast() async {
        await #expect(processExitsWith: .failure) {
            let store = TurnReplayStore()
            let sharedState = makeTurnReplayExitTestState()
            let pending = await store.registerPendingOperation(
                kind: .turn(threadID: "thread-1"),
                state: sharedState
            )
            pending.acceptWrite()
            await store.bind(
                pending,
                to: "turn-1",
                initialSnapshot: .init(id: "turn-1", state: .inProgress)
            )
            await store.register(makeTurnReplayExitTestState(), for: "turn-1")
        }
    }

    @Test func connectionTerminationClearsAllRawStateAndFailsSubscribers() async throws {
        let store = TurnReplayStore()
        let state = makeState()
        let pending = await store.registerPendingOperation(
            kind: .turn(threadID: "thread-1"),
            state: state
        )
        pending.acceptWrite()
        await store.bind(
            pending,
            to: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress)
        )
        let events = try await store.events(for: "turn-1", state: state)
        var iterator = events.makeAsyncIterator()
        let termination = CodexConnectionTermination.transportFailure(
            .io(errno: 32, message: "broken pipe")
        )

        await store.terminateAll(with: termination)
        let snapshot = await store.snapshotForTesting()
        #expect(snapshot.pendingOperationCount == 0)
        #expect(snapshot.activeGenerationCount == 0)
        #expect(snapshot.orphanGenerationCount == 0)
        #expect(snapshot.termination == termination)
        #expect(await state.snapshot() == .terminated(termination))
        do {
            _ = try await iterator.next()
            Issue.record("Expected the active subscriber to fail on connection termination.")
        } catch let error as CodexAppServerError {
            #expect(error == .connectionTerminated(termination))
        } catch {
            Issue.record("Unexpected active subscriber error: \(error)")
        }
    }

    @Test func concurrentTerminationAndSubscriptionJoinOneFullCleanup() async throws {
        let store = TurnReplayStore()
        let state = makeState()
        let pending = await store.registerPendingOperation(
            kind: .turn(threadID: "thread-1"),
            state: state
        )
        pending.acceptWrite()
        await store.bind(
            pending,
            to: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress)
        )
        let termination = CodexConnectionTermination.processExited(status: 15)
        let firstTermination = Task {
            await store.terminateAll(with: termination)
        }
        let racingEvents = try await store.events(for: "turn-1", state: state)
        let secondTermination = Task {
            await store.terminateAll(with: termination)
        }
        await firstTermination.value
        await secondTermination.value

        let snapshot = await store.snapshotForTesting()
        #expect(snapshot.activeGenerationCount == 0)
        #expect(snapshot.pendingOperationCount == 0)
        #expect(snapshot.termination == termination)
        #expect(await state.snapshot() == .terminated(termination))
        var iterator = racingEvents.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected racing subscription to observe typed termination.")
        } catch let error as CodexAppServerError {
            #expect(error == .connectionTerminated(termination))
        } catch {
            Issue.record("Unexpected racing subscription error: \(error)")
        }
    }

    private func makeState() -> TurnGenerationHandleState {
        TurnGenerationHandleState(connectionLease: makeConnectionLease().0)
    }

    private func makeConnectionLease() -> (
        AppServerConnectionLease,
        ProcessTerminationToken
    ) {
        let transport = CodexAppServerTestTransport()
        let closeAction = ConnectionCloseAction()
        let client = AppServerClient(
            transport: transport,
            connectionCloseAction: closeAction
        )
        let turnReplayStore = TurnReplayStore()
        let router = CodexAppServerNotificationRouter(
            client: client,
            turnReplayStore: turnReplayStore
        )
        let connection = AppServerConnection(
            transport: transport,
            client: client,
            router: router,
            turnReplayStore: turnReplayStore,
            serverRequestHandler: CodexAppServer.Configuration.defaultServerRequestHandler(
                clock: .init()
            )
        )
        let supervisor = ConnectionSupervisor(connection: connection)
        closeAction.bind(to: supervisor)
        let terminationToken = ProcessTerminationToken()
        return (
            AppServerConnectionLease(
                supervisor: supervisor,
                processTerminationToken: terminationToken
            ),
            terminationToken
        )
    }

    private func makeCompactSnapshot() -> CompactTurnSnapshot {
        let item = makeItem(id: "terminal")
        let response = CodexResponse(
            turnID: "turn-1",
            transcript: .init(items: [item])
        )
        return .init(
            snapshot: .init(id: "turn-1", state: .completed, items: [item]),
            outcome: .completed(response)
        )
    }

    private func makeItem(id: String) -> CodexThreadItem {
        .init(
            id: id,
            kind: .agentMessage,
            content: .message(.init(id: id, role: .assistant, text: id))
        )
    }
}

private extension TurnGenerationHandleState.Snapshot {
    var terminalSnapshot: CompactTurnSnapshot? {
        if case .terminal(let compactSnapshot) = self {
            return compactSnapshot
        }
        return nil
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private func makeTurnReplayExitTestState() -> TurnGenerationHandleState {
    let transport = CodexAppServerTestTransport()
    let closeAction = ConnectionCloseAction()
    let client = AppServerClient(
        transport: transport,
        connectionCloseAction: closeAction
    )
    let turnReplayStore = TurnReplayStore()
    let router = CodexAppServerNotificationRouter(
        client: client,
        turnReplayStore: turnReplayStore
    )
    let connection = AppServerConnection(
        transport: transport,
        client: client,
        router: router,
        turnReplayStore: turnReplayStore,
        serverRequestHandler: CodexAppServer.Configuration.defaultServerRequestHandler(
            clock: .init()
        )
    )
    let supervisor = ConnectionSupervisor(connection: connection)
    closeAction.bind(to: supervisor)
    return TurnGenerationHandleState(connectionLease: .init(
        supervisor: supervisor,
        processTerminationToken: .init()
    ))
}
