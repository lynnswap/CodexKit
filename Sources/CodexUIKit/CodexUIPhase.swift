import Foundation

public enum CodexUIPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}
