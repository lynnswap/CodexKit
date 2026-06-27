import CodexAppServerKit
import Foundation

public enum CodexChatTurnSelection: Equatable, Sendable {
    case latest
    case turn(CodexTurnID)
}

public struct CodexChatProjectedTurnSnapshot: Identifiable, Equatable, Sendable {
    public var turn: CodexChatTurnStateSnapshot
    public var items: [CodexChatItemSnapshot]

    public var id: CodexTurnID {
        turn.id
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
        items.map(\.threadItem)
    }

    public var transcript: CodexTranscript {
        CodexTranscript(items: threadItems)
    }

    public init(
        turn: CodexChatTurnStateSnapshot,
        items: [CodexChatItemSnapshot]
    ) {
        self.turn = turn
        self.items = items
    }
}

public struct CodexChatTurnProjection: Sendable {
    public struct Update: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case ignored
            case snapshot
            case turnUpdated(CodexChatTurnStateSnapshot)
            case itemUpserted(CodexChatItemSnapshot)
            case itemTextAppended(id: String, turnID: CodexTurnID?, delta: String, item: CodexChatItemSnapshot)
            case itemRemoved(id: String, turnID: CodexTurnID?)
            case phaseChanged(CodexDataPhase)
        }

        public var kind: Kind
        public var affectsSelectedTurn: Bool
        public var snapshot: CodexChatProjectedTurnSnapshot?

        public init(
            kind: Kind,
            affectsSelectedTurn: Bool,
            snapshot: CodexChatProjectedTurnSnapshot?
        ) {
            self.kind = kind
            self.affectsSelectedTurn = affectsSelectedTurn
            self.snapshot = snapshot
        }

        public static func ignored(snapshot: CodexChatProjectedTurnSnapshot?) -> Self {
            .init(kind: .ignored, affectsSelectedTurn: false, snapshot: snapshot)
        }
    }

    private struct ItemKey: Hashable, Sendable {
        var id: String
        var turnID: CodexTurnID?

        init(id: String, turnID: CodexTurnID?) {
            self.id = id
            self.turnID = turnID
        }

        init(_ item: CodexChatItemSnapshot) {
            self.init(id: item.id, turnID: item.turnID)
        }
    }

    public var selection: CodexChatTurnSelection
    private var turnsByID: [CodexTurnID: CodexChatTurnStateSnapshot] = [:]
    private var orderedTurnIDs: [CodexTurnID] = []
    private var itemsByKey: [ItemKey: CodexChatItemSnapshot] = [:]
    private var orderedItemKeys: [ItemKey] = []

    public init(selection: CodexChatTurnSelection = .latest) {
        self.selection = selection
    }

    public var selectedTurnID: CodexTurnID? {
        switch selection {
        case .latest:
            orderedTurnIDs.last ?? orderedItemKeys.last?.turnID
        case .turn(let turnID):
            turnID
        }
    }

    public var snapshot: CodexChatProjectedTurnSnapshot? {
        guard let selectedTurnID,
            let turn = turnsByID[selectedTurnID]
        else {
            return nil
        }
        let items = orderedItemKeys.compactMap { key -> CodexChatItemSnapshot? in
            guard key.turnID == selectedTurnID else {
                return nil
            }
            return itemsByKey[key]
        }
        return CodexChatProjectedTurnSnapshot(turn: turn, items: items)
    }

    public mutating func reset() {
        turnsByID.removeAll(keepingCapacity: true)
        orderedTurnIDs.removeAll(keepingCapacity: true)
        itemsByKey.removeAll(keepingCapacity: true)
        orderedItemKeys.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func apply(_ change: CodexChatChange) -> Update {
        switch change {
        case .snapshot(let snapshot):
            apply(snapshot)
            return .init(kind: .snapshot, affectsSelectedTurn: true, snapshot: self.snapshot)
        case .turnInserted(let turn),
            .turnUpdated(let turn):
            upsert(turn)
            return update(kind: .turnUpdated(turn), affectedTurnID: turn.id)
        case .itemInserted(let item),
            .itemUpdated(let item):
            upsert(item)
            return update(kind: .itemUpserted(item), affectedTurnID: item.turnID)
        case .itemTextAppended(let id, let turnID, let delta, let item):
            upsert(item)
            return update(
                kind: .itemTextAppended(id: id, turnID: turnID, delta: delta, item: item),
                affectedTurnID: turnID
            )
        case .itemRemoved(let id, let turnID):
            removeItem(id: id, turnID: turnID)
            return update(kind: .itemRemoved(id: id, turnID: turnID), affectedTurnID: turnID)
        case .phaseChanged(let phase):
            return .init(kind: .phaseChanged(phase), affectsSelectedTurn: true, snapshot: snapshot)
        }
    }

    private mutating func apply(_ snapshot: CodexChatSnapshot) {
        turnsByID = Dictionary(uniqueKeysWithValues: snapshot.turns.map { ($0.id, $0) })
        orderedTurnIDs = snapshot.turns.map(\.id)
        itemsByKey.removeAll(keepingCapacity: true)
        orderedItemKeys.removeAll(keepingCapacity: true)
        for item in snapshot.items {
            upsert(item)
        }
    }

    private mutating func upsert(_ turn: CodexChatTurnStateSnapshot) {
        if turnsByID[turn.id] == nil {
            orderedTurnIDs.append(turn.id)
        }
        turnsByID[turn.id] = turn
    }

    private mutating func upsert(_ item: CodexChatItemSnapshot) {
        let key = ItemKey(item)
        if itemsByKey[key] == nil {
            orderedItemKeys.append(key)
        }
        itemsByKey[key] = item
    }

    private mutating func removeItem(id: String, turnID: CodexTurnID?) {
        let key = ItemKey(id: id, turnID: turnID)
        itemsByKey.removeValue(forKey: key)
        orderedItemKeys.removeAll { $0 == key }
    }

    private func update(kind: Update.Kind, affectedTurnID: CodexTurnID?) -> Update {
        let affectsSelectedTurn = affectedTurnID == selectedTurnID
        return .init(
            kind: kind,
            affectsSelectedTurn: affectsSelectedTurn,
            snapshot: snapshot
        )
    }
}
