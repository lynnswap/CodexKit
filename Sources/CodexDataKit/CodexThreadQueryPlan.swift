import CodexAppServerKit
import Foundation

package struct CodexChatRecord: Hashable, Sendable {
    package var id: CodexThreadID
    package var name: String?
    package var preview: String?
    package var title: String
    package var modelProvider: String?
    package var isArchived: Bool
    package var workspaceID: CodexWorkspaceID?
    package var workspaceURL: URL?
    package var workspaceGroupID: CodexWorkspaceGroupID?
    package var sourceKind: CodexThreadSourceKind?
    package var searchableText: String
    package var createdAt: Date?
    package var updatedAt: Date?
    package var recencyAt: Date?

    package init(chat: CodexChat) {
        id = chat.id
        name = chat.name
        preview = chat.preview
        title = chat.title
        modelProvider = chat.modelProvider
        isArchived = chat.isArchived
        workspaceID = chat.workspaceID
        workspaceURL = chat.workspace?.url
        workspaceGroupID = chat.workspaceGroupID
        sourceKind = chat.sourceKind
        searchableText = chat.searchableText
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt
        recencyAt = chat.recencyAt
    }
}

package struct CodexThreadQueryPlan: Sendable {
    package typealias RecordPredicate = @Sendable (CodexChatRecord) -> Bool

    package var predicate: RecordPredicate?
    package var predicateSignature: CodexChatPredicateSignature?
    package var sortPlans: [CodexSortPlan<CodexChat>]
    package var fetchLimit: Int?
    package var fetchOffset: Int
    package var includePendingChanges: Bool
    private var serverFilter: CodexThreadServerFilter

    package init(descriptor: CodexFetchDescriptor<CodexChat>) {
        if let predicate = descriptor.predicate {
            let lowered = makeCodexChatRecordPredicate(predicate)
            self.predicate = lowered.predicate
            self.predicateSignature = lowered.signature
            self.serverFilter = CodexThreadServerFilter(signature: lowered.signature)
        } else {
            self.predicate = { $0.isArchived == false }
            self.predicateSignature = nil
            self.serverFilter = .defaultChatFilter
        }
        self.sortPlans = descriptor.sortPlans
        self.fetchLimit = descriptor.fetchLimit
        self.fetchOffset = descriptor.normalizedFetchOffset
        self.includePendingChanges = descriptor.includePendingChanges
    }

    package var signature: CodexFetchDescriptorSignature {
        CodexFetchDescriptorSignature(
            modelKind: .chat,
            predicate: predicateSignature,
            sortPlans: sortPlans.map(\.signature),
            fetchLimit: fetchLimit,
            fetchOffset: fetchOffset,
            includePendingChanges: includePendingChanges
        )
    }

    package var archived: Bool? {
        serverFilter.archived
    }

    package var workspaces: [URL]? {
        serverFilter.workspaces
    }

    package var singleWorkspace: URL? {
        guard let workspaces, workspaces.count == 1 else {
            return nil
        }
        return workspaces[0]
    }

    package var searchTerm: String? {
        serverFilter.searchTerm
    }

    package var modelProviders: [String]? {
        serverFilter.modelProviders
    }

    package var sourceKinds: [CodexThreadSourceKind]? {
        serverFilter.sourceKinds
    }

    package var serverPredicateIsComplete: Bool {
        serverFilter.isComplete
    }

    package var membershipRequiresServerRefresh: Bool {
        serverFilter.requiresServerRefreshForMembership
    }

    package var usesServerOwnedOrdering: Bool {
        sortPlans.first?.key == .recencyAt || sortPlans.isEmpty
    }

    package func matches(_ chat: CodexChat) -> Bool {
        matches(CodexChatRecord(chat: chat))
    }

    package func matches(_ record: CodexChatRecord) -> Bool {
        predicate?(record) ?? true
    }

    package func threadQuery(cursor: String?, includePaging: Bool) -> CodexThreadQuery {
        let serverSort = sortPlans.first { sortPlan in
            switch sortPlan.key {
            case .createdAt, .updatedAt, .recencyAt:
                return true
            case .name:
                return false
            }
        }
        return CodexThreadQuery(
            archived: archived,
            cursor: includePaging ? cursor : nil,
            workspaces: workspaces,
            limit: includePaging ? fetchLimit : nil,
            searchTerm: searchTerm,
            modelProviders: modelProviders,
            sortDirection: serverSort?.threadSortDirection,
            sortKey: serverSort?.threadSortKey,
            sourceKinds: sourceKinds
        )
    }
}

