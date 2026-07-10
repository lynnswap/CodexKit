import Darwin
import Foundation
import Testing

import CodexAppServerKitTesting
@testable import CodexAppServerKit

@Suite("Connection lifecycle")
struct ConnectionLifecycleTests {
    @Test func framerUsesSixteenMiBWireLimit() throws {
        #expect(JSONRPC.Framer.maximumFrameByteCount == 16 * 1_024 * 1_024)

        var framer = JSONRPC.Framer(maximumFrameByteCount: 3)
        #expect(try framer.append(0x61) == nil)
        #expect(try framer.append(0x62) == nil)
        #expect(try framer.append(0x63) == nil)
        #expect(try framer.append(0x0A) == Data("abc".utf8))

        _ = try framer.append(0x61)
        _ = try framer.append(0x62)
        _ = try framer.append(0x63)
        #expect(throws: CodexTransportFailure.self) {
            _ = try framer.append(0x64)
        }
    }

    @Test func mailboxOwnsReadySixteenPlusOneOverflowAndDrainsOnClose() async throws {
        let mailbox = JSONRPCInboundFrameMailbox()
        let accepted = (0..<17).map { Data([UInt8($0)]) }
        for frame in accepted {
            try await mailbox.send(frame)
        }

        #expect(await mailbox.snapshot() == .init(
            readyFrameCount: 16,
            hasOverflowFrame: true,
            admissionWaiterCount: 0,
            isTerminal: false
        ))

        let unaccepted = Task {
            try await mailbox.send(Data([17]))
        }
        await mailbox.waitForAdmissionWaiterCount(atLeast: 1)
        #expect(await mailbox.snapshot().acceptedFrameCount == 17)

        await mailbox.finish()
        await #expect(throws: CodexTransportFailure.self) {
            try await unaccepted.value
        }
        await #expect(throws: CodexTransportFailure.self) {
            try await mailbox.send(Data([18]))
        }

        var drained: [Data] = []
        while let frame = try await mailbox.next() {
            drained.append(frame)
        }
        #expect(drained == accepted)
    }

    @Test func cancellingAdmissionWaiterDoesNotTransferItsFrame() async throws {
        let mailbox = JSONRPCInboundFrameMailbox()
        for value in 0..<17 {
            try await mailbox.send(Data([UInt8(value)]))
        }

        let blocked = Task {
            try await mailbox.send(Data([17]))
        }
        await mailbox.waitForAdmissionWaiterCount(atLeast: 1)
        blocked.cancel()
        await #expect(throws: CancellationError.self) {
            try await blocked.value
        }

        let snapshot = await mailbox.snapshot()
        #expect(snapshot.acceptedFrameCount == 17)
        #expect(snapshot.admissionWaiterCount == 0)
    }

    @Test func cancelledReceiverDoesNotConsumeFrameOrTerminalFailure() async throws {
        let mailbox = JSONRPCInboundFrameMailbox()
        let receiver = Task {
            try await mailbox.next()
        }
        await mailbox.waitUntilReceiverIsRegistered()
        receiver.cancel()
        await #expect(throws: CancellationError.self) {
            try await receiver.value
        }

        let frame = Data("frame".utf8)
        let failure = CodexTransportFailure.protocolViolation(
            message: "terminal",
            rawData: nil
        )
        try await mailbox.send(frame)
        await mailbox.finish(throwing: failure)

        #expect(try await mailbox.next() == frame)
        do {
            _ = try await mailbox.next()
            Issue.record("Expected the terminal failure after the accepted frame.")
        } catch let observed as CodexTransportFailure {
            #expect(observed == failure)
        }
    }

    @Test func concurrentProducerAdmissionIsFIFO() async throws {
        let mailbox = JSONRPCInboundFrameMailbox(readyCapacity: 1)
        try await mailbox.send(Data([UInt8(0)]))
        try await mailbox.send(Data([UInt8(1)]))

        var producers: [Task<Void, Error>] = []
        for value in 2...4 {
            producers.append(Task {
                try await mailbox.send(Data([UInt8(value)]))
            })
            await mailbox.waitForAdmissionWaiterCount(atLeast: value - 1)
        }

        var drained: [Data] = []
        for (index, producer) in producers.enumerated() {
            drained.append(try #require(try await mailbox.next()))
            try await producer.value
            #expect(await mailbox.snapshot().admissionWaiterCount == producers.count - index - 1)
        }
        drained.append(try #require(try await mailbox.next()))
        drained.append(try #require(try await mailbox.next()))

        #expect(drained == (0...4).map { Data([UInt8($0)]) })
    }

    @Test func liveReaderBoundsChunkAndDropsOnlyUnacceptedRemainderOnClose() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let payload = (0..<40)
            .map { "{\"method\":\"future/event\",\"params\":{\"index\":\($0)}}" }
            .joined(separator: "\n") + "\n"
        try Data(payload.utf8).write(to: fixture.payloadURL)
        try fixture.installExecutable(
            """
            #!/bin/sh
            cat "$PAYLOAD_PATH"
            while :; do sleep 1; done
            """
        )

        let transport = try AppServerProcessTransport(
            configuration: fixture.configuration(environment: [
                "PAYLOAD_PATH": fixture.payloadURL.path,
            ])
        )
        await transport.waitForInboundAdmissionWaiterCountForTesting(atLeast: 1)

        let mailboxBeforeClose = await transport.inboundMailboxSnapshotForTesting()
        let stdoutBeforeClose = await transport.stdoutReadSnapshotForTesting()
        #expect(mailboxBeforeClose.acceptedFrameCount == 17)
        #expect(mailboxBeforeClose.admissionWaiterCount == 1)
        #expect(stdoutBeforeClose.successfulReadCount > 0)
        #expect(stdoutBeforeClose.maximumChunkByteCount <= AppServerProcessTransport.stdoutReadChunkByteCount)

        _ = await transport.beginClose()
        var receivedIndexes: [Int] = []
        for _ in 0..<17 {
            guard case .notification(let notification) = try await transport.nextInboundEvent()
            else {
                Issue.record("Expected an accepted notification.")
                return
            }
            let object = try #require(
                JSONSerialization.jsonObject(with: notification.params) as? [String: Int]
            )
            receivedIndexes.append(try #require(object["index"]))
        }
        #expect(try await transport.nextInboundEvent() == nil)
        await transport.finishPendingResponsesAfterInboundDrain(.closed)

        let observation = await transport.waitForProcessExit()
        guard case .exited = observation else {
            Issue.record("Expected the terminated child process to exit, got \(observation).")
            return
        }
        await transport.waitUntilClosed()
        let stdoutAfterClose = await transport.stdoutReadSnapshotForTesting()
        #expect(receivedIndexes == Array(0..<17))
        #expect(stdoutAfterClose.successfulReadCount == stdoutBeforeClose.successfulReadCount)
        #expect(stdoutAfterClose.currentChunkRemainderByteCount == 0)
        #expect(stdoutAfterClose.sourceCancellationCompleted)

        let beforeReap = await transport.processLifecycleSnapshotForTesting()
        #expect(beforeReap.didObserveExit)
        #expect(beforeReap.didReap == false)
        await transport.reapProcess()
        await transport.reapProcess()
        let afterReap = await transport.processLifecycleSnapshotForTesting()
        #expect(afterReap.didReap)
        #expect(afterReap.reapSystemCallCount == 1)
    }

    @Test func processIgnoringTermIsKilledBeforeExitObservationAndReapedOnce() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        try fixture.installExecutable(
            """
            #!/bin/sh
            trap '' TERM
            printf '%s\n' '{"method":"ready","params":{}}'
            while :; do sleep 1; done
            """
        )
        let transport = try AppServerProcessTransport(
            configuration: fixture.configuration()
        )
        guard case .notification = try await transport.nextInboundEvent() else {
            Issue.record("Expected the child readiness notification.")
            return
        }

        _ = await transport.beginClose()
        let observation = await transport.waitForProcessExit()
        #expect(observation == .exited(status: -SIGKILL, observedBeforeTermination: false))
        await transport.waitUntilClosed()
        await transport.reapProcess()
        await transport.reapProcess()
        #expect(await transport.processLifecycleSnapshotForTesting().reapSystemCallCount == 1)
    }

    @Test func exitReadinessWaitsForWaitIDStatusPublication() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        try fixture.installExecutable(
            """
            #!/bin/sh
            sleep 0.01
            exit 0
            """
        )

        for _ in 0..<20 {
            let transport = try AppServerProcessTransport(
                configuration: fixture.configuration()
            )
            let observation = await transport.waitForProcessExit()
            #expect(observation == .exited(status: 0, observedBeforeTermination: true))

            _ = await transport.beginClose()
            #expect(try await transport.nextInboundEvent() == nil)
            await transport.finishPendingResponsesAfterInboundDrain(.closed)
            await transport.waitUntilClosed()
            await transport.reapProcess()
            #expect(await transport.processLifecycleSnapshotForTesting().reapSystemCallCount == 1)
        }
    }

    @Test func explicitCloseWhileInboundIsIdleCompletesRouterAndReapsOnce() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        try fixture.installExecutable(
            """
            #!/bin/sh
            while :; do sleep 1; done
            """
        )
        let transport = try AppServerProcessTransport(
            configuration: fixture.configuration()
        )
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            processTerminationToken: transport.processTerminationToken
        )
        await transport.waitUntilInboundReceiverIsRegisteredForTesting()

        await harness.close()
        await harness.supervisor.waitUntilClosed()

        #expect(await harness.supervisor.terminationForTesting() == .closedByCaller)
        let lifecycle = await transport.processLifecycleSnapshotForTesting()
        #expect(lifecycle.didObserveExit)
        #expect(lifecycle.didReap)
        #expect(lifecycle.reapSystemCallCount == 1)
    }

    @Test func unknownResponseWhileOpenTerminatesTheConnection() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        let frame = Data(#"{"id":999,"result":{}}"#.utf8)

        try await transport.emitRawInboundFrame(frame)
        let termination = await harness.supervisor.waitForTerminationForTesting()
        guard case .transportFailure(.protocolViolation(_, let rawData)) = termination else {
            Issue.record("Expected an unknown response protocol violation, got \(termination).")
            return
        }
        #expect(rawData == frame)
        await harness.supervisor.waitUntilClosed()
    }

    @Test func unknownResponseAcceptedBeforeCloseDoesNotReplaceCloseWinner() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        let gate = CodexAppServerTestGate()
        await transport.holdNextInboundEventDelivery(at: gate)

        try await transport.emitRawInboundFrame(Data(#"{"id":999,"result":{}}"#.utf8))
        await transport.waitUntilInboundEventDeliveryIsHeld()
        await harness.close()

        #expect(await harness.supervisor.terminationForTesting() == .closedByCaller)
    }

    @Test func writerFailureClaimsTypedTerminalAndRunsFullClose() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        try fixture.installExecutable(
            """
            #!/bin/sh
            while :; do sleep 1; done
            """
        )
        let transport = try AppServerProcessTransport(
            configuration: fixture.configuration(),
            writerFactory: { fileHandle in
                AppServerJSONRPCWriter(fileHandle: fileHandle) { _ in
                    throw POSIXError(.EPIPE)
                }
            }
        )
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            processTerminationToken: transport.processTerminationToken
        )

        await #expect(throws: CodexTransportFailure.self) {
            try await transport.notify(.init(method: "test", params: Data("{}".utf8)))
        }
        let termination = await harness.supervisor.waitForTerminationForTesting()
        guard case .transportFailure(.io(let errorNumber, _)) = termination else {
            Issue.record("Expected a typed writer I/O failure, got \(termination).")
            return
        }
        #expect(errorNumber == EPIPE)
        await #expect(throws: JSONRPC.Error.closed) {
            try await transport.notify(.init(method: "after-close", params: Data("{}".utf8)))
        }
        await harness.supervisor.waitUntilClosed()
    }
}

private struct ProcessFixture {
    let rootURL: URL
    let executableURL: URL
    let payloadURL: URL
    let codexHomeURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        executableURL = rootURL.appendingPathComponent("fake-app-server")
        payloadURL = rootURL.appendingPathComponent("payload.jsonl")
        codexHomeURL = rootURL.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func installExecutable(_ contents: String) throws {
        try contents.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func configuration(
        environment: [String: String] = [:]
    ) -> AppServerProcessTransport.Configuration {
        var environment = environment
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin"
        return .init(
            executable: executableURL.path,
            arguments: [],
            environment: environment,
            codexHomeURL: codexHomeURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
