import SwiftUI

private struct CodexModelContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: CodexModelContext? = nil
}

extension EnvironmentValues {
    public var codexModelContext: CodexModelContext? {
        get { self[CodexModelContextEnvironmentKey.self] }
        set { self[CodexModelContextEnvironmentKey.self] = newValue }
    }
}

extension View {
    public func codexModelContainer(_ container: CodexModelContainer) -> some View {
        environment(\.codexModelContext, container.mainContext)
    }

    public func codexModelContext(_ context: CodexModelContext) -> some View {
        environment(\.codexModelContext, context)
    }
}

public struct CodexQueryResults<Model: CodexModel>: RandomAccessCollection {
    public typealias Index = Array<Model>.Index
    public typealias Element = Model

    public var items: [Model]
    public var sections: [CodexFetchSection<Model>]
    public var phase: CodexUIPhase
    public var lastErrorDescription: String?

    public init(
        items: [Model] = [],
        sections: [CodexFetchSection<Model>] = [],
        phase: CodexUIPhase = .idle,
        lastErrorDescription: String? = nil
    ) {
        self.items = items
        self.sections = sections
        self.phase = phase
        self.lastErrorDescription = lastErrorDescription
    }

    public var startIndex: Index {
        items.startIndex
    }

    public var endIndex: Index {
        items.endIndex
    }

    public subscript(position: Index) -> Model {
        items[position]
    }
}

@MainActor
@propertyWrapper
public struct CodexQuery<Model: CodexModel>: @preconcurrency DynamicProperty {
    @Environment(\.codexModelContext) private var modelContext
    @State private var fetchedResults: CodexFetchedResults<Model>?
    private let request: CodexFetchRequest<Model>

    public init(_ request: CodexFetchRequest<Model>) {
        self.request = request
    }

    public var wrappedValue: CodexQueryResults<Model> {
        guard let fetchedResults else {
            return CodexQueryResults()
        }
        return CodexQueryResults(
            items: fetchedResults.items,
            sections: fetchedResults.sections,
            phase: fetchedResults.phase,
            lastErrorDescription: fetchedResults.lastErrorDescription
        )
    }

    public mutating func update() {
        guard fetchedResults == nil, let modelContext else {
            return
        }
        let results = modelContext.fetchedResults(for: request)
        fetchedResults = results
        Task {
            try? await results.performFetch()
        }
    }
}