package enum CodexFetchDescriptorModelKind: Hashable, Sendable {
    case chat
    case workspace
    case workspaceGroup
}

package struct CodexFetchDescriptorSignature: Hashable, Sendable {
    package var modelKind: CodexFetchDescriptorModelKind
    package var predicate: CodexChatPredicateSignature?
    package var sortPlans: [CodexSortPlanSignature]
    package var fetchLimit: Int?
    package var fetchOffset: Int
    package var includePendingChanges: Bool
}

package struct CodexSortPlanSignature: Hashable, Sendable {
    package var key: CodexSortKey
    package var order: SortOrder
}

extension CodexSortPlan {
    package var signature: CodexSortPlanSignature {
        .init(key: key, order: order)
    }
}

extension CodexFetchDescriptor {
    package var querySignature: CodexFetchDescriptorSignature {
        let kind: CodexFetchDescriptorModelKind
        if Model.self == CodexChat.self {
            return CodexThreadQueryPlan(descriptor: self as! CodexFetchDescriptor<CodexChat>)
                .signature
        } else if Model.self == CodexWorkspace.self {
            kind = .workspace
        } else if Model.self == CodexWorkspaceGroup.self {
            kind = .workspaceGroup
        } else {
            preconditionFailure("CodexFetchDescriptor does not support fetching \(Model.self).")
        }
        return CodexFetchDescriptorSignature(
            modelKind: kind,
            predicate: nil,
            sortPlans: sortPlans.map(\.signature),
            fetchLimit: fetchLimit,
            fetchOffset: normalizedFetchOffset,
            includePendingChanges: includePendingChanges
        )
    }
}

package enum CodexChatPredicateKey: Hashable, Sendable {
    case isArchived
    case modelProvider
    case workspaceID
    case sourceKind
    case searchableText
}

package enum CodexChatPredicateValue: Hashable, Sendable {
    case key(CodexChatPredicateKey)
    case bool(Bool)
    case string(String)
    case optionalString(String?)
    case workspaceID(CodexWorkspaceID)
    case optionalWorkspaceID(CodexWorkspaceID?)
    case sourceKind(CodexThreadSourceKind)
    case optionalSourceKind(CodexThreadSourceKind?)
    case stringArray([String])
    case workspaceIDArray([CodexWorkspaceID])
    case sourceKindArray([CodexThreadSourceKind])
    case nilLiteral(String)
}

extension CodexChatPredicateValue {
    fileprivate func codexPredicateEquals(_ other: Self) -> Bool {
        switch (self, other) {
        case (.nilLiteral, .optionalString(.none)),
            (.optionalString(.none), .nilLiteral),
            (.nilLiteral, .optionalWorkspaceID(.none)),
            (.optionalWorkspaceID(.none), .nilLiteral),
            (.nilLiteral, .optionalSourceKind(.none)),
            (.optionalSourceKind(.none), .nilLiteral):
            return true
        default:
            return self == other
        }
    }
}

package indirect enum CodexChatPredicateSignature: Hashable, Sendable {
    case bool(CodexChatPredicateValue)
    case equal(CodexChatPredicateValue, CodexChatPredicateValue)
    case notEqual(CodexChatPredicateValue, CodexChatPredicateValue)
    case localizedStandardContains(CodexChatPredicateValue, CodexChatPredicateValue)
    case contains(CodexChatPredicateValue, CodexChatPredicateValue)
    case conjunction(CodexChatPredicateSignature, CodexChatPredicateSignature)
    case disjunction(CodexChatPredicateSignature, CodexChatPredicateSignature)
    case negation(CodexChatPredicateSignature)
}

