import Foundation

public typealias CodexChatUpdates = any AsyncSequence<CodexChatUpdate, Never>

public final class CodexChatObservation {
    public let chat: CodexChat
    public let updates: CodexChatUpdates

    private let cancellation: () -> Void
    public private(set) var isCancelled = false

    package init(
        chat: CodexChat,
        updates: CodexChatUpdates,
        cancellation: @escaping () -> Void
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

    deinit {
        cancel()
    }
}
