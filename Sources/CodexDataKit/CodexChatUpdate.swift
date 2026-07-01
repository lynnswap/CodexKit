import CodexAppServerKit
import Foundation

public enum CodexChatResynchronizationReason: Equatable, Sendable {
    case refresh
}

public enum CodexChatUpdate: Equatable, Sendable {
    case resynchronized(reason: CodexChatResynchronizationReason)
    case turnInserted(id: CodexTurnID)
    case turnUpdated(id: CodexTurnID)
    case itemInserted(id: String, turnID: CodexTurnID?)
    case itemUpdated(id: String, turnID: CodexTurnID?)
    case itemRemoved(id: String, turnID: CodexTurnID?)
    case itemTextAppended(id: String, turnID: CodexTurnID?, delta: String)
    case statusChanged(CodexThreadStatus?)
    case phaseChanged(CodexDataPhase)

    public var affectedTurnID: CodexTurnID? {
        switch self {
        case .resynchronized,
             .statusChanged,
             .phaseChanged:
            nil
        case .turnInserted(let id),
             .turnUpdated(let id):
            id
        case .itemInserted(_, let turnID),
             .itemUpdated(_, let turnID),
             .itemRemoved(_, let turnID),
             .itemTextAppended(_, let turnID, _):
            turnID
        }
    }
}