private struct CodexThreadServerFilter: Hashable, Sendable {
    var archived: Bool?
    var workspaces: [URL]?
    var searchTerm: String?
    var modelProviders: [String]?
    var sourceKinds: [CodexThreadSourceKind]?
    var isComplete = true

    init() {}

    init(signature: CodexChatPredicateSignature) {
        self = Self.filter(from: signature) ?? Self(isComplete: false)
    }

    private init(isComplete: Bool) {
        self.isComplete = isComplete
    }

    static var defaultChatFilter: Self {
        var filter = Self()
        filter.archived = false
        return filter
    }

    var requiresServerRefreshForMembership: Bool {
        searchTerm?.isEmpty == false
            || modelProviders?.isEmpty == false
            || sourceKinds?.isEmpty == false
            || isComplete == false
    }

    private static func filter(from signature: CodexChatPredicateSignature) -> Self? {
        switch signature {
        case .bool(.key(.isArchived)):
            var filter = Self()
            filter.archived = true
            return filter
        case .bool:
            return nil
        case .negation(.bool(.key(.isArchived))):
            var filter = Self()
            filter.archived = false
            return filter
        case .negation:
            return nil
        case .equal(let lhs, let rhs):
            return equalityFilter(lhs, rhs)
        case .notEqual(let lhs, let rhs):
            return inequalityFilter(lhs, rhs)
        case .localizedStandardContains(let lhs, let rhs):
            return localizedContainsFilter(lhs, rhs)
        case .contains(let lhs, let rhs):
            return containsFilter(lhs, rhs)
        case .conjunction(let lhs, let rhs):
            guard var lhsFilter = filter(from: lhs),
                let rhsFilter = filter(from: rhs),
                lhsFilter.merge(rhsFilter)
            else {
                return nil
            }
            return lhsFilter
        case .disjunction(let lhs, let rhs):
            return disjunctionFilter(lhs, rhs)
        }
    }

    private mutating func merge(_ other: Self) -> Bool {
        guard merge(&archived, other.archived),
            merge(&workspaces, other.workspaces),
            merge(&searchTerm, other.searchTerm),
            merge(&modelProviders, other.modelProviders),
            merge(&sourceKinds, other.sourceKinds)
        else {
            return false
        }
        isComplete = isComplete && other.isComplete
        return true
    }

    private func merge<Value: Equatable>(_ lhs: inout Value?, _ rhs: Value?) -> Bool {
        guard let rhs else {
            return true
        }
        guard let lhsValue = lhs else {
            lhs = rhs
            return true
        }
        return lhsValue == rhs
    }

    private static func equalityFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> Self? {
        switch (lhs, rhs) {
        case (.key(.isArchived), .bool(let value)), (.bool(let value), .key(.isArchived)):
            var filter = Self()
            filter.archived = value
            return filter
        case (.key(.workspaceID), .optionalWorkspaceID(.some(let id))),
            (.optionalWorkspaceID(.some(let id)), .key(.workspaceID)):
            var filter = Self()
            filter.workspaces = [URL(fileURLWithPath: id.rawValue, isDirectory: true)]
            return filter
        case (.key(.modelProvider), .optionalString(.some(let provider))),
            (.optionalString(.some(let provider)), .key(.modelProvider)):
            var filter = Self()
            filter.modelProviders = [provider]
            return filter
        case (.key(.sourceKind), .optionalSourceKind(.some(let sourceKind))),
            (.optionalSourceKind(.some(let sourceKind)), .key(.sourceKind)):
            var filter = Self()
            filter.sourceKinds = [sourceKind]
            return filter
        default:
            return nil
        }
    }

    private static func inequalityFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> Self? {
        switch (lhs, rhs) {
        case (.key(.isArchived), .bool(let value)), (.bool(let value), .key(.isArchived)):
            var filter = Self()
            filter.archived = !value
            return filter
        default:
            return nilCheckFilter(lhs, rhs, expectsNil: false)
        }
    }

