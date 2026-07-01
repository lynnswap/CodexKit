import CodexAppServerKit
import Foundation
import Observation

public protocol CodexPersistentModel: AnyObject, Observable, Hashable, Identifiable, SendableMetatype
where ID: Hashable & Sendable {
    nonisolated var id: ID { get }

    var modelContext: CodexModelContext? { get }
}

extension CodexPersistentModel {
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

public struct CodexWorkspaceID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }
}

private extension Array where Element == CodexChatUpdate {
    mutating func appendIfPresent(_ change: CodexChatUpdate?) {
        if let change {
            append(change)
        }
    }

    var containsTurnItemMutation: Bool {
        contains { $0.affectedTurnID != nil }
    }
}

private struct CodexNarrativeItemSignature: Hashable {
    var kind: CodexThreadItem.Kind
    var text: String
}

private extension CodexThreadItem {
    var isReviewModeMarker: Bool {
        switch kind {
        case .enteredReviewMode, .exitedReviewMode:
            true
        default:
            false
        }
    }

    var duplicateNarrativeSignature: CodexNarrativeItemSignature? {
        guard let text, text.isEmpty == false else {
            return nil
        }
        switch kind {
        case .agentMessage,
            .userMessage,
            .enteredReviewMode,
            .exitedReviewMode,
            .reasoning,
            .diagnostic,
            .error:
            return .init(kind: kind, text: text)
        case .plan,
            .commandExecution,
            .fileChange,
            .mcpToolCall,
            .dynamicToolCall,
            .collabAgentToolCall,
            .subAgentActivity,
            .webSearch,
            .imageView,
            .sleep,
            .imageGeneration,
            .contextCompaction,
            .unknown:
            return nil
        }
    }

    var replayNarrativeSignature: CodexNarrativeItemSignature? {
        switch kind {
        case .reasoning:
            guard let text = reasoningReplaySignatureText else {
                return nil
            }
            return .init(kind: kind, text: text)
        case .enteredReviewMode,
            .exitedReviewMode,
            .diagnostic,
            .error:
            guard let text, text.isEmpty == false else {
                return nil
            }
            return .init(kind: kind, text: text)
        case .agentMessage,
            .userMessage,
            .plan,
            .commandExecution,
            .fileChange,
            .mcpToolCall,
            .dynamicToolCall,
            .collabAgentToolCall,
            .subAgentActivity,
            .webSearch,
            .imageView,
            .sleep,
            .imageGeneration,
            .contextCompaction,
            .unknown:
            return nil
        }
    }

    private var reasoningReplaySignatureText: String? {
        guard case .reasoning(let reasoning) = content else {
            return nil
        }
        let parts = [
            reasoning.summary.joined(separator: "\n"),
            reasoning.content.joined(separator: "\n"),
        ].filter { $0.isEmpty == false }
        guard parts.isEmpty == false else {
            return nil
        }
        return parts.joined(separator: "\u{0}")
    }

    var command: CodexCommand? {
        guard case .command(let command) = content else {
            return nil
        }
        return command
    }
}

public struct CodexWorkspaceGroupID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }
}

public struct CodexChatItemID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawItemID: String, turnID: CodexTurnID?) {
        self.rawValue = Self.scopedRawValue(rawItemID, turnID: turnID)
    }

    public var description: String {
        rawValue
    }

    fileprivate static func scopedRawValue(
        _ value: String,
        turnID: CodexTurnID?
    ) -> String {
        guard let turnID else {
            return value
        }
        return "\(turnID.rawValue):\(value)"
    }
}

public struct CodexChatInput: Sendable {
    public var instructions: CodexInstructions?
    public var options: CodexThread.Options

    public init(
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init()
    ) {
        self.instructions = instructions
        self.options = options
    }
}

public struct CodexReviewInput: Sendable {
    public var target: CodexReviewTarget
    public var instructions: CodexInstructions?
    public var options: CodexThread.Options
    public var delivery: CodexReviewDelivery
    public var transcriptErrorHandlingPolicy: CodexTranscriptErrorHandlingPolicy

    public init(
        target: CodexReviewTarget,
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init(),
        delivery: CodexReviewDelivery = .inline,
        transcriptErrorHandlingPolicy: CodexTranscriptErrorHandlingPolicy = .preserveTranscript
    ) {
        self.target = target
        self.instructions = instructions
        self.options = options
        self.delivery = delivery
        self.transcriptErrorHandlingPolicy = transcriptErrorHandlingPolicy
    }
}

public struct CodexStartedReview {
    public let chat: CodexChat
    public let session: CodexReviewSession

    public init(chat: CodexChat, session: CodexReviewSession) {
        self.chat = chat
        self.session = session
    }
}

public struct CodexChatMessageInput: Sendable {
    public var prompt: CodexPrompt
    public var options: CodexGenerationOptions

    public init(
        _ text: String,
        options: CodexGenerationOptions = .init()
    ) {
        self.prompt = CodexPrompt(text)
        self.options = options
    }

    public init(
        prompt: CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) {
        self.prompt = prompt
        self.options = options
    }
}

@Observable
public final class CodexWorkspaceGroup: CodexPersistentModel {
    public let id: CodexWorkspaceGroupID
    public private(set) var name: String
    public private(set) var workspaces: [CodexWorkspace]

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    package init(
        id: CodexWorkspaceGroupID,
        name: String,
        modelContext: CodexModelContext
    ) {
        self.id = id
        self.name = name
        self.workspaces = []
        self.modelContext = modelContext
    }

    package func applyContextSnapshot(name: String) {
        self.name = name
    }

    package func replaceContextWorkspaces(_ workspaces: [CodexWorkspace]) {
        self.workspaces = workspaces
    }

}

private extension CodexTurnStatus {
    var isTerminal: Bool {
        switch self {
        case .running, .unknown:
            false
        case .completed, .failed, .interrupted, .cancelled:
            true
        }
    }
}

@Observable
public final class CodexWorkspace: CodexPersistentModel {
    public let id: CodexWorkspaceID
    public private(set) var url: URL
    public private(set) var name: String
    public private(set) var chats: [CodexChat]

    public private(set) weak var workspaceGroup: CodexWorkspaceGroup?

    public var workspaceGroupID: CodexWorkspaceGroupID? {
        workspaceGroup?.id
    }

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    package init(
        id: CodexWorkspaceID,
        url: URL,
        name: String,
        workspaceGroup: CodexWorkspaceGroup?,
        modelContext: CodexModelContext
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.workspaceGroup = workspaceGroup
        self.chats = []
        self.modelContext = modelContext
    }

    package func applyContextSnapshot(
        url: URL,
        name: String,
        workspaceGroup: CodexWorkspaceGroup?
    ) {
        self.url = url
        self.name = name
        self.workspaceGroup = workspaceGroup
    }

    package func replaceContextChats(_ chats: [CodexChat]) {
        self.chats = chats
    }

    package func attachContextChatIfNeeded(_ chat: CodexChat) {
        guard chats.contains(where: { $0 === chat }) == false else {
            return
        }
        chats.append(chat)
    }

    package func moveContextChatToFront(_ chat: CodexChat) {
        chats.removeAll { $0 === chat }
        chats.insert(chat, at: 0)
    }

    @discardableResult
    public nonisolated(nonsending) func startChat(
        _ input: CodexChatInput = .init()
    ) async throws -> CodexChat {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await modelContext.startChat(in: self, input: input)
    }

    @discardableResult
    public nonisolated(nonsending) func startReview(
        _ input: CodexReviewInput
    ) async throws -> CodexStartedReview {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await modelContext.startReview(in: self, input: input)
    }
}

@Observable
public final class CodexTurn: CodexPersistentModel {
    public let id: CodexTurnID
    public var status: CodexTurnStatus?
    public var errorDescription: String?
    public var itemsLoadState: CodexTurnItemsLoadState
    public var usage: CodexTokenUsage?
    public private(set) var items: [CodexItem]

    public private(set) weak var chat: CodexChat?

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    package init(
        id: CodexTurnID,
        chat: CodexChat,
        modelContext: CodexModelContext,
        status: CodexTurnStatus? = nil,
        errorDescription: String? = nil,
        itemsLoadState: CodexTurnItemsLoadState? = nil,
        usage: CodexTokenUsage? = nil
    ) {
        self.id = id
        self.chat = chat
        self.modelContext = modelContext
        self.status = status
        self.errorDescription = errorDescription
        self.itemsLoadState = itemsLoadState ?? .notLoaded
        self.usage = usage
        self.items = []
    }

