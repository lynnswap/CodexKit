import CodexAppServerKit
import Foundation

@MainActor
public struct CodexChatTurnSnapshot {
    public let turnID: CodexTurnID
    public let turn: CodexChat.Turn
    public let items: [CodexChat.Item]

    public var id: CodexTurnID {
        turnID
    }

    public var status: CodexTurnStatus? {
        turn.status
    }

    public var errorDescription: String? {
        turn.errorDescription
    }

    public var usage: CodexTokenUsage? {
        turn.usage
    }

    public var threadItems: [CodexThreadItem] {
        items.map { item in
            CodexThreadItem(
                id: item.id,
                kind: item.kind,
                content: item.content,
                rawPayload: item.rawPayload
            )
        }
    }

    public var transcript: CodexTranscript {
        CodexTranscript(items: threadItems)
    }

    package init(turn: CodexChat.Turn, items: [CodexChat.Item]) {
        self.turnID = turn.id
        self.turn = turn
        self.items = items
    }
}

@MainActor
extension CodexChat {
    public func turn(id: CodexTurnID) -> Turn? {
        turns.first { $0.id == id }
    }

    public func items(in turnID: CodexTurnID) -> [Item] {
        items.filter { $0.turnID == turnID }
    }

    public func turnSnapshot(for turnID: CodexTurnID) -> CodexChatTurnSnapshot? {
        guard let turn = turn(id: turnID) else {
            return nil
        }
        return CodexChatTurnSnapshot(turn: turn, items: items(in: turnID))
    }
}
