import CodexAppServerKit
import Foundation

public struct CodexChatSnapshot: Equatable, Sendable {
    public var chatID: CodexThreadID
    public var phase: CodexDataPhase
    public var turns: [CodexChatTurnStateSnapshot]
    public var items: [CodexChatItemSnapshot]

    public init(
        chatID: CodexThreadID,
        phase: CodexDataPhase,
        turns: [CodexChatTurnStateSnapshot],
        items: [CodexChatItemSnapshot]
    ) {
        self.chatID = chatID
        self.phase = phase
        self.turns = turns
        self.items = items
    }

    @MainActor
    package init(chat: CodexChat) {
        self.init(
            chatID: chat.id,
            phase: chat.phase,
            turns: chat.turns.map(CodexChatTurnStateSnapshot.init),
            items: chat.items.map(CodexChatItemSnapshot.init)
        )
    }
}

public struct CodexChatTurnStateSnapshot: Identifiable, Equatable, Sendable {
    public var id: CodexTurnID
    public var status: CodexTurnStatus?
    public var errorDescription: String?
    public var usage: CodexTokenUsage?

    public init(
        id: CodexTurnID,
        status: CodexTurnStatus? = nil,
        errorDescription: String? = nil,
        usage: CodexTokenUsage? = nil
    ) {
        self.id = id
        self.status = status
        self.errorDescription = errorDescription
        self.usage = usage
    }

    @MainActor
    package init(turn: CodexChat.Turn) {
        self.init(
            id: turn.id,
            status: turn.status,
            errorDescription: turn.errorDescription,
            usage: turn.usage
        )
    }
}

public struct CodexChatItemSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var turnID: CodexTurnID?
    public var kind: CodexThreadItem.Kind
    public var content: CodexThreadItem.Content
    public var rawPayload: Data?

    public var threadItem: CodexThreadItem {
        CodexThreadItem(id: id, kind: kind, content: content, rawPayload: rawPayload)
    }

    public var text: String? {
        threadItem.text
    }

    public init(
        id: String,
        turnID: CodexTurnID?,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content,
        rawPayload: Data? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.kind = kind
        self.content = content
        self.rawPayload = rawPayload
    }

    @MainActor
    package init(item: CodexChat.Item) {
        self.init(
            id: item.id,
            turnID: item.turnID,
            kind: item.kind,
            content: item.content,
            rawPayload: item.rawPayload
        )
    }
}

public enum CodexChatChange: Equatable, Sendable {
    case snapshot(CodexChatSnapshot)
    case turnInserted(CodexChatTurnStateSnapshot)
    case turnUpdated(CodexChatTurnStateSnapshot)
    case itemInserted(CodexChatItemSnapshot)
    case itemUpdated(CodexChatItemSnapshot)
    case itemRemoved(id: String, turnID: CodexTurnID?)
    case itemTextAppended(
        id: String,
        turnID: CodexTurnID?,
        delta: String,
        item: CodexChatItemSnapshot
    )
    case phaseChanged(CodexDataPhase)
}