    package func applyContextChat(_ chat: CodexChat) {
        self.chat = chat
    }

    package func replaceContextItems(_ items: [CodexItem]) {
        self.items = items
    }

    package func attachContextItemIfNeeded(_ item: CodexItem) {
        guard items.contains(where: { $0 === item }) == false else {
            return
        }
        items.append(item)
    }

    package func detachContextItem(_ item: CodexItem) {
        items.removeAll { $0 === item }
    }
}

@Observable
public final class CodexItem: CodexPersistentModel {
    public let id: CodexChatItemID
    public private(set) var itemID: String
    public fileprivate(set) var itemsLoadState: CodexTurnItemsLoadState
    public var kind: CodexThreadItem.Kind
    public var content: CodexThreadItem.Content
    public var rawPayload: Data?

    public private(set) weak var chat: CodexChat?
    public private(set) weak var turn: CodexTurn?

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    public var turnID: CodexTurnID? {
        turn?.id
    }

    public var text: String? {
        threadItem.text
    }

    public var message: CodexMessage? {
        threadItem.message
    }

    public var reasoning: CodexReasoning? {
        if case .reasoning(let reasoning) = content {
            return reasoning
        }
        return nil
    }

    fileprivate var threadItem: CodexThreadItem {
        CodexThreadItem(id: itemID, kind: kind, content: content, rawPayload: rawPayload)
    }

    fileprivate var mergeKey: CodexChatItemKey {
        .init(id: itemID, kind: kind, turnID: turnID)
    }

    package init(
        threadItem: CodexThreadItem,
        chat: CodexChat,
        turn: CodexTurn?,
        modelContext: CodexModelContext,
        itemsLoadState: CodexTurnItemsLoadState
    ) {
        self.id = CodexChatItemKey(threadItem: threadItem, turnID: turn?.id).modelID
        self.itemID = threadItem.id
        self.chat = chat
        self.turn = turn
        self.modelContext = modelContext
        self.itemsLoadState = itemsLoadState
        self.kind = threadItem.kind
        self.content = threadItem.content
        self.rawPayload = threadItem.rawPayload
    }

    package func applyContextOwners(chat: CodexChat, turn: CodexTurn?) {
        self.chat = chat
        self.turn = turn
    }

    package func detachFromContext() {
        chat = nil
        turn = nil
        modelContext = nil
    }

    fileprivate func update(
        from threadItem: CodexThreadItem,
        itemsLoadState: CodexTurnItemsLoadState
    ) {
        itemID = threadItem.id
        self.itemsLoadState = itemsLoadState
        kind = threadItem.kind
        content = threadItem.content
        rawPayload = threadItem.rawPayload
    }
}

package struct CodexChatItemKey: Hashable {
    var id: String
    var semanticID: String
    var turnID: CodexTurnID?

    init(id: String, kind: CodexThreadItem.Kind? = nil, turnID: CodexTurnID?) {
        self.id = id
        self.semanticID = Self.semanticID(rawItemID: id, kind: kind)
        self.turnID = turnID
    }

    init(threadItem: CodexThreadItem, turnID: CodexTurnID?) {
        self.init(id: threadItem.id, kind: threadItem.kind, turnID: turnID)
    }

    var modelID: CodexChatItemID {
        CodexChatItemID(rawItemID: semanticID, turnID: turnID)
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.semanticID == rhs.semanticID && lhs.turnID == rhs.turnID
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(semanticID)
        hasher.combine(turnID)
    }

    private static func semanticID(
        rawItemID: String,
        kind: CodexThreadItem.Kind?
    ) -> String {
        switch kind {
        case .enteredReviewMode:
            "review-marker:enteredReviewMode"
        case .exitedReviewMode:
            "review-marker:exitedReviewMode"
        default:
            rawItemID
        }
    }
}

@Observable
public final class CodexChat: CodexPersistentModel {
    public let id: CodexThreadID
    public private(set) var name: String?
    public private(set) var preview: String?
    public private(set) var modelProvider: String?
    public private(set) var isArchived: Bool
    public private(set) var createdAt: Date?
    public private(set) var updatedAt: Date?
    public private(set) var recencyAt: Date?
    public private(set) var status: CodexThreadStatus?
    public private(set) var ephemeral: Bool?
    public private(set) var turns: [CodexTurn]
    public private(set) var items: [CodexItem]
    public var phase: CodexDataPhase = .idle
    public var lastErrorDescription: String?

    public private(set) weak var workspace: CodexWorkspace?

    public var workspaceID: CodexWorkspaceID? {
        workspace?.id
    }

    public var workspaceGroupID: CodexWorkspaceGroupID? {
        workspace?.workspaceGroupID
    }

    @ObservationIgnored
    private var liveMergeState = LiveMergeState()
    @ObservationIgnored
    private var hasAppliedLiveTurnItemUpdates = false
    @ObservationIgnored
    private var preservesSeededMetadataUntilAuthoritativeSnapshot = false
    @ObservationIgnored
    private var turnsByID: [CodexTurnID: CodexTurn] = [:]
    @ObservationIgnored
    private var itemsByMergeKey: [CodexChatItemKey: CodexItem] = [:]
    @ObservationIgnored
    private var itemsByTurnID: [CodexTurnID: [CodexItem]] = [:]
    @ObservationIgnored
    private var provisionalSeedTurnID: CodexTurnID?

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    public var title: String {
        if let name, name.isEmpty == false {
            return name
        }
        if let preview, preview.isEmpty == false {
            return preview
        }
        if let workspace {
            return workspace.name
        }
        return id.rawValue
    }

    public var transcript: CodexTranscript {
        .init(items: items.map(\.threadItem))
    }

    public func turn(id: CodexTurnID) -> CodexTurn? {
        // Keep Observation dependency tracking on the ordered current value while
        // serving the lookup from the ignored index.
        _ = turns
        return turnsByID[id]
    }

    public func items(in turnID: CodexTurnID) -> [CodexItem] {
        // Keep Observation dependency tracking on the ordered current value while
        // serving the scoped lookup from the ignored index.
        _ = items
        return itemsByTurnID[turnID] ?? []
    }

    package init(
        id: CodexThreadID,
        modelContext: CodexModelContext
    ) {
        self.id = id
        self.turns = []
        self.items = []
        self.isArchived = false
        self.modelContext = modelContext
    }

    package func apply(
        _ snapshot: CodexThreadSnapshot,
        workspace: CodexWorkspace?,
        preservesExistingTurnItems: Bool = false
    ) {
        if snapshot.hasField(.workspace) {
            self.workspace = workspace
        }
        let receivedAuthoritativeTitleMetadata =
            (snapshot.hasField(.name) && snapshot.name?.isEmpty == false)
            || (snapshot.hasField(.preview) && snapshot.preview?.isEmpty == false)
        if snapshot.hasField(.name), shouldApplyOptionalMetadata(snapshot.name, existing: name) {
            name = snapshot.name
        }
        if snapshot.hasField(.preview), shouldApplyOptionalMetadata(snapshot.preview, existing: preview) {
            preview = snapshot.preview
        }
        if snapshot.hasField(.modelProvider),
            shouldApplyOptionalMetadata(snapshot.modelProvider, existing: modelProvider)
        {
            modelProvider = snapshot.modelProvider
        }
        if receivedAuthoritativeTitleMetadata {
            preservesSeededMetadataUntilAuthoritativeSnapshot = false
        }
        if snapshot.hasField(.createdAt) {
            createdAt = snapshot.createdAt
        }
        if snapshot.hasField(.updatedAt) {
            updatedAt = snapshot.updatedAt
        }
        if snapshot.hasField(.recencyAt) {
            recencyAt = snapshot.recencyAt
        }
        if snapshot.hasField(.status) {
            status = snapshot.status
        }
        if snapshot.hasField(.ephemeral) {
            ephemeral = snapshot.ephemeral
        }
        if let turns = snapshot.turns {
            let turns = normalizedIncomingTurnRecords(turns)
            if snapshot.turnItemsAreAuthoritative && preservesExistingTurnItems == false {
                replaceTurns(with: turns)
                replaceItems(with: turns)
                hasAppliedLiveTurnItemUpdates = false
            } else {
                mergeTurns(with: turns)
                mergeItems(from: turns)
            }
            for turn in turns {
                if let status = turn.status, status.isTerminal {
                    _ = terminalizeActiveItems(in: turn.id, status: status, completedAt: updatedAt)
                }
            }
        }
        if snapshot.hasField(.status) {
            _ = terminalizeActiveTurns(for: snapshot.status, completedAt: updatedAt)
        }
    }

