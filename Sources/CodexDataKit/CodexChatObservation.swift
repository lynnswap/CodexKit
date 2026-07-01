import Foundation

public typealias CodexChatUpdates = any AsyncSequence<CodexChatUpdate, Never> & Sendable

@MainActor
public final class CodexChatObservation {
    public let chat: CodexChat
    public let updates: CodexChatUpdates

    private let cancellation: @MainActor () -> Void
    public private(set) var isCancelled = false

    package init(
        chat: CodexChat,
        updates: CodexChatUpdates,
        cancellation: @escaping @MainActor () -> Void
    ) {
        self.chat = chat
        self.updates = updates
        self.cancellation = cancellation
    }

    public func cancel() {
        guard isCancelled == false else {
            return
        }
        isCancelled = true
        cancellation()
    }

    isolated deinit {
        cancel()
    }
}
