import CodexAppServerKit
import Foundation
import Observation

@MainActor
@Observable
public final class CodexConversation {
    public struct Configuration: Sendable {
        public var includeTurnsInRefresh: Bool

        public init(includeTurnsInRefresh: Bool = true) {
            self.includeTurnsInRefresh = includeTurnsInRefresh
        }
    }

    public let id: CodexThreadID
    public var phase: CodexUIPhase = .idle
    public var workspace: URL?
    public var name: String?
    public var preview: String?
    public var turns: [Turn] = []
    public var items: [Item] = []
    public var lastErrorDescription: String?

    public var title: String {
        if let name, name.isEmpty == false {
            return name
        }
        if let preview, preview.isEmpty == false {
            return preview
        }
        if let workspace {
            return workspace.lastPathComponent
        }
        return id.rawValue
    }

    public var transcript: CodexTranscript {
        .init(items: items.map(\.threadItem))
    }

    @ObservationIgnored
    private let thread: CodexThread
    private let configuration: Configuration

    public init(thread: CodexThread, configuration: Configuration = .init()) {
        self.thread = thread
        self.configuration = configuration
        self.id = thread.id
        self.workspace = thread.workspace
    }

    public static func resume(
        _ threadID: CodexThreadID,
        server: CodexAppServer,
        options: CodexThread.ResumeOptions = .init(),
        configuration: Configuration = .init()
    ) async throws -> CodexConversation {
        let thread = try await server.resumeThread(threadID, options: options)
        return CodexConversation(thread: thread, configuration: configuration)
    }

    public func refresh(includeTurns: Bool? = nil) async throws {
        phase = .loading
        lastErrorDescription = nil
        do {
            let shouldIncludeTurns = includeTurns ?? configuration.includeTurnsInRefresh
            let record = try await thread.read(
                includeTurns: shouldIncludeTurns
            )
            workspace = record.workspace
            name = record.name
            preview = record.preview
            if shouldIncludeTurns {
                replaceTurns(with: record.turns)
                replaceItems(with: record.turns)
            }
            phase = .loaded
        } catch {
            fail(with: error)
            throw error
        }
    }

    @discardableResult
    public func send(
        _ prompt: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        try await send(CodexPrompt(prompt), options: options)
    }

    @discardableResult
    public func send(
        _ prompt: CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        phase = .loading
        lastErrorDescription = nil
        do {
            let response = try await thread.respond(to: prompt, options: options)
            apply(response)
            phase = .loaded
            return response
        } catch {
            if options.transcriptErrorHandlingPolicy != .revertTranscript,
               let response = (error as? CodexAppServerError)?.response {
                apply(response)
            }
            fail(with: error)
            throw error
        }
    }

    @discardableResult
    public func send(
        options: CodexGenerationOptions = .init(),
        @CodexPromptBuilder prompt: () throws -> CodexPrompt
    ) async throws -> CodexResponse {
        try await send(try prompt(), options: options)
    }

    private func replaceTurns(with records: [CodexTurnSnapshot]) {
        let existingByID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        turns = records.map { record in
            let turn = existingByID[record.id] ?? Turn(id: record.id)
            turn.status = record.status
            turn.errorDescription = record.errorMessage
            return turn
        }
    }

    private func replaceItems(with records: [CodexTurnSnapshot]) {
        let existingByKey = Dictionary(uniqueKeysWithValues: items.map { ($0.mergeKey, $0) })
        items = records.flatMap { record in
            record.items.map { incomingItem in
                let incomingKey = ItemKey(id: incomingItem.id, turnID: record.id)
                if let existing = existingByKey[incomingKey] {
                    existing.update(from: incomingItem, turnID: record.id)
                    return existing
                }
                return Item(threadItem: incomingItem, turnID: record.id)
            }
        }
    }

    private func upsertTurn(
        id: CodexTurnID,
        status: CodexTurnStatus?,
        errorDescription: String?
    ) {
        if let turn = turns.first(where: { $0.id == id }) {
            turn.status = status
            turn.errorDescription = errorDescription
        } else {
            turns.append(Turn(id: id, status: status, errorDescription: errorDescription))
        }
    }

    private func apply(_ response: CodexResponse) {
        upsertTurn(
            id: response.turnID,
            status: response.status,
            errorDescription: response.errorMessage
        )
        mergeItems(response.transcript.items, turnID: response.turnID)
    }

    private func mergeItems(_ incomingItems: [CodexThreadItem], turnID: CodexTurnID?) {
        guard incomingItems.isEmpty == false else {
            return
        }
        let existingByKey = Dictionary(uniqueKeysWithValues: items.map { ($0.mergeKey, $0) })
        var merged = items
        for incomingItem in incomingItems {
            let incomingKey = ItemKey(id: incomingItem.id, turnID: turnID)
            if let existing = existingByKey[incomingKey] {
                existing.update(from: incomingItem, turnID: turnID)
            } else {
                merged.append(Item(threadItem: incomingItem, turnID: turnID))
            }
        }
        items = merged
    }

    private func fail(with error: any Error) {
        let message = error.localizedDescription
        lastErrorDescription = message
        phase = .failed(message)
    }

    fileprivate struct ItemKey: Hashable {
        var id: String
        var turnID: CodexTurnID?
    }

    @MainActor
    @Observable
    public final class Turn {
        public let id: CodexTurnID
        public var status: CodexTurnStatus?
        public var errorDescription: String?

        public init(
            id: CodexTurnID,
            status: CodexTurnStatus? = nil,
            errorDescription: String? = nil
        ) {
            self.id = id
            self.status = status
            self.errorDescription = errorDescription
        }
    }

    @MainActor
    @Observable
    public final class Item {
        public let id: String
        public var turnID: CodexTurnID?
        public var kind: CodexThreadItem.Kind
        public var content: CodexThreadItem.Content
        public var rawPayload: Data?

        public var text: String? {
            threadItem.text
        }

        public var message: CodexMessage? {
            threadItem.message
        }

        fileprivate var threadItem: CodexThreadItem {
            CodexThreadItem(id: id, kind: kind, content: content, rawPayload: rawPayload)
        }

        fileprivate var mergeKey: ItemKey {
            .init(id: id, turnID: turnID)
        }

        fileprivate init(threadItem: CodexThreadItem, turnID: CodexTurnID?) {
            self.id = threadItem.id
            self.turnID = turnID
            self.kind = threadItem.kind
            self.content = threadItem.content
            self.rawPayload = threadItem.rawPayload
        }

        fileprivate func update(from threadItem: CodexThreadItem, turnID: CodexTurnID?) {
            self.turnID = turnID
            kind = threadItem.kind
            content = threadItem.content
            rawPayload = threadItem.rawPayload
        }
    }
}