    package func applyContextArchived(_ isArchived: Bool) {
        self.isArchived = isArchived
    }

    package func preserveSeededMetadataUntilAuthoritativeSnapshot() {
        preservesSeededMetadataUntilAuthoritativeSnapshot = true
    }

    package func markProvisionalSeedTurn(_ turnID: CodexTurnID?) {
        provisionalSeedTurnID = turnID
    }

    package func detachFromContext() {
        workspace = nil
        modelContext = nil
    }

    package func detachFromWorkspace(_ workspace: CodexWorkspace) {
        if self.workspace === workspace {
            self.workspace = nil
        }
    }

    public nonisolated(nonsending) func observe(
        includeTurns: Bool = true
    ) async throws -> CodexChatObservation {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await modelContext.observe(self, includeTurns: includeTurns)
    }

    private func shouldApplyOptionalMetadata<Value>(_ incoming: Value?, existing: Value?) -> Bool {
        incoming != nil || preservesSeededMetadataUntilAuthoritativeSnapshot == false || existing == nil
    }

    @discardableResult
    public nonisolated(nonsending) func send(
        _ input: CodexChatMessageInput
    ) async throws -> CodexResponse {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        phase = .loading
        lastErrorDescription = nil
        do {
            let response = try await modelContext.send(input, in: self)
            await modelContext.syncPhaseAfterSend(in: self)
            return response
        } catch {
            if input.options.transcriptErrorHandlingPolicy != .revertTranscript,
                let response = (error as? CodexAppServerError)?.response
            {
                await modelContext.apply(response, to: self)
            }
            fail(with: error)
            throw error
        }
    }

    @discardableResult
    public nonisolated(nonsending) func send(
        _ text: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        try await send(.init(text, options: options))
    }

