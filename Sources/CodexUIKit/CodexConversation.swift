import CodexAppServerKit
import Foundation
import Observation

@MainActor
@Observable
/// `CodexConversation` is the observation owner for a single thread.
///
/// It owns the `CodexThread` client and translates server state into simple
/// observable slices suitable for UI rendering.
public final class CodexConversation {
    public struct Configuration: Sendable {
        public var includeTurnsInRefresh: Bool

        public init(includeTurnsInRefresh: Bool = false) {
            self.includeTurnsInRefresh = includeTurnsInRefresh
        }
    }

    /// Current view-model phase. Use this with `lastErrorDescription` for error
    /// presentation.
    public var phase: CodexUIKitPhase
    public var snapshot: CodexThreadSnapshot
    /// Transcript rows derived from the latest completed send and `read` result.
    public var timelineRows: [CodexThreadItem]
    public var transcript: CodexTranscript {
        .init(items: timelineRows)
    }
    /// Last send/read error message from the underlying thread operations.
    public var lastErrorDescription: String?

    @ObservationIgnored
    /// Underlying thread handle used by owner APIs (`refresh`, `send`).
    ///
    /// UI consumers should treat this as a transport handle and primarily read
    /// `snapshot`, `transcript`, `timelineRows`, and `phase`.
    public let thread: CodexThread
    private let ownerConfiguration: Configuration

    public init(thread: CodexThread, configuration: Configuration = .init()) {
        self.thread = thread
        ownerConfiguration = configuration
        phase = .idle
        snapshot = .init(id: thread.id, workspace: thread.workspace)
        timelineRows = []
    }

    public static func resume(
        _ threadID: CodexThreadID,
        server: CodexAppServer,
        options: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexConversation {
        let thread = try await server.resumeThread(threadID, options: options)
        return .init(thread: thread)
    }

    public func refresh(includeTurns: Bool? = nil) async throws {
        // On this first slice, turns are mirrored as diagnostic rows only.
        // Live `thread.events` / `transcriptUpdates` subscriptions are not started here.
        phase = .loading
        lastErrorDescription = nil
        do {
            let includeTurns = includeTurns ?? ownerConfiguration.includeTurnsInRefresh
            snapshot = try await thread.read(includeTurns: includeTurns)
            if includeTurns {
                timelineRows = timelineRows(from: snapshot)
            }
            phase = .loaded
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    @discardableResult
    public func send(
        _ prompt: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        phase = .loading
        lastErrorDescription = nil
        do {
            let response = try await thread.respond(to: prompt, options: options)
            append(response.transcript.items)
            phase = .loaded
            return response
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    public func send(_ prompt: CodexPrompt, options: CodexGenerationOptions = .init()) async throws
        -> CodexResponse
    {
        phase = .loading
        do {
            lastErrorDescription = nil
            let response = try await thread.respond(to: prompt, options: options)
            append(response.transcript.items)
            phase = .loaded
            return response
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    @discardableResult
    public func send(
        @CodexPromptBuilder prompt: () throws -> CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        try await send(try prompt(), options: options)
    }

    private func append(_ items: [CodexThreadItem]) {
        guard items.isEmpty == false else {
            return
        }
        var merged = timelineRows
        for item in items {
            if let index = merged.firstIndex(where: { $0.id == item.id }) {
                merged[index] = item
            } else {
                merged.append(item)
            }
        }
        timelineRows = merged
    }

    private func timelineRows(from snapshot: CodexThreadSnapshot) -> [CodexThreadItem] {
        snapshot.turns.enumerated().map { _, turn in
            CodexThreadItem(
                id: "turn-snapshot:\(turn.id.rawValue)",
                kind: .diagnostic,
                content: .diagnostic(turn.id.rawValue)
            )
        }
    }
}
