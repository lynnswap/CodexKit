import Foundation

public enum CodexDataPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}