    private static func nilCheckFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue,
        expectsNil: Bool
    ) -> Self? {
        switch (lhs, rhs) {
        case (.key(.workspaceID), .nilLiteral),
            (.nilLiteral, .key(.workspaceID)),
            (.key(.modelProvider), .nilLiteral),
            (.nilLiteral, .key(.modelProvider)),
            (.key(.sourceKind), .nilLiteral),
            (.nilLiteral, .key(.sourceKind)):
            return expectsNil ? nil : Self(isComplete: false)
        default:
            return nil
        }
    }

    private static func localizedContainsFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> Self? {
        guard lhs == .key(.searchableText),
            case .string(let searchTerm) = rhs
        else {
            return nil
        }
        var filter = Self()
        filter.searchTerm = searchTerm.isEmpty ? nil : searchTerm
        return filter
    }

    private static func containsFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> Self? {
        switch (lhs, rhs) {
        case (.stringArray(let values), .key(.modelProvider)):
            var filter = Self()
            filter.modelProviders = values.isEmpty ? nil : values
            return filter
        case (.sourceKindArray(let values), .key(.sourceKind)):
            var filter = Self()
            filter.sourceKinds = values.isEmpty ? nil : values
            return filter
        case (.workspaceIDArray(let values), .key(.workspaceID)):
            var filter = Self()
            filter.workspaces = values.isEmpty
                ? nil
                : values.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
            return filter
        default:
            return nil
        }
    }

    private static func disjunctionFilter(
        _ lhs: CodexChatPredicateSignature,
        _ rhs: CodexChatPredicateSignature
    ) -> Self? {
        guard let lhs = filter(from: lhs), let rhs = filter(from: rhs) else {
            return nil
        }
        var merged = Self()
        if lhs.onlyHasSourceKinds, rhs.onlyHasSourceKinds {
            merged.sourceKinds = union(lhs.sourceKinds, rhs.sourceKinds)
            return merged
        }
        if lhs.onlyHasModelProviders, rhs.onlyHasModelProviders {
            merged.modelProviders = union(lhs.modelProviders, rhs.modelProviders)
            return merged
        }
        if lhs.onlyHasWorkspaces, rhs.onlyHasWorkspaces {
            merged.workspaces = union(lhs.workspaces, rhs.workspaces)
            return merged
        }
        return nil
    }

    private var onlyHasSourceKinds: Bool {
        sourceKinds != nil && archived == nil && workspaces == nil
            && searchTerm == nil && modelProviders == nil
    }

    private var onlyHasModelProviders: Bool {
        modelProviders != nil && archived == nil && workspaces == nil
            && searchTerm == nil && sourceKinds == nil
    }

    private var onlyHasWorkspaces: Bool {
        workspaces != nil && archived == nil && searchTerm == nil
            && modelProviders == nil && sourceKinds == nil
    }

    private static func union<Value: Hashable>(_ lhs: [Value]?, _ rhs: [Value]?) -> [Value]? {
        let values = (lhs ?? []) + (rhs ?? [])
        var seen: Set<Value> = []
        let unique = values.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }
}

private struct CodexChatExpression<Value: Sendable>: Sendable {
    var evaluate: @Sendable (CodexChatRecord) -> Value
    var signature: CodexChatPredicateValue
}

private enum CodexChatSequenceValue: Sendable {
    case strings([String])
    case workspaceIDs([CodexWorkspaceID])
    case sourceKinds([CodexThreadSourceKind])

    func contains(_ value: CodexChatPredicateValue) -> Bool {
        switch (self, value) {
        case (.strings(let values), .string(let value)):
            values.contains(value)
        case (.workspaceIDs(let values), .workspaceID(let value)):
            values.contains(value)
        case (.sourceKinds(let values), .sourceKind(let value)):
            values.contains(value)
        default:
            false
        }
    }
}

private struct CodexChatPredicateLowering: Sendable {
    var predicate: CodexThreadQueryPlan.RecordPredicate
    var signature: CodexChatPredicateSignature
}

