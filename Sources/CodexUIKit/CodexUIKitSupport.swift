import Foundation

/// Phase exposed by CodexUI observable owners.
public enum CodexUIKitPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}
