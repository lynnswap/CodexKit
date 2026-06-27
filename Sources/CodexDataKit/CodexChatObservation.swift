import Foundation

@MainActor
public final class CodexChatObservation {
    public let chat: CodexChat

    private let task: Task<Void, Never>
    public private(set) var isCancelled = false

    package init(chat: CodexChat, task: Task<Void, Never>) {
        self.chat = chat
        self.task = task
    }

    public func cancel() {
        guard isCancelled == false else {
            return
        }
        isCancelled = true
        task.cancel()
    }

    isolated deinit {
        task.cancel()
    }
}
