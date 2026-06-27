import Foundation

@MainActor
public final class CodexChatObservation {
    public let chat: CodexChat

    private let cancellation: @MainActor () -> Void
    public private(set) var isCancelled = false

    package init(
        chat: CodexChat,
        cancellation: @escaping @MainActor () -> Void
    ) {
        self.chat = chat
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