private protocol CodexChatRecordPredicateExpression {
    func codexChatRecordPredicate() -> CodexChatPredicateLowering
}

private protocol CodexChatRecordBoolExpression {
    func codexChatBoolExpression() -> CodexChatExpression<Bool>
}

private protocol CodexChatRecordStringExpression {
    func codexChatStringExpression() -> CodexChatExpression<String>
}

private protocol CodexChatRecordOptionalStringExpression {
    func codexChatOptionalStringExpression() -> CodexChatExpression<String?>
}

private protocol CodexChatRecordWorkspaceIDExpression {
    func codexChatWorkspaceIDExpression() -> CodexChatExpression<CodexWorkspaceID>
}

private protocol CodexChatRecordOptionalWorkspaceIDExpression {
    func codexChatOptionalWorkspaceIDExpression() -> CodexChatExpression<CodexWorkspaceID?>
}

private protocol CodexChatRecordSourceKindExpression {
    func codexChatSourceKindExpression() -> CodexChatExpression<CodexThreadSourceKind>
}

private protocol CodexChatRecordOptionalSourceKindExpression {
    func codexChatOptionalSourceKindExpression() -> CodexChatExpression<CodexThreadSourceKind?>
}

private protocol CodexChatRecordEquatableExpression {
    func codexChatEquatableExpression() -> CodexChatExpression<CodexChatPredicateValue>
}

private protocol CodexChatRecordSequenceExpression {
    func codexChatSequenceExpression() -> CodexChatExpression<CodexChatSequenceValue>
}

private protocol CodexChatRecordMembershipElementExpression {
    func codexChatMembershipElementExpression() -> CodexChatExpression<CodexChatPredicateValue>
}

private func makeCodexChatRecordPredicate(
    _ predicate: Predicate<CodexChat>
) -> CodexChatPredicateLowering {
    guard let expression = predicate.expression as? any CodexChatRecordPredicateExpression else {
        preconditionFailure("Unsupported CodexChat predicate expression: \(type(of: predicate.expression))")
    }
    return expression.codexChatRecordPredicate()
}

extension PredicateExpressions.Conjunction: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordPredicateExpression, RHS: CodexChatRecordPredicateExpression
{
    fileprivate func codexChatRecordPredicate() -> CodexChatPredicateLowering {
        let lhsPredicate = lhs.codexChatRecordPredicate()
        let rhsPredicate = rhs.codexChatRecordPredicate()
        return .init(
            predicate: { record in
                lhsPredicate.predicate(record) && rhsPredicate.predicate(record)
            },
            signature: .conjunction(lhsPredicate.signature, rhsPredicate.signature)
        )
    }
}

extension PredicateExpressions.Disjunction: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordPredicateExpression, RHS: CodexChatRecordPredicateExpression
{
    fileprivate func codexChatRecordPredicate() -> CodexChatPredicateLowering {
        let lhsPredicate = lhs.codexChatRecordPredicate()
        let rhsPredicate = rhs.codexChatRecordPredicate()
        return .init(
            predicate: { record in
                lhsPredicate.predicate(record) || rhsPredicate.predicate(record)
            },
            signature: .disjunction(lhsPredicate.signature, rhsPredicate.signature)
        )
    }
}

extension PredicateExpressions.Negation: CodexChatRecordPredicateExpression
    where Wrapped: CodexChatRecordPredicateExpression
{
    fileprivate func codexChatRecordPredicate() -> CodexChatPredicateLowering {
        let predicate = wrapped.codexChatRecordPredicate()
        return .init(
            predicate: { record in
                predicate.predicate(record) == false
            },
            signature: .negation(predicate.signature)
        )
    }
}

extension PredicateExpressions.Equal: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordEquatableExpression, RHS: CodexChatRecordEquatableExpression
{
    fileprivate func codexChatRecordPredicate() -> CodexChatPredicateLowering {
        let lhsExpression = lhs.codexChatEquatableExpression()
        let rhsExpression = rhs.codexChatEquatableExpression()
        return .init(
            predicate: { record in
                lhsExpression.evaluate(record)
                    .codexPredicateEquals(rhsExpression.evaluate(record))
            },
            signature: .equal(lhsExpression.signature, rhsExpression.signature)
        )
    }
}