    public nonisolated(nonsending) func cancel() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.cancelActiveTurn(in: self)
    }

    public nonisolated(nonsending) func archive() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.archive(self)
    }

    public nonisolated(nonsending) func unarchive() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.unarchive(self)
    }

    public nonisolated(nonsending) func delete() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.delete(self)
    }

    private func contextTurn(
        id: CodexTurnID,
        status: CodexTurnStatus? = nil,
        errorDescription: String? = nil,
        itemsLoadState: CodexTurnItemsLoadState? = nil,
        usage: CodexTokenUsage? = nil
    ) -> CodexTurn {
        guard let modelContext else {
            preconditionFailure("CodexChat is detached from its CodexModelContext.")
        }
        return modelContext.turn(
            id: id,
            in: self,
            status: status,
            errorDescription: errorDescription,
            itemsLoadState: itemsLoadState,
            usage: usage
        )
    }

    private func contextItem(
        threadItem: CodexThreadItem,
        turnID: CodexTurnID?,
        itemsLoadState: CodexTurnItemsLoadState
    ) -> CodexItem {
        guard let modelContext else {
            preconditionFailure("CodexChat is detached from its CodexModelContext.")
        }
        return modelContext.item(
            threadItem: threadItem,
            turnID: turnID,
            in: self,
            itemsLoadState: itemsLoadState
        )
    }

    private func replaceTurns(with records: [CodexTurnSnapshot]) {
        provisionalSeedTurnID = nil
        let existingByID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        turns = records.map { record in
            let turn = existingByID[record.id] ?? contextTurn(id: record.id)
            turn.status = record.status
            turn.errorDescription = record.errorMessage
            turn.itemsLoadState = record.itemsLoadState
            return turn
        }
        rebuildTurnIndex()
    }

    private func normalizedIncomingTurnRecords(
        _ records: [CodexTurnSnapshot]
    ) -> [CodexTurnSnapshot] {
        let records = recordsByRemovingReplacedProvisionalSeed(records).map { record in
            var record = record
            record.items = itemsByCoalescingDuplicateNarrativeItems(record.items)
            return record
        }
        return recordsByCoalescingReplayNarrativeItems(records)
    }

    private func recordsByRemovingReplacedProvisionalSeed(
        _ records: [CodexTurnSnapshot]
    ) -> [CodexTurnSnapshot] {
        guard let provisionalTurnID = provisionalSeedTurnID else {
            return records
        }
        guard records.contains(where: { record in
            record.id != provisionalTurnID && record.items.contains(where: \.isReviewModeMarker)
        }) else {
            return records
        }
        _ = removeProvisionalSeedTurn(provisionalTurnID)
        return records.filter { $0.id != provisionalTurnID }
    }

    private func itemsByCoalescingDuplicateNarrativeItems(
        _ incomingItems: [CodexThreadItem]
    ) -> [CodexThreadItem] {
        var seenSignatures = Set<CodexNarrativeItemSignature>()
        var items: [CodexThreadItem] = []
        items.reserveCapacity(incomingItems.count)
        for item in incomingItems {
            guard let signature = item.duplicateNarrativeSignature else {
                items.append(item)
                continue
            }
            guard seenSignatures.insert(signature).inserted else {
                continue
            }
            items.append(item)
        }
        return items
    }

    private func recordsByCoalescingReplayNarrativeItems(
        _ records: [CodexTurnSnapshot]
    ) -> [CodexTurnSnapshot] {
        var seenSignatures = Set<CodexNarrativeItemSignature>()
        return records.map { record in
            var record = record
            record.items = record.items.filter { item in
                guard let signature = item.replayNarrativeSignature else {
                    return true
                }
                return seenSignatures.insert(signature).inserted
            }
            return record
        }
    }

    private func mergeTurns(with records: [CodexTurnSnapshot]) {
        for record in records {
            upsertTurn(
                id: record.id,
                status: record.status,
                errorDescription: record.errorMessage,
                itemsLoadState: record.itemsLoadState,
                preservesExistingUsage: true
            )
        }
    }

    private func replaceItems(with records: [CodexTurnSnapshot]) {
        let existingByKey = itemsByMergeKey
        let previousItems = items
        items = records.flatMap { record in
            record.items.map { incomingItem in
                let incomingKey = CodexChatItemKey(
                    threadItem: incomingItem,
                    turnID: record.id
                )
                let turn = contextTurn(id: record.id)
                if let existing = existingByKey[incomingKey] {
                    existing.applyContextOwners(chat: self, turn: turn)
                    existing.update(
                        from: incomingItem,
                        itemsLoadState: record.itemsLoadState
                    )
                    return existing
                }
                return contextItem(
                    threadItem: incomingItem,
                    turnID: record.id,
                    itemsLoadState: record.itemsLoadState
                )
            }
        }
        let retainedItems = Set(items.map(ObjectIdentifier.init))
        let removedItems = previousItems.filter {
            retainedItems.contains(ObjectIdentifier($0)) == false
        }
        unregisterItemsFromContext(removedItems)
        rebuildItemIndexes()
    }

    private func mergeItems(from records: [CodexTurnSnapshot]) {
        for record in records {
            if record.itemsAreAuthoritative {
                removeNonAuthoritativeItems(in: record.id)
            }
            guard record.items.isEmpty == false else {
                continue
            }
            mergeItems(
                record.items,
                turnID: record.id,
                itemsLoadState: record.itemsLoadState
            )
        }
    }

    @discardableResult
    private func upsertTurn(
        id: CodexTurnID,
        status: CodexTurnStatus?,
        errorDescription: String?,
        itemsLoadState: CodexTurnItemsLoadState? = nil,
        usage: CodexTokenUsage? = nil,
        preservesExistingUsage: Bool = false
    ) -> CodexChatUpdate? {
        if let turn = turnsByID[id] {
            let previousStatus = turn.status
            let previousErrorDescription = turn.errorDescription
            let previousUsage = turn.usage
            let previousItemsLoadState = turn.itemsLoadState
            turn.status = status
            turn.errorDescription = errorDescription
            if let itemsLoadState {
                turn.itemsLoadState = itemsLoadState
            }
            if preservesExistingUsage == false || usage != nil {
                turn.usage = usage
            }
            guard turn.status != previousStatus
                || turn.errorDescription != previousErrorDescription
                || turn.usage != previousUsage
                || turn.itemsLoadState != previousItemsLoadState
            else {
                return nil
            }
            return .turnUpdated(id: turn.id)
        } else {
            let turn = contextTurn(
                id: id,
                status: status,
                errorDescription: errorDescription,
                itemsLoadState: itemsLoadState,
                usage: usage
            )
            turns.append(turn)
            turnsByID[turn.id] = turn
            return .turnInserted(id: turn.id)
        }
    }

    @discardableResult
    package func apply(_ response: CodexResponse) -> [CodexChatUpdate] {
        let previousPhase = phase
        var changes: [CodexChatUpdate] = []
        if let completedAt = response.completedAt,
            updatedAt.map({ completedAt > $0 }) ?? true
        {
            updatedAt = completedAt
        }
        changes.appendIfPresent(upsertTurn(
            id: response.turnID,
            status: response.status,
            errorDescription: response.errorMessage,
            usage: response.usage,
            preservesExistingUsage: true
        ))
        changes.append(contentsOf: mergeItems(response.transcript.items, turnID: response.turnID))
        if let status = response.status, status.isTerminal {
            changes.append(contentsOf: terminalizeActiveItems(
                in: response.turnID,
                status: status,
                completedAt: response.completedAt
            ))
        }
        changes.appendIfPresent(markIdleIfActive())
        appendPhaseChange(to: &changes, previousPhase: previousPhase)
        markAppliedLiveTurnItemUpdatesIfNeeded(changes)
        return changes
    }

    @discardableResult
    package func apply(_ event: CodexThreadEvent) -> [CodexChatUpdate] {
        let previousPhase = phase
        var changes: [CodexChatUpdate] = []
        switch event {
        case .turnStarted(let turnID):
            removeProvisionalSeedTurnIfNeeded(for: turnID, into: &changes)
            changes.appendIfPresent(upsertTurn(
                id: turnID,
                status: .running,
                errorDescription: nil,
                preservesExistingUsage: true
            ))
            changes.appendIfPresent(markRunningIfNeeded())
            lastErrorDescription = nil
        case .turnCompleted(let response):
            changes.append(contentsOf: apply(response))
            changes.appendIfPresent(markIdleIfActive())
            if response.errorMessage != nil || response.status?.isFailure == true {
                let message = response.errorMessage ?? response.status?.rawValue ?? "Turn failed"
                fail(with: message)
            } else {
                phase = .loaded
                lastErrorDescription = nil
            }
        case .turnFailed(let turnID, let message):
            if let turnID {
                changes.appendIfPresent(upsertTurn(
                    id: turnID,
                    status: .failed,
                    errorDescription: message,
                    preservesExistingUsage: true
                ))
                changes.append(contentsOf: terminalizeActiveItems(
                    in: turnID,
                    status: .failed,
                    completedAt: Date()
                ))
            }
            changes.appendIfPresent(markIdleIfActive())
            fail(with: message)
        case .itemStarted(let item, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: mergeItems([
                itemByApplyingLifecycleStatus(.running, to: item),
            ], turnID: turnID))
            changes.appendIfPresent(markRunningIfNeeded())
        case .itemCompleted(let item, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: mergeItems([
                itemByApplyingLifecycleStatus(.completed, to: item),
            ], turnID: turnID))
        case .itemUpdated(let item, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: mergeItems(
                [item],
                turnID: turnID,
                accumulatesOutputDeltas: isOutputDeltaUpdate(item)
            ))
            changes.appendIfPresent(markRunningIfNeeded())
        case .message(let message, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            let item = CodexThreadItem(
                id: message.id,
                kind: message.role == .user ? .userMessage : .agentMessage,
                content: .message(message)
            )
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: mergeItems([item], turnID: turnID))
            changes.appendIfPresent(markRunningIfNeeded())
        case .messageDelta(let delta, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                incomingKey: CodexChatItemKey(
                    id: delta.itemID ?? scopedFallbackMessageID(turnID: turnID),
                    kind: .agentMessage,
                    turnID: turnID
                ),
                turnID: turnID
            ))
            changes.append(contentsOf: merge(delta, turnID: turnID))
            changes.appendIfPresent(markRunningIfNeeded())
        case .reasoningSummaryPartAdded(let part, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            let item = CodexThreadItem(id: part.id, kind: .reasoning, content: .reasoning(.empty))
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: start(part, turnID: turnID))
            changes.appendIfPresent(markRunningIfNeeded())
        case .reasoningDelta(let delta, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                incomingKey: reasoningMergeKey(for: delta, turnID: turnID),
                turnID: turnID
            ))
            changes.append(contentsOf: merge(delta, turnID: turnID))
            changes.appendIfPresent(markRunningIfNeeded())
        case .tokenUsageUpdated(let usage, let turnID):
            if let turnID {
                changes.appendIfPresent(setUsage(usage, for: turnID))
            }
        case .statusChanged(let status):
            switch status {
            case .active, .unknown:
                changes.appendIfPresent(setStatus(status))
                changes.appendIfPresent(markRunningIfNeeded())
            case .notLoaded, .idle, .systemError:
                changes.appendIfPresent(setStatus(status))
                changes.append(contentsOf: terminalizeActiveTurns(
                    for: status,
                    completedAt: updatedAt
                ))
                markLoadedIfNotFailed()
            }
        case .closed:
            changes.appendIfPresent(setStatus(.notLoaded))
            changes.append(contentsOf: terminalizeActiveTurns(
                status: .completed,
                completedAt: updatedAt
            ))
            markLoadedIfNotFailed()
        case .unknown:
            break
        }
        appendPhaseChange(to: &changes, previousPhase: previousPhase)
        markAppliedLiveTurnItemUpdatesIfNeeded(changes)
        return changes
    }

    package var shouldPreserveTurnItemsWhenReconcilingSnapshot: Bool {
        hasAppliedLiveTurnItemUpdates
    }

    private func markAppliedLiveTurnItemUpdatesIfNeeded(_ changes: [CodexChatUpdate]) {
        guard changes.containsTurnItemMutation else {
            return
        }
        hasAppliedLiveTurnItemUpdates = true
    }

    @discardableResult
    private func mergeItems(
        _ incomingItems: [CodexThreadItem],
        turnID: CodexTurnID?,
        itemsLoadState: CodexTurnItemsLoadState = .full,
        accumulatesOutputDeltas: Bool = false
    ) -> [CodexChatUpdate] {
        guard incomingItems.isEmpty == false else {
            return []
        }
        var changes: [CodexChatUpdate] = []
        for incomingItem in incomingItems {
            if incomingItem.kind == .reasoning && incomingItem.id.contains(":summary:") == false
                && incomingItem.id.contains(":content:") == false
            {
                changes.append(contentsOf: removeReasoningParts(parentItemID: incomingItem.id))
            }
            let incomingKey = CodexChatItemKey(
                threadItem: incomingItem,
                turnID: turnID
            )
            let directlyMatchedItem = item(for: incomingKey)
            if let existing = directlyMatchedItem,
                isDuplicateNarrativeReplay(incomingItem, replacing: existing.threadItem)
            {
                continue
            }
            if directlyMatchedItem == nil,
                hasNarrativeItem(matching: incomingItem, turnID: turnID)
            {
                continue
            }
            if directlyMatchedItem == nil,
                hasReplayNarrativeItem(matching: incomingItem)
            {
                continue
            }
            let indexedItem = itemsByMergeKey[incomingKey]
            let replayItem = indexedItem == nil
                ? commandReplayItem(matching: incomingItem, turnID: turnID)
                : nil
            let existingItem = indexedItem ?? replayItem
            if let existing = existingItem
            {
                let previousItem = existing.threadItem
                let previousMergeKey = existing.mergeKey
                let previousTurnID = existing.turnID
                let incomingItem = itemByPreservingExistingLifecycle(
                    from: incomingItem,
                    existing: previousItem
                )
                let movesAcrossTurns = previousTurnID != turnID
                if movesAcrossTurns {
                    let replacementItem: CodexThreadItem
                    if accumulatesOutputDeltas,
                        mergeOutputDelta(incomingItem, into: existing, key: previousMergeKey)
                    {
                        replacementItem = existing.threadItem
                    } else {
                        replacementItem = incomingItem
                    }
                    let replacement = replaceItemAcrossTurns(
                        existing,
                        with: replacementItem,
                        turnID: turnID,
                        itemsLoadState: itemsLoadState
                    )
                    changes.append(.itemRemoved(id: previousItem.id, turnID: previousTurnID))
                    changes.append(.itemInserted(id: replacement.itemID, turnID: replacement.turnID))
                    continue
                }
                let updateChange: CodexChatUpdate?
                if accumulatesOutputDeltas,
                    mergeOutputDelta(incomingItem, into: existing, key: previousMergeKey)
                {
                    updateChange = changeForUpdatedItem(
                        existing,
                        previousItem: previousItem
                    )
                } else {
                    existing.update(
                        from: incomingItem,
                        itemsLoadState: itemsLoadState
                    )
                    updateChange = changeForUpdatedItem(
                        existing,
                        previousItem: previousItem
                    )
                }
                if existing.mergeKey != previousMergeKey {
                    rebuildItemIndexes()
                    changes.appendIfPresent(updateChange)
                } else {
                    changes.appendIfPresent(updateChange)
                }
            } else {
                if accumulatesOutputDeltas {
                    seedOutputDeltaStateIfNeeded(incomingItem, key: incomingKey)
                }
                let item = contextItem(
                    threadItem: incomingItem,
                    turnID: turnID,
                    itemsLoadState: itemsLoadState
                )
                appendItem(item)
                changes.append(.itemInserted(id: item.itemID, turnID: item.turnID))
            }
        }
        return changes
    }

    private func isDuplicateNarrativeReplay(
        _ incomingItem: CodexThreadItem,
        replacing existingItem: CodexThreadItem
    ) -> Bool {
        guard let incomingSignature = incomingItem.duplicateNarrativeSignature else {
            return false
        }
        return existingItem.duplicateNarrativeSignature == incomingSignature
    }

    private func hasNarrativeItem(
        matching incomingItem: CodexThreadItem,
        turnID: CodexTurnID?
    ) -> Bool {
        guard let incomingSignature = incomingItem.duplicateNarrativeSignature else {
            return false
        }
        if let turnID {
            return itemsByTurnID[turnID]?.contains {
                $0.threadItem.duplicateNarrativeSignature == incomingSignature
            } == true
        } else {
            return items.contains {
                $0.turnID == nil && $0.threadItem.duplicateNarrativeSignature == incomingSignature
            }
        }
    }

    private func hasReplayNarrativeItem(
        matching incomingItem: CodexThreadItem
    ) -> Bool {
        guard let incomingSignature = incomingItem.replayNarrativeSignature else {
            return false
        }
        return items.contains {
            $0.threadItem.replayNarrativeSignature == incomingSignature
        }
    }

    private func commandReplayItem(
        matching incomingItem: CodexThreadItem,
        turnID: CodexTurnID?
    ) -> CodexItem? {
        guard let incomingCommand = incomingItem.command else {
            return nil
        }
        let sameTurnCandidates: [CodexItem]
        if let turnID {
            sameTurnCandidates = itemsByTurnID[turnID] ?? []
        } else {
            sameTurnCandidates = items.filter { $0.turnID == nil }
        }
        if let sameTurnReplay = sameTurnCandidates.first(where: { item in
            guard let existingCommand = item.threadItem.command else {
                return false
            }
            guard existingCommand.status?.isTerminal != true else {
                return false
            }
            return commandsMatchForReplay(existingCommand, incomingCommand)
        }) {
            return sameTurnReplay
        }
        return items.first { item in
            guard item.turnID != turnID else {
                return false
            }
            guard let existingCommand = item.threadItem.command else {
                return false
            }
            guard existingCommand.status?.isTerminal != true else {
                return false
            }
            guard commandsMatchForReplay(existingCommand, incomingCommand) else {
                return false
            }
            return commandsShareReplayIdentity(
                existingItemID: item.itemID,
                existingCommand: existingCommand,
                incomingItemID: incomingItem.id,
                incomingCommand: incomingCommand
            )
        }
    }

    private func commandsMatchForReplay(
        _ existingCommand: CodexCommand,
        _ incomingCommand: CodexCommand
    ) -> Bool {
        guard existingCommand.command == incomingCommand.command else {
            return false
        }
        if let existingCWD = existingCommand.cwd,
            let incomingCWD = incomingCommand.cwd,
            existingCWD != incomingCWD
        {
            return false
        }
        if let existingProcessID = existingCommand.processID,
            let incomingProcessID = incomingCommand.processID,
            existingProcessID != incomingProcessID
        {
            return false
        }
        return existingCommand.source == incomingCommand.source
            || existingCommand.source == nil
            || incomingCommand.source == nil
    }

    private func commandsShareReplayIdentity(
        existingItemID: String,
        existingCommand: CodexCommand,
        incomingItemID: String,
        incomingCommand: CodexCommand
    ) -> Bool {
        if existingItemID == incomingItemID {
            return true
        }
        if let existingProcessID = existingCommand.processID,
            let incomingProcessID = incomingCommand.processID,
            existingProcessID == incomingProcessID
        {
            return true
        }
        return false
    }

    private func itemByApplyingLifecycleStatus(
        _ status: CodexTurnStatus,
        to item: CodexThreadItem
    ) -> CodexThreadItem {
        let content: CodexThreadItem.Content
        switch item.content {
        case .command(var command):
            if status.isTerminal {
                command.status = lifecycleStatus(for: command, fallback: status)
            } else {
                command.status = command.status ?? lifecycleStatus(for: command, fallback: status)
            }
            content = .command(command)
        case .fileChange(var fileChange):
            fileChange.status = status.isTerminal ? status : fileChange.status ?? status
            content = .fileChange(fileChange)
        case .toolCall(var toolCall):
            toolCall.status = status.isTerminal ? status : toolCall.status ?? status
            content = .toolCall(toolCall)
        default:
            return item
        }
        return itemByReplacingContent(in: item, with: content)
    }

    private func itemByPreservingExistingLifecycle(
        from incomingItem: CodexThreadItem,
        existing existingItem: CodexThreadItem
    ) -> CodexThreadItem {
        let content: CodexThreadItem.Content
        switch (incomingItem.content, existingItem.content) {
        case (.command(var incomingCommand), .command(let existingCommand)):
            incomingCommand.status = mergedLifecycleStatus(
                incoming: incomingCommand.status,
                existing: existingCommand.status
            )
            incomingCommand.startedAt = incomingCommand.startedAt ?? existingCommand.startedAt
            incomingCommand.completedAt = incomingCommand.completedAt ?? existingCommand.completedAt
            incomingCommand.duration = incomingCommand.duration ?? existingCommand.duration
            incomingCommand.cwd = incomingCommand.cwd ?? existingCommand.cwd
            incomingCommand.processID = incomingCommand.processID ?? existingCommand.processID
            incomingCommand.source = incomingCommand.source ?? existingCommand.source
            if incomingCommand.commandActions.isEmpty {
                incomingCommand.commandActions = existingCommand.commandActions
            }
            content = .command(incomingCommand)
        case (.fileChange(var incomingFileChange), .fileChange(let existingFileChange)):
            incomingFileChange.status = mergedLifecycleStatus(
                incoming: incomingFileChange.status,
                existing: existingFileChange.status
            )
            content = .fileChange(incomingFileChange)
        case (.toolCall(var incomingToolCall), .toolCall(let existingToolCall)):
            incomingToolCall.status = mergedLifecycleStatus(
                incoming: incomingToolCall.status,
                existing: existingToolCall.status
            )
            content = .toolCall(incomingToolCall)
        default:
            return incomingItem
        }
        return itemByReplacingContent(in: incomingItem, with: content)
    }

    private func mergedLifecycleStatus(
        incoming: CodexTurnStatus?,
        existing: CodexTurnStatus?
    ) -> CodexTurnStatus? {
        guard let incoming else {
            return existing
        }
        if existing?.isTerminal == true, incoming.isTerminal == false {
            return existing
        }
        return incoming
    }

    private func terminalizeActiveItems(
        in turnID: CodexTurnID,
        status: CodexTurnStatus,
        completedAt: Date?
    ) -> [CodexChatUpdate] {
        guard status.isTerminal else {
            return []
        }
        var changes: [CodexChatUpdate] = []
        for item in itemsByTurnID[turnID] ?? [] {
            let previousItem = item.threadItem
            let terminalItem = itemByApplyingTerminalLifecycleStatus(
                status,
                completedAt: terminalCompletionDate(
                    preferred: completedAt,
                    for: previousItem
                ),
                to: previousItem
            )
            guard terminalItem != previousItem else {
                continue
            }
            item.update(from: terminalItem, itemsLoadState: item.itemsLoadState)
            changes.appendIfPresent(changeForUpdatedItem(item, previousItem: previousItem))
        }
        return changes
    }

    private func terminalizeActiveTurns(
        for threadStatus: CodexThreadStatus?,
        completedAt: Date?
    ) -> [CodexChatUpdate] {
        guard let status = terminalTurnStatus(for: threadStatus) else {
            return []
        }
        return terminalizeActiveTurns(status: status, completedAt: completedAt)
    }

    private func terminalizeActiveTurns(
        status: CodexTurnStatus,
        completedAt: Date?
    ) -> [CodexChatUpdate] {
        guard status.isTerminal else {
            return []
        }
        var changes: [CodexChatUpdate] = []
        for turn in turns where shouldTerminalizeLifecycleStatus(turn.status) {
            let previousStatus = turn.status
            turn.status = status
            if turn.status != previousStatus {
                changes.append(.turnUpdated(id: turn.id))
            }
            changes.append(contentsOf: terminalizeActiveItems(
                in: turn.id,
                status: status,
                completedAt: completedAt
            ))
        }
        return changes
    }

    private func terminalTurnStatus(for threadStatus: CodexThreadStatus?) -> CodexTurnStatus? {
        switch threadStatus {
        case .active, .unknown, .none:
            nil
        case .systemError:
            .failed
        case .notLoaded, .idle:
            .completed
        }
    }

    private func itemByApplyingTerminalLifecycleStatus(
        _ status: CodexTurnStatus,
        completedAt: Date,
        to item: CodexThreadItem
    ) -> CodexThreadItem {
        let content: CodexThreadItem.Content
        switch item.content {
        case .command(var command):
            guard shouldTerminalizeLifecycleStatus(command.status) else {
                return item
            }
            command.status = lifecycleStatus(for: command, fallback: status)
            command.completedAt = command.completedAt ?? completedAt
            content = .command(command)
        case .fileChange(var fileChange):
            guard shouldTerminalizeLifecycleStatus(fileChange.status) else {
                return item
            }
            fileChange.status = status
            content = .fileChange(fileChange)
        case .toolCall(var toolCall):
            guard shouldTerminalizeLifecycleStatus(toolCall.status) else {
                return item
            }
            toolCall.status = status
            content = .toolCall(toolCall)
        default:
            return item
        }
        return itemByReplacingContent(in: item, with: content)
    }

    private func shouldTerminalizeLifecycleStatus(_ status: CodexTurnStatus?) -> Bool {
        guard let status else {
            return true
        }
        return status.isTerminal == false
    }

    private func terminalCompletionDate(
        preferred: Date?,
        for item: CodexThreadItem
    ) -> Date {
        let fallback = Date()
        guard let preferred else {
            return fallback
        }
        guard let startedAt = commandStartedAt(in: item),
            preferred <= startedAt
        else {
            return preferred
        }
        return fallback > startedAt ? fallback : startedAt.addingTimeInterval(0.001)
    }

    private func commandStartedAt(in item: CodexThreadItem) -> Date? {
        guard case .command(let command) = item.content else {
            return nil
        }
        return command.startedAt
    }

    private func lifecycleStatus(
        for command: CodexCommand,
        fallback status: CodexTurnStatus
    ) -> CodexTurnStatus {
        guard status == .completed, let exitCode = command.exitCode else {
            return status
        }
        return exitCode == 0 ? .completed : .failed
    }

    private func itemByReplacingContent(
        in item: CodexThreadItem,
        with content: CodexThreadItem.Content
    ) -> CodexThreadItem {
        CodexThreadItem(
            id: item.id,
            kind: item.kind,
            content: content,
            rawPayload: item.rawPayload
        )
    }

    private func seedOutputDeltaStateIfNeeded(
        _ item: CodexThreadItem,
        key: CodexChatItemKey
    ) {
        guard let delta = outputDeltaText(from: item) else {
            return
        }
        liveMergeState.outputDeltaTextByItemKey[key] = delta
    }

    @discardableResult
    private func mergeOutputDelta(
        _ incomingItem: CodexThreadItem,
        into existing: CodexItem,
        key: CodexChatItemKey
    ) -> Bool {
        guard existing.kind == incomingItem.kind,
            let delta = outputDeltaText(from: incomingItem)
        else {
            return false
        }

        let previousAccumulatedText = liveMergeState.outputDeltaTextByItemKey[key] ?? ""
        let accumulatedText = previousAccumulatedText + delta
        let merge = mergedDeltaText(
            existingText: outputText(from: existing.threadItem),
            previousAccumulatedText: previousAccumulatedText,
            accumulatedText: accumulatedText,
            deltaText: delta
        )
        liveMergeState.outputDeltaTextByItemKey[key] = merge.accumulatedText
        existing.update(
            from: itemByReplacingOutput(
                in: existing.threadItem,
                with: merge.text,
                using: incomingItem
            ),
            itemsLoadState: .full
        )
        return true
    }

    private func insertRunningTurnIfMissing(
        _ turnID: CodexTurnID?,
        into changes: inout [CodexChatUpdate]
    ) {
        removeProvisionalSeedTurnIfNeeded(for: turnID, into: &changes)
        guard let turnID, turnsByID[turnID] == nil else {
            return
        }
        changes.appendIfPresent(upsertTurn(
            id: turnID,
            status: .running,
            errorDescription: nil,
            preservesExistingUsage: true
        ))
    }

    private func isOutputDeltaUpdate(_ item: CodexThreadItem) -> Bool {
        guard let rawPayload = item.rawPayload,
              let payload = try? JSONDecoder().decode(ItemProgressPayload.self, from: rawPayload)
        else {
            return false
        }
        return payload.delta != nil
    }

    private func outputDeltaText(from item: CodexThreadItem) -> String? {
        switch item.content {
        case .command(let command)
            where command.command.isEmpty && command.cwd == nil && command.exitCode == nil:
            command.output
        case .fileChange(let fileChange)
            where fileChange.path == nil:
            fileChange.output
        case .toolCall(let toolCall)
            where toolCall.namespace == nil && toolCall.server == nil && toolCall.name == nil
                && toolCall.arguments == nil && toolCall.error == nil:
            toolCall.result
        default:
            nil
        }
    }

    private func outputText(from item: CodexThreadItem) -> String? {
        switch item.content {
        case .command(let command):
            command.output
        case .fileChange(let fileChange):
            fileChange.output
        case .toolCall(let toolCall):
            toolCall.result
        default:
            nil
        }
    }

    private func itemByReplacingOutput(
        in existingItem: CodexThreadItem,
        with output: String,
        using incomingItem: CodexThreadItem
    ) -> CodexThreadItem {
        let content: CodexThreadItem.Content
        switch existingItem.content {
        case .command(var command):
            if case .command(let incomingCommand) = incomingItem.content,
                let status = incomingCommand.status
            {
                command.status = status
            }
            command.output = output
            content = .command(command)
        case .fileChange(var fileChange):
            if case .fileChange(let incomingFileChange) = incomingItem.content,
                let status = incomingFileChange.status
            {
                fileChange.status = status
            }
            fileChange.output = output
            content = .fileChange(fileChange)
        case .toolCall(var toolCall):
            if case .toolCall(let incomingToolCall) = incomingItem.content,
                let status = incomingToolCall.status
            {
                toolCall.status = status
            }
            toolCall.result = output
            content = .toolCall(toolCall)
        default:
            content = existingItem.content
        }
        return CodexThreadItem(
            id: existingItem.id,
            kind: existingItem.kind,
            content: content,
            rawPayload: incomingItem.rawPayload ?? existingItem.rawPayload
        )
    }

    private func merge(_ delta: CodexMessageDelta, turnID: CodexTurnID?) -> [CodexChatUpdate] {
        let itemID = delta.itemID ?? scopedFallbackMessageID(turnID: turnID)
        let key = CodexChatItemKey(id: itemID, turnID: turnID)
        let previousAccumulatedText = liveMergeState.messageDeltaTextByItemKey[key] ?? ""
        let accumulatedText = previousAccumulatedText + delta.text

        let existingMessage = item(for: key)?.message
        let merge = mergedDeltaText(
            existingText: existingMessage?.text,
            previousAccumulatedText: previousAccumulatedText,
            accumulatedText: accumulatedText,
            deltaText: delta.text
        )
        liveMergeState.messageDeltaTextByItemKey[key] = merge.accumulatedText
        let message = CodexMessage(
            id: itemID,
            role: existingMessage?.role ?? .assistant,
            phase: delta.phase ?? existingMessage?.phase,
            text: merge.text
        )
        return mergeItems([
            .init(id: itemID, kind: .agentMessage, content: .message(message)),
        ], turnID: turnID)
    }

    private func start(_ part: CodexReasoningPart, turnID: CodexTurnID?) -> [CodexChatUpdate] {
        let key = CodexChatItemKey(id: part.id, turnID: turnID)
        guard item(for: key) == nil else {
            return []
        }
        return mergeItems([
            .init(id: part.id, kind: .reasoning, content: .reasoning(.empty)),
        ], turnID: turnID)
    }

    private func merge(_ delta: CodexReasoningDelta, turnID: CodexTurnID?) -> [CodexChatUpdate] {
        let key = reasoningMergeKey(for: delta, turnID: turnID)
        let previousAccumulatedText = liveMergeState.reasoningDeltaTextByItemKey[key] ?? ""
        let accumulatedText = previousAccumulatedText + delta.delta

        let existingReasoning = item(for: key)?.reasoning
        let existingText: String?
        switch delta.part.kind {
        case .summary:
            existingText = existingReasoning?.summary.joined(separator: "\n")
        case .text:
            existingText = existingReasoning?.content.joined(separator: "\n")
        }
        let merge = mergedDeltaText(
            existingText: existingText,
            previousAccumulatedText: previousAccumulatedText,
            accumulatedText: accumulatedText,
            deltaText: delta.delta
        )
        liveMergeState.reasoningDeltaTextByItemKey[key] = merge.accumulatedText
        let reasoning: CodexReasoning
        switch delta.part.kind {
        case .summary:
            reasoning = .init(summary: merge.text)
        case .text:
            reasoning = .init(content: merge.text)
        }
        return mergeItems([
            .init(id: key.id, kind: .reasoning, content: .reasoning(reasoning)),
        ], turnID: turnID)
    }

    private func reasoningMergeKey(
        for delta: CodexReasoningDelta,
        turnID: CodexTurnID?
    ) -> CodexChatItemKey {
        let parentKey = CodexChatItemKey(id: delta.part.itemID, turnID: turnID)
        if item(for: parentKey)?.reasoning != nil {
            return parentKey
        }
        return CodexChatItemKey(id: delta.id, turnID: turnID)
    }

    private func mergedDeltaText(
        existingText: String?,
        previousAccumulatedText: String,
        accumulatedText: String,
        deltaText: String
    ) -> DeltaTextMerge {
        guard let existingText, existingText.isEmpty == false else {
            return .init(text: accumulatedText, accumulatedText: accumulatedText)
        }
        if existingText.hasPrefix(accumulatedText) {
            return .init(text: existingText, accumulatedText: accumulatedText)
        }
        if existingText.hasSuffix(accumulatedText) {
            return .init(text: existingText, accumulatedText: existingText)
        }
        if accumulatedText.hasPrefix(existingText) {
            return .init(text: accumulatedText, accumulatedText: accumulatedText)
        }
        if previousAccumulatedText.isEmpty,
            deltaText.isEmpty == false,
            (existingText.hasPrefix(deltaText) || existingText.hasSuffix(deltaText))
        {
            return .init(text: existingText, accumulatedText: existingText)
        }
        if previousAccumulatedText.isEmpty {
            let mergedText = existingText + deltaText
            return .init(text: mergedText, accumulatedText: mergedText)
        }
        if existingText.hasSuffix(previousAccumulatedText) {
            let mergedText = existingText + deltaText
            return .init(text: mergedText, accumulatedText: mergedText)
        }
        if existingText == previousAccumulatedText {
            return .init(text: accumulatedText, accumulatedText: accumulatedText)
        }
        return .init(text: existingText + deltaText, accumulatedText: accumulatedText)
    }

    private func changeForUpdatedItem(
        _ item: CodexItem,
        previousItem: CodexThreadItem
    ) -> CodexChatUpdate? {
        let currentItem = item.threadItem
        guard currentItem != previousItem else {
            return nil
        }
        if let delta = appendedText(previousText: previousItem.text, currentText: item.text) {
            return .itemTextAppended(
                id: item.itemID,
                turnID: item.turnID,
                delta: delta
            )
        }
        return .itemUpdated(id: item.itemID, turnID: item.turnID)
    }

    private func appendedText(previousText: String?, currentText: String?) -> String? {
        guard let currentText else {
            return nil
        }
        let previousText = previousText ?? ""
        guard currentText.hasPrefix(previousText), currentText.count > previousText.count else {
            return nil
        }
        return String(currentText.dropFirst(previousText.count))
    }

    private func scopedFallbackMessageID(turnID: CodexTurnID?) -> String {
        turnID.map { "agent-message-delta:\($0.rawValue)" } ?? "agent-message-delta"
    }

    private func setUsage(_ usage: CodexTokenUsage, for turnID: CodexTurnID) -> CodexChatUpdate? {
        if let turn = turnsByID[turnID] {
            let previousUsage = turn.usage
            turn.usage = usage
            return turn.usage == previousUsage ? nil : .turnUpdated(id: turn.id)
        } else {
            let turn = contextTurn(id: turnID, usage: usage)
            turns.append(turn)
            turnsByID[turn.id] = turn
            return .turnInserted(id: turn.id)
        }
    }

    private func item(for key: CodexChatItemKey) -> CodexItem? {
        itemsByMergeKey[key]
    }

    private func removeProvisionalSeedTurn(_ provisionalTurnID: CodexTurnID) -> [CodexItem] {
        provisionalSeedTurnID = nil
        guard let provisionalTurn = turnsByID[provisionalTurnID] else {
            return []
        }

        let removedItems = items.filter { $0.turnID == provisionalTurnID }
        let removedKeys = Set(removedItems.map(\.mergeKey))
        if removedKeys.isEmpty == false {
            items.removeAll { item in
                removedKeys.contains(item.mergeKey)
            }
            for item in removedItems {
                removeItemFromIndexes(item)
            }
            unregisterItemsFromContext(removedItems)
        }

        turns.removeAll { $0 === provisionalTurn }
        turnsByID.removeValue(forKey: provisionalTurnID)
        itemsByTurnID.removeValue(forKey: provisionalTurnID)
        provisionalTurn.replaceContextItems([])
        return removedItems
    }

    @discardableResult
    private func removeProvisionalSeedTurnIfNeeded(
        for liveTurnID: CodexTurnID?,
        into changes: inout [CodexChatUpdate]
    ) -> Bool {
        guard let provisionalTurnID = provisionalSeedTurnID,
            let liveTurnID
        else {
            return false
        }
        guard provisionalTurnID != liveTurnID,
            turnsByID[provisionalTurnID] != nil
        else {
            provisionalSeedTurnID = nil
            return false
        }

        let removedItems = removeProvisionalSeedTurn(provisionalTurnID)
        changes.append(contentsOf: removedItems.map { item in
            .itemRemoved(id: item.itemID, turnID: item.turnID)
        })
        changes.append(.turnUpdated(id: provisionalTurnID))
        return true
    }

    private func terminalizeActiveItemsBeforeAppending(
        _ incomingItem: CodexThreadItem,
        turnID: CodexTurnID?
    ) -> [CodexChatUpdate] {
        terminalizeActiveItemsBeforeAppending(
            incomingKey: CodexChatItemKey(threadItem: incomingItem, turnID: turnID),
            turnID: turnID
        )
    }

    private func terminalizeActiveItemsBeforeAppending(
        incomingKey: CodexChatItemKey,
        turnID: CodexTurnID?
    ) -> [CodexChatUpdate] {
        guard let turnID else {
            return []
        }
        if let existingItem = item(for: incomingKey),
            isLifecycleTrackedItem(existingItem.threadItem)
        {
            return []
        }
        var changes: [CodexChatUpdate] = []
        for item in itemsByTurnID[turnID] ?? [] where item.mergeKey != incomingKey {
            let previousItem = item.threadItem
            let terminalItem = itemByApplyingTerminalLifecycleStatus(
                .completed,
                completedAt: terminalCompletionDate(preferred: nil, for: previousItem),
                to: previousItem
            )
            guard terminalItem != previousItem else {
                continue
            }
            item.update(from: terminalItem, itemsLoadState: item.itemsLoadState)
            changes.appendIfPresent(changeForUpdatedItem(item, previousItem: previousItem))
        }
        return changes
    }

    private func isLifecycleTrackedItem(_ item: CodexThreadItem) -> Bool {
        switch item.content {
        case .command, .fileChange, .toolCall:
            true
        default:
            false
        }
    }

    private func removeReasoningParts(
        parentItemID: String
    ) -> [CodexChatUpdate] {
        let prefixes = ["\(parentItemID):summary:", "\(parentItemID):content:"]
        let removedItems = items.filter { item in
            prefixes.contains { item.itemID.hasPrefix($0) }
        }
        guard removedItems.isEmpty == false else {
            return []
        }
        let removedKeys = Set(removedItems.map(\.mergeKey))
        items.removeAll { item in
            removedKeys.contains(item.mergeKey)
        }
        for item in removedItems {
            removeItemFromIndexes(item)
        }
        unregisterItemsFromContext(removedItems)
        liveMergeState.reasoningDeltaTextByItemKey = liveMergeState.reasoningDeltaTextByItemKey
            .filter { key, _ in
                prefixes.contains { key.id.hasPrefix($0) } == false
            }
        return removedItems.map { item in
            .itemRemoved(id: item.itemID, turnID: item.turnID)
        }
    }

    @discardableResult
    private func removeNonAuthoritativeItems(in turnID: CodexTurnID) -> [CodexChatUpdate] {
        let removedItems = items.filter { item in
            item.turnID == turnID && item.itemsLoadState != .full
        }
        guard removedItems.isEmpty == false else {
            return []
        }
        let removedKeys = Set(removedItems.map(\.mergeKey))
        items.removeAll { item in
            removedKeys.contains(item.mergeKey)
        }
        for item in removedItems {
            removeItemFromIndexes(item)
        }
        unregisterItemsFromContext(removedItems)
        return removedItems.map { item in
            .itemRemoved(id: item.itemID, turnID: item.turnID)
        }
    }

    private func markRunningIfNeeded() -> CodexChatUpdate? {
        let statusChange: CodexChatUpdate?
        if status?.isActive != true {
            statusChange = setStatus(.active(activeFlags: []))
        } else {
            statusChange = nil
        }
        if phase != .loading {
            phase = .loading
        }
        return statusChange
    }

    private func setStatus(_ status: CodexThreadStatus?) -> CodexChatUpdate? {
        let previousStatus = self.status
        self.status = status
        return previousStatus == status ? nil : .statusChanged(status)
    }

    private func markIdleIfActive() -> CodexChatUpdate? {
        guard status?.isActive == true else {
            return nil
        }
        return setStatus(.idle)
    }

    package func syncPhaseAfterRefresh(includeTurns: Bool, refreshedStatus: Bool = true) {
        if includeTurns {
            syncPhaseWithTurnsAfterRefresh()
        } else {
            syncPhaseWithStatusAfterMetadataRefresh(refreshedStatus: refreshedStatus)
        }
    }

    @discardableResult
    package func syncPhaseWithTurnsAfterRefresh() -> CodexChatUpdate? {
        let previousPhase = phase
        guard let latestTurn = turns.last else {
            phase = status?.isActive == true ? .loading : .loaded
            lastErrorDescription = nil
            return phase == previousPhase ? nil : .phaseChanged(phase)
        }
        switch latestTurn.status {
        case .running:
            phase = status?.isActive == true ? .loading : .loaded
            lastErrorDescription = nil
        case .failed, .interrupted, .cancelled:
            fail(with: latestTurn.errorDescription ?? latestTurn.status?.rawValue ?? "Turn failed")
        case .completed, .unknown, .none:
            phase = status?.isActive == true ? .loading : .loaded
            lastErrorDescription = nil
        }
        return phase == previousPhase ? nil : .phaseChanged(phase)
    }

    private func syncPhaseWithStatusAfterMetadataRefresh(refreshedStatus: Bool) {
        switch status {
        case .active:
            phase = .loading
            lastErrorDescription = nil
        case .notLoaded, .idle, .systemError, .unknown, .none:
            if refreshedStatus {
                _ = terminalizeActiveTurns(for: status, completedAt: updatedAt)
            }
            phase = .loaded
            lastErrorDescription = nil
        }
    }

    private func markLoadedIfNotFailed() {
        if case .failed = phase {
            return
        }
        phase = .loaded
    }

    private func appendPhaseChange(
        to changes: inout [CodexChatUpdate],
        previousPhase: CodexDataPhase
    ) {
        if phase != previousPhase {
            changes.append(.phaseChanged(phase))
        }
    }

    package func fail(with error: any Error) {
        let message = error.localizedDescription
        fail(with: message)
    }

    package func resetLiveMergeStateFromCurrentItems() {
        liveMergeState = LiveMergeState()
    }

    private func rebuildTurnIndex() {
        turnsByID = Dictionary(
            turns.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    private func rebuildItemIndexes() {
        itemsByMergeKey.removeAll(keepingCapacity: true)
        itemsByTurnID.removeAll(keepingCapacity: true)
        for turn in turns {
            turn.replaceContextItems([])
        }
        var coalescedItems: [CodexItem] = []
        coalescedItems.reserveCapacity(items.count)
        for item in items where itemsByMergeKey[item.mergeKey] == nil {
            coalescedItems.append(item)
            addItemToIndexes(item)
        }
        if coalescedItems.count != items.count {
            items = coalescedItems
        }
    }

    private func appendItem(_ item: CodexItem) {
        items.append(item)
        addItemToIndexes(item)
    }

    private func replaceItemAcrossTurns(
        _ existing: CodexItem,
        with incomingItem: CodexThreadItem,
        turnID: CodexTurnID?,
        itemsLoadState: CodexTurnItemsLoadState
    ) -> CodexItem {
        let replacementIndex = items.firstIndex { $0 === existing }
        let previousMergeKey = existing.mergeKey
        removeItemFromIndexes(existing)
        unregisterItemsFromContext([existing])
        let replacement = contextItem(
            threadItem: incomingItem,
            turnID: turnID,
            itemsLoadState: itemsLoadState
        )
        if let replacementIndex {
            items[replacementIndex] = replacement
        } else {
            items.append(replacement)
        }
        addItemToIndexes(replacement)
        if let outputDeltaText = liveMergeState.outputDeltaTextByItemKey.removeValue(
            forKey: previousMergeKey
        ) {
            liveMergeState.outputDeltaTextByItemKey[replacement.mergeKey] = outputDeltaText
        }
        return replacement
    }

    private func addItemToIndexes(_ item: CodexItem) {
        itemsByMergeKey[item.mergeKey] = item
        if let turnID = item.turnID {
            itemsByTurnID[turnID, default: []].append(item)
            turnsByID[turnID]?.attachContextItemIfNeeded(item)
        }
    }

    private func removeItemFromIndexes(_ item: CodexItem) {
        itemsByMergeKey.removeValue(forKey: item.mergeKey)
        guard let turnID = item.turnID else {
            return
        }
        itemsByTurnID[turnID]?.removeAll { $0 === item }
        turnsByID[turnID]?.detachContextItem(item)
        if itemsByTurnID[turnID]?.isEmpty == true {
            itemsByTurnID.removeValue(forKey: turnID)
        }
    }

    private func unregisterItemsFromContext(_ items: [CodexItem]) {
        guard let modelContext else {
            return
        }
        for item in items {
            modelContext.unregisterContextItem(item)
            item.detachFromContext()
        }
    }

    private func fail(with message: String) {
        lastErrorDescription = message
        phase = .failed(message)
    }

    private struct LiveMergeState {
        var messageDeltaTextByItemKey: [CodexChatItemKey: String] = [:]
        var reasoningDeltaTextByItemKey: [CodexChatItemKey: String] = [:]
        var outputDeltaTextByItemKey: [CodexChatItemKey: String] = [:]
    }

    private struct DeltaTextMerge {
        var text: String
        var accumulatedText: String
    }

    private struct ItemProgressPayload: Decodable {
        var delta: String?
    }

}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexWorkspaceGroup: Sendable {}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexWorkspace: Sendable {}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexTurn: Sendable {}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexItem: Sendable {}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexChat: Sendable {}
