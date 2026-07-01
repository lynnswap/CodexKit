import Dispatch

public protocol CodexModelActor: Actor {
    nonisolated var modelContainer: CodexModelContainer { get }
    nonisolated var modelExecutor: any CodexModelExecutor { get }
}

public protocol CodexModelExecutor: Executor {
    var modelContext: CodexModelContext { get }
}

public protocol CodexSerialModelExecutor: CodexModelExecutor, SerialExecutor {}

public extension CodexModelActor {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        guard let serialExecutor = modelExecutor as? any SerialExecutor else {
            preconditionFailure("CodexModelActor requires a serial model executor.")
        }
        return serialExecutor.asUnownedSerialExecutor()
    }

    var modelContext: CodexModelContext {
        modelExecutor.modelContext
    }
}

public final class CodexDefaultSerialModelExecutor: @unchecked Sendable, CodexSerialModelExecutor {
    public let modelContext: CodexModelContext

    private let queue: DispatchQueue

    public convenience init(modelContainer: CodexModelContainer) {
        self.init(modelContext: CodexModelContext(modelContainer))
    }

    public init(modelContext: CodexModelContext) {
        self.modelContext = modelContext
        self.queue = DispatchQueue(
            label: "com.openai.codex-data-kit.model-executor",
            qos: .userInitiated
        )
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
