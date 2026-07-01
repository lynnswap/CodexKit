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

public struct CodexQueryResults<Model: CodexPersistentModel>: RandomAccessCollection {
    public typealias Index = Array<Model>.Index
    public typealias Element = Model

    public var items: [Model]
    public var sections: [CodexFetchSection<Model>]
    public var phase: CodexDataPhase
    public var lastErrorDescription: String?

    public init(
        items: [Model] = [],
        sections: [CodexFetchSection<Model>] = [],
        phase: CodexDataPhase = .idle,
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
public struct CodexQuery<Model: CodexPersistentModel>: @preconcurrency DynamicProperty {
    @Environment(\.codexModelContext) private var modelContext
    @State private var fetchedResults: CodexFetchedResults<Model>?
    private let fetchDescriptor: CodexFetchDescriptor<Model>
    private let sectionBy: CodexSectionDescriptor<Model>?

    public init(
        _ descriptor: CodexFetchDescriptor<Model> = .init(),
        animation _: Animation? = nil,
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.fetchDescriptor = descriptor
        self.sectionBy = sectionBy
    }

    public init(
        filter: CodexFetchPredicate<Model>? = nil,
        sort: [CodexSortDescriptor<Model>] = [],
        animation _: Animation? = nil,
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.fetchDescriptor = CodexFetchDescriptor(
            predicate: filter ?? .init(),
            sortBy: sort
        )
        self.sectionBy = sectionBy
    }

    public init<Value: Comparable>(
        filter: CodexFetchPredicate<Model>? = nil,
        sort keyPath: KeyPath<Model, Value>,
        order: CodexSortOrder = .forward,
        animation: Animation? = nil,
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.init(
            filter: filter,
            sort: [CodexSortDescriptor(keyPath, order: order)],
            animation: animation,
            sectionBy: sectionBy
        )
    }

    public init<Value: Comparable>(
        filter: CodexFetchPredicate<Model>? = nil,
        sort keyPath: KeyPath<Model, Value?>,
        order: CodexSortOrder = .forward,
        animation: Animation? = nil,
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.init(
            filter: filter,
            sort: [CodexSortDescriptor(keyPath, order: order)],
            animation: animation,
            sectionBy: sectionBy
        )
    }

    public init(
        fetchRequest request: CodexFetchRequest<Model>,
        animation _: Animation? = nil,
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.fetchDescriptor = request.fetchDescriptor
        self.sectionBy = sectionBy
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
        guard let modelContext else {
            fetchedResults = nil
            return
        }

        if let fetchedResults,
           fetchedResults.modelContext === modelContext,
           fetchedResults.fetchDescriptor == fetchDescriptor,
           fetchedResults.sectionBy == sectionBy {
            return
        }

        let results = modelContext.fetchedResults(for: fetchDescriptor, sectionedBy: sectionBy)
        fetchedResults = results
        Task {
            try? await results.performFetch()
        }
    }
}