extension PredicateExpressions.NotEqual: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordEquatableExpression, RHS: CodexChatRecordEquatableExpression
{
    fileprivate func codexChatRecordPredicate() -> CodexChatPredicateLowering {
        let lhsExpression = lhs.codexChatEquatableExpression()
        let rhsExpression = rhs.codexChatEquatableExpression()
        return .init(
            predicate: { record in
                lhsExpression.evaluate(record)
                    .codexPredicateEquals(rhsExpression.evaluate(record)) == false
            },
            signature: .notEqual(lhsExpression.signature, rhsExpression.signature)
        )
    }
}

extension PredicateExpressions.StringLocalizedStandardContains: CodexChatRecordPredicateExpression
    where Root: CodexChatRecordStringExpression, Other: CodexChatRecordStringExpression
{
    fileprivate func codexChatRecordPredicate() -> CodexChatPredicateLowering {
        let rootExpression = root.codexChatStringExpression()
        let otherExpression = other.codexChatStringExpression()
        return .init(
            predicate: { record in
                rootExpression.evaluate(record).localizedStandardContains(otherExpression.evaluate(record))
            },
            signature: .localizedStandardContains(rootExpression.signature, otherExpression.signature)
        )
    }
}

extension PredicateExpressions.SequenceContains: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordSequenceExpression, RHS: CodexChatRecordMembershipElementExpression
{
    fileprivate func codexChatRecordPredicate() -> CodexChatPredicateLowering {
        let sequenceExpression = sequence.codexChatSequenceExpression()
        let elementExpression = element.codexChatMembershipElementExpression()
        return .init(
            predicate: { record in
                sequenceExpression.evaluate(record).contains(elementExpression.evaluate(record))
            },
            signature: .contains(sequenceExpression.signature, elementExpression.signature)
        )
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordBoolExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == Bool
{
    fileprivate func codexChatBoolExpression() -> CodexChatExpression<Bool> {
        if keyPath == \CodexChat.isArchived {
            return .init(evaluate: { $0.isArchived }, signature: .key(.isArchived))
        }
        preconditionFailure("Unsupported CodexChat Bool predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordPredicateExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == Bool
{
    fileprivate func codexChatRecordPredicate() -> CodexChatPredicateLowering {
        let expression = codexChatBoolExpression()
        return .init(predicate: expression.evaluate, signature: .bool(expression.signature))
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordStringExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == String
{
    fileprivate func codexChatStringExpression() -> CodexChatExpression<String> {
        if keyPath == \CodexChat.searchableText {
            return .init(evaluate: { $0.searchableText }, signature: .key(.searchableText))
        }
        preconditionFailure("Unsupported CodexChat String predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordOptionalStringExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == String?
{
    fileprivate func codexChatOptionalStringExpression() -> CodexChatExpression<String?> {
        if keyPath == \CodexChat.modelProvider {
            return .init(evaluate: { $0.modelProvider }, signature: .key(.modelProvider))
        }
        preconditionFailure("Unsupported CodexChat optional String predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordOptionalWorkspaceIDExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == CodexWorkspaceID?
{
    fileprivate func codexChatOptionalWorkspaceIDExpression() -> CodexChatExpression<CodexWorkspaceID?> {
        if keyPath == \CodexChat.workspaceID {
            return .init(evaluate: { $0.workspaceID }, signature: .key(.workspaceID))
        }
        preconditionFailure("Unsupported CodexChat optional workspace ID predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordOptionalSourceKindExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == CodexThreadSourceKind?
{
    fileprivate func codexChatOptionalSourceKindExpression() -> CodexChatExpression<CodexThreadSourceKind?> {
        if keyPath == \CodexChat.sourceKind {
            return .init(evaluate: { $0.sourceKind }, signature: .key(.sourceKind))
        }
        preconditionFailure("Unsupported CodexChat optional source kind predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordEquatableExpression
    where Root == PredicateExpressions.Variable<CodexChat>
{
    fileprivate func codexChatEquatableExpression() -> CodexChatExpression<CodexChatPredicateValue> {
        if Output.self == Bool.self {
            let expression = (self as! PredicateExpressions.KeyPath<Root, Bool>)
                .codexChatBoolExpression()
            return .init(
                evaluate: { .bool(expression.evaluate($0)) },
                signature: expression.signature
            )
        }
        if Output.self == String?.self {
            let expression = (self as! PredicateExpressions.KeyPath<Root, String?>)
                .codexChatOptionalStringExpression()
            return .init(
                evaluate: { .optionalString(expression.evaluate($0)) },
                signature: expression.signature
            )
        }
        if Output.self == CodexWorkspaceID?.self {
            let expression = (self as! PredicateExpressions.KeyPath<Root, CodexWorkspaceID?>)
                .codexChatOptionalWorkspaceIDExpression()
            return .init(
                evaluate: { .optionalWorkspaceID(expression.evaluate($0)) },
                signature: expression.signature
            )
        }
        if Output.self == CodexThreadSourceKind?.self {
            let expression = (self as! PredicateExpressions.KeyPath<Root, CodexThreadSourceKind?>)
                .codexChatOptionalSourceKindExpression()
            return .init(
                evaluate: { .optionalSourceKind(expression.evaluate($0)) },
                signature: expression.signature
            )
        }
        preconditionFailure("Unsupported CodexChat equatable predicate key path: \(keyPath)")
    }
}

extension PredicateExpressions.ForcedUnwrap: CodexChatRecordStringExpression
    where Inner: CodexChatRecordOptionalStringExpression, Wrapped == String
{
    fileprivate func codexChatStringExpression() -> CodexChatExpression<String> {
        let expression = inner.codexChatOptionalStringExpression()
        return .init(
            evaluate: { record in
                guard let value = expression.evaluate(record) else {
                    preconditionFailure("CodexChat predicate force-unwrapped nil String.")
                }
                return value
            },
            signature: expression.signature
        )
    }
}

extension PredicateExpressions.ForcedUnwrap: CodexChatRecordMembershipElementExpression
    where Inner: CodexChatRecordEquatableExpression
{
    fileprivate func codexChatMembershipElementExpression() -> CodexChatExpression<CodexChatPredicateValue> {
        let expression = inner.codexChatEquatableExpression()
        return .init(
            evaluate: { record in
                switch expression.evaluate(record) {
                case .optionalString(.some(let value)):
                    return .string(value)
                case .optionalWorkspaceID(.some(let value)):
                    return .workspaceID(value)
                case .optionalSourceKind(.some(let value)):
                    return .sourceKind(value)
                case .optionalString(.none),
                    .optionalWorkspaceID(.none),
                    .optionalSourceKind(.none):
                    return .nilLiteral("membership")
                default:
                    preconditionFailure("CodexChat predicate force-unwrapped an unsupported or nil membership value.")
                }
            },
            signature: expression.signature
        )
    }
}

extension PredicateExpressions.ForcedUnwrap: CodexChatRecordWorkspaceIDExpression
    where Inner: CodexChatRecordOptionalWorkspaceIDExpression, Wrapped == CodexWorkspaceID
{
    fileprivate func codexChatWorkspaceIDExpression() -> CodexChatExpression<CodexWorkspaceID> {
        let expression = inner.codexChatOptionalWorkspaceIDExpression()
        return .init(
            evaluate: { record in
                guard let value = expression.evaluate(record) else {
                    preconditionFailure("CodexChat predicate force-unwrapped nil workspace ID.")
                }
                return value
            },
            signature: expression.signature
        )
    }
}

extension PredicateExpressions.ForcedUnwrap: CodexChatRecordSourceKindExpression
    where Inner: CodexChatRecordOptionalSourceKindExpression, Wrapped == CodexThreadSourceKind
{
    fileprivate func codexChatSourceKindExpression() -> CodexChatExpression<CodexThreadSourceKind> {
        let expression = inner.codexChatOptionalSourceKindExpression()
        return .init(
            evaluate: { record in
                guard let value = expression.evaluate(record) else {
                    preconditionFailure("CodexChat predicate force-unwrapped nil source kind.")
                }
                return value
            },
            signature: expression.signature
        )
    }
}

extension PredicateExpressions.Value: CodexChatRecordBoolExpression where Output == Bool {
    fileprivate func codexChatBoolExpression() -> CodexChatExpression<Bool> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .bool(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordStringExpression where Output == String {
    fileprivate func codexChatStringExpression() -> CodexChatExpression<String> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .string(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordOptionalStringExpression
    where Output == String?
{
    fileprivate func codexChatOptionalStringExpression() -> CodexChatExpression<String?> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .optionalString(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordOptionalWorkspaceIDExpression
    where Output == CodexWorkspaceID?
{
    fileprivate func codexChatOptionalWorkspaceIDExpression() -> CodexChatExpression<CodexWorkspaceID?> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .optionalWorkspaceID(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordOptionalSourceKindExpression
    where Output == CodexThreadSourceKind?
{
    fileprivate func codexChatOptionalSourceKindExpression() -> CodexChatExpression<CodexThreadSourceKind?> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .optionalSourceKind(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordEquatableExpression {
    fileprivate func codexChatEquatableExpression() -> CodexChatExpression<CodexChatPredicateValue> {
        if Output.self == Bool.self {
            let value = value as! Bool
            return .init(evaluate: { _ in .bool(value) }, signature: .bool(value))
        }
        if Output.self == String?.self {
            let value = value as! String?
            return .init(evaluate: { _ in .optionalString(value) }, signature: .optionalString(value))
        }
        if Output.self == String.self {
            let value = value as! String
            return .init(evaluate: { _ in .string(value) }, signature: .string(value))
        }
        if Output.self == CodexWorkspaceID?.self {
            let value = value as! CodexWorkspaceID?
            return .init(
                evaluate: { _ in .optionalWorkspaceID(value) },
                signature: .optionalWorkspaceID(value)
            )
        }
        if Output.self == CodexWorkspaceID.self {
            let value = value as! CodexWorkspaceID
            return .init(evaluate: { _ in .workspaceID(value) }, signature: .workspaceID(value))
        }
        if Output.self == CodexThreadSourceKind?.self {
            let value = value as! CodexThreadSourceKind?
            return .init(
                evaluate: { _ in .optionalSourceKind(value) },
                signature: .optionalSourceKind(value)
            )
        }
        if Output.self == CodexThreadSourceKind.self {
            let value = value as! CodexThreadSourceKind
            return .init(evaluate: { _ in .sourceKind(value) }, signature: .sourceKind(value))
        }
        preconditionFailure("Unsupported CodexChat predicate value: \(value)")
    }
}

extension PredicateExpressions.Value: CodexChatRecordSequenceExpression {
    fileprivate func codexChatSequenceExpression() -> CodexChatExpression<CodexChatSequenceValue> {
        if let value = value as? [String] {
            return .init(evaluate: { _ in .strings(value) }, signature: .stringArray(value))
        }
        if let value = value as? [CodexWorkspaceID] {
            return .init(evaluate: { _ in .workspaceIDs(value) }, signature: .workspaceIDArray(value))
        }
        if let value = value as? [CodexThreadSourceKind] {
            return .init(evaluate: { _ in .sourceKinds(value) }, signature: .sourceKindArray(value))
        }
        preconditionFailure("Unsupported CodexChat predicate sequence value: \(value)")
    }
}

extension PredicateExpressions.NilLiteral: CodexChatRecordEquatableExpression {
    fileprivate func codexChatEquatableExpression() -> CodexChatExpression<CodexChatPredicateValue> {
        .init(
            evaluate: { _ in .nilLiteral(String(describing: Wrapped.self)) },
            signature: .nilLiteral(String(describing: Wrapped.self))
        )
    }
}
