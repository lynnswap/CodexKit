import CodexAppServerKit
import Foundation
import Observation

@MainActor
public protocol CodexObservableModel: AnyObject, Identifiable where ID: Sendable {
    var id: ID { get }
    var modelContext: CodexModelContext? { get }
}

public struct CodexWorkspaceID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }
}

public struct CodexWorkspaceGroupID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }
}

public struct CodexChatInput: Sendable {
    public var instructions: CodexInstructions?
    public var options: CodexThread.Options

    public init(
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init()
    ) {
        self.instructions = instructions
        self.options = options
    }
}

public struct CodexChatMessageInput: Sendable {
    public var prompt: CodexPrompt
    public var options: CodexGenerationOptions

    public init(
        _ text: String,
        options: CodexGenerationOptions = .init()
    ) {
        self.prompt = CodexPrompt(text)
        self.options = options
    }

    public init(
        prompt: CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) {
        self.prompt = prompt
        self.options = options
    }
}

@MainActor
@Observable
public final class CodexWorkspaceGroup: CodexObservableModel {
    public let id: CodexWorkspaceGroupID
    public private(set) var name: String
    public private(set) var workspaces: [CodexWorkspace]

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    package init(
        id: CodexWorkspaceGroupID,
        name: String,
        modelContext: CodexModelContext
    ) {
        self.id = id
        self.name = name
        self.workspaces = []
        self.modelContext = modelContext
    }

    package func update(name: String) {
        self.name = name
    }

    package func setWorkspaces(_ workspaces: [CodexWorkspace]) {
        self.workspaces = workspaces
    }

    public func refresh() async throws {
        try await modelContext?.refresh(self)
    }
}

@MainActor
@Observable
public final class CodexWorkspace: CodexObservableModel {
    public let id: CodexWorkspaceID
    public private(set) var url: URL
    public private(set) var name: String
    public private(set) var workspaceGroup: CodexWorkspaceGroup?
    public private(set) var chats: [CodexChat]

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    package init(
        id: CodexWorkspaceID,
        url: URL,
        name: String,
        workspaceGroup: CodexWorkspaceGroup?,
        modelContext: CodexModelContext
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.workspaceGroup = workspaceGroup
        self.chats = []
        self.modelContext = modelContext
    }

    package func update(
        url: URL,
        name: String,
        workspaceGroup: CodexWorkspaceGroup?
    ) {
        self.url = url
        self.name = name
        self.workspaceGroup = workspaceGroup
    }

    package func setChats(_ chats: [CodexChat]) {
        self.chats = chats
    }

    package func addChatIfNeeded(_ chat: CodexChat) {
        guard chats.contains(where: { $0 === chat }) == false else {
            return
        }
        chats.append(chat)
    }

    package func moveChatToFront(_ chat: CodexChat) {
        chats.removeAll { $0 === chat }
        chats.insert(chat, at: 0)
    }

    public func refresh() async throws {
        try await modelContext?.refresh(self)
    }

    @discardableResult
    public func startChat(_ input: CodexChatInput = .init()) async throws -> CodexChat {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await modelContext.startChat(in: self, input: input)
    }
}

@MainActor
@Observable
public final class CodexChat: CodexObservableModel {
    public let id: CodexThreadID
    public private(set) var workspace: CodexWorkspace?
    public private(set) var name: String?
    public private(set) var preview: String?
    public private(set) var modelProvider: String?
    public private(set) var createdAt: Date?
    public private(set) var updatedAt: Date?
    public private(set) var ephemeral: Bool?
    public private(set) var turns: [Turn]
    public private(set) var items: [Item]
    public var phase: CodexUIPhase = .idle
    public var lastErrorDescription: String?

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    public var title: String {
        if let name, name.isEmpty == false {
            return name
        }
        if let preview, preview.isEmpty == false {
            return preview
        }
        if let workspace {
            return workspace.name
        }
        return id.rawValue
    }

    public var transcript: CodexTranscript {
        .init(items: items.map(\.threadItem))
    }

    package init(
        id: CodexThreadID,
        modelContext: CodexModelContext
    ) {
        self.id = id
        self.turns = []
        self.items = []
        self.modelContext = modelContext
    }

    package func apply(_ snapshot: CodexThreadSnapshot, workspace: CodexWorkspace?) {
        self.workspace = workspace
        name = snapshot.name
        preview = snapshot.preview
        modelProvider = snapshot.modelProvider
        createdAt = snapshot.createdAt
        updatedAt = snapshot.updatedAt
        ephemeral = snapshot.ephemeral
        if let turns = snapshot.turns {
            replaceTurns(with: turns)
            replaceItems(with: turns)
        }
    }

    public func refresh(includeTurns: Bool = true) async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        phase = .loading
        lastErrorDescription = nil
        do {
            try await modelContext.refresh(self, includeTurns: includeTurns)
            phase = .loaded
        } catch {
            fail(with: error)
            throw error
        }
    }

    @discardableResult
    public func send(_ input: CodexChatMessageInput) async throws -> CodexResponse {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        phase = .loading
        lastErrorDescription = nil
        do {
            let response = try await modelContext.send(input, in: self)
            apply(response)
            phase = .loaded
            return response
        } catch {
            if input.options.transcriptErrorHandlingPolicy != .revertTranscript,
                let response = (error as? CodexAppServerError)?.response
            {
                apply(response)
            }
            fail(with: error)
            throw error
        }
    }

    @discardableResult
    public func send(
        _ text: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        try await send(.init(text, options: options))
    }

    public func cancel() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.cancelActiveTurn(in: self)
    }

    public func archive() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.archive(self)
    }

    public func delete() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.delete(self)
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
