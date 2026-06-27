import CodexAppServerKit
import Foundation
import Observation

@MainActor
public protocol CodexObservableModel: AnyObject, Identifiable where ID: Sendable {
    var id: ID { get }
    var modelContext: CodexModelContext? { get }
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

@MainActor
@Observable
public final class CodexWorkspaceGroup: CodexObservableModel {
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

    package func update(name: String) {
        self.name = name
    }

    package func setWorkspaces(_ workspaces: [CodexWorkspace]) {
        self.workspaces = workspaces
    }

    public func refresh() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.refresh(self)
    }
}

@MainActor
@Observable
public final class CodexWorkspace: CodexObservableModel {
    public let id: CodexWorkspaceID
    public private(set) var url: URL
    public private(set) var name: String
    public private(set) var chats: [CodexChat]

    public private(set) weak var workspaceGroup: CodexWorkspaceGroup?

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

    package func update(
        url: URL,
        name: String,
        workspaceGroup: CodexWorkspaceGroup?
    ) {
        self.url = url
        self.name = name
        self.workspaceGroup = workspaceGroup
    }

    package func setChats(_ chats: [CodexChat]) {
        self.chats = chats
    }

    package func addChatIfNeeded(_ chat: CodexChat) {
        guard chats.contains(where: { $0 === chat }) == false else {
            return
        }
        chats.append(chat)
    }

    package func moveChatToFront(_ chat: CodexChat) {
        chats.removeAll { $0 === chat }
        chats.insert(chat, at: 0)
    }

    public func refresh() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.refresh(self)
    }

    @discardableResult
    public func startChat(_ input: CodexChatInput = .init()) async throws -> CodexChat {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await modelContext.startChat(in: self, input: input)
    }
}

@MainActor
@Observable
public final class CodexChat: CodexObservableModel {
    public let id: CodexThreadID
    public private(set) var name: String?
    public private(set) var preview: String?
    public private(set) var modelProvider: String?
    public private(set) var isArchived: Bool
    public private(set) var createdAt: Date?
    public private(set) var updatedAt: Date?
    public private(set) var ephemeral: Bool?
    public private(set) var turns: [Turn]
    public private(set) var items: [Item]
    public var phase: CodexDataPhase = .idle
    public var lastErrorDescription: String?

    public private(set) weak var workspace: CodexWorkspace?

    @ObservationIgnored
    private var liveMergeState = LiveMergeState()

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

    package func apply(_ snapshot: CodexThreadSnapshot, workspace: CodexWorkspace?) {
        if snapshot.hasField(.workspace) {
            self.workspace = workspace
        }
        if snapshot.hasField(.name) {
            name = snapshot.name
        }
        if snapshot.hasField(.preview) {
            preview = snapshot.preview
        }
        if snapshot.hasField(.modelProvider) {
            modelProvider = snapshot.modelProvider
        }
        if snapshot.hasField(.createdAt) {
            createdAt = snapshot.createdAt
        }
        if snapshot.hasField(.updatedAt) {
            updatedAt = snapshot.updatedAt
        }
        if snapshot.hasField(.ephemeral) {
            ephemeral = snapshot.ephemeral
        }
        if let turns = snapshot.turns {
            if snapshot.turnItemsAreAuthoritative {
                replaceTurns(with: turns)
                replaceItems(with: turns)
            } else {
                mergeTurns(with: turns)
                mergeItems(from: turns)
            }
        }
    }

    package func setArchived(_ isArchived: Bool) {
        self.isArchived = isArchived
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

    public func refresh(includeTurns: Bool = true) async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        phase = .loading
        lastErrorDescription = nil
        do {
            try await modelContext.refresh(self, includeTurns: includeTurns)
            syncPhaseWithTurnsAfterRefresh()
        } catch {
            fail(with: error)
            throw error
        }
    }

    public func observe(includeTurns: Bool = true) async throws -> CodexChatObservation {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await modelContext.observe(self, includeTurns: includeTurns)
    }

    @discardableResult
    public func send(_ input: CodexChatMessageInput) async throws -> CodexResponse {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        phase = .loading
        lastErrorDescription = nil
        do {
            let response = try await modelContext.send(input, in: self)
            syncPhaseWithTurnsAfterRefresh()
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
    public func send(
        _ text: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        try await send(.init(text, options: options))
    }

    public func cancel() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.cancelActiveTurn(in: self)
    }

    public func archive() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.archive(self)
    }

    public func unarchive() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.unarchive(self)
    }

    public func delete() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.delete(self)
    }

    private func replaceTurns(with records: [CodexTurnSnapshot]) {
        let existingByID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        turns = records.map { record in
            let turn = existingByID[record.id] ?? Turn(id: record.id)
            turn.status = record.status
            turn.errorDescription = record.errorMessage
            return turn
        }
    }

    private func mergeTurns(with records: [CodexTurnSnapshot]) {
        for record in records {
            upsertTurn(
                id: record.id,
                status: record.status,
                errorDescription: record.errorMessage,
                preservesExistingUsage: true
            )
        }
    }

    private func replaceItems(with records: [CodexTurnSnapshot]) {
        let existingByKey = Dictionary(uniqueKeysWithValues: items.map { ($0.mergeKey, $0) })
        items = records.flatMap { record in
            record.items.map { incomingItem in
                let incomingKey = ItemKey(id: incomingItem.id, turnID: record.id)
                if let existing = existingByKey[incomingKey] {
                    existing.update(from: incomingItem, turnID: record.id)
                    return existing
                }
                return Item(threadItem: incomingItem, turnID: record.id)
            }
        }
    }

    private func mergeItems(from records: [CodexTurnSnapshot]) {
        for record in records where record.items.isEmpty == false {
            mergeItems(record.items, turnID: record.id)
        }
    }

    private func upsertTurn(
        id: CodexTurnID,
        status: CodexTurnStatus?,
        errorDescription: String?,
        usage: CodexTokenUsage? = nil,
        preservesExistingUsage: Bool = false
    ) {
        if let turn = turns.first(where: { $0.id == id }) {
            turn.status = status
            turn.errorDescription = errorDescription
            if preservesExistingUsage == false || usage != nil {
                turn.usage = usage
            }
        } else {
            turns.append(Turn(
                id: id,
                status: status,
                errorDescription: errorDescription,
                usage: usage
            ))
        }
    }

    package func apply(_ response: CodexResponse) {
        if let completedAt = response.completedAt,
            updatedAt.map({ completedAt > $0 }) ?? true
        {
            updatedAt = completedAt
        }
        upsertTurn(
            id: response.turnID,
            status: response.status,
            errorDescription: response.errorMessage,
            usage: response.usage,
            preservesExistingUsage: true
        )
        mergeItems(response.transcript.items, turnID: response.turnID)
    }

    package func apply(_ event: CodexThreadEvent) {
        switch event {
        case .turnStarted(let turnID):
            upsertTurn(
                id: turnID,
                status: .running,
                errorDescription: nil,
                preservesExistingUsage: true
            )
            phase = .loading
            lastErrorDescription = nil
        case .turnCompleted(let response):
            apply(response)
            if response.errorMessage != nil || response.status?.isFailure == true {
                let message = response.errorMessage ?? response.status?.rawValue ?? "Turn failed"
                fail(with: message)
            } else {
                phase = .loaded
                lastErrorDescription = nil
            }
        case .turnFailed(let turnID, let message):
            if let turnID {
                upsertTurn(
                    id: turnID,
                    status: .failed,
                    errorDescription: message,
                    preservesExistingUsage: true
                )
            }
            fail(with: message)
        case .itemStarted(let item, let turnID),
             .itemCompleted(let item, let turnID):
            mergeItems([item], turnID: turnID)
            markRunningIfNeeded()
        case .itemUpdated(let item, let turnID):
            mergeItems([item], turnID: turnID, accumulatesOutputDeltas: true)
            markRunningIfNeeded()
        case .message(let message, let turnID):
            let item = CodexThreadItem(
                id: message.id,
                kind: message.role == .user ? .userMessage : .agentMessage,
                content: .message(message)
            )
            mergeItems([item], turnID: turnID)
            markRunningIfNeeded()
        case .messageDelta(let delta, let turnID):
            merge(delta, turnID: turnID)
            markRunningIfNeeded()
        case .reasoningSummaryPartAdded(let part, let turnID):
            start(part, turnID: turnID)
            markRunningIfNeeded()
        case .reasoningDelta(let delta, let turnID):
            merge(delta, turnID: turnID)
            markRunningIfNeeded()
        case .tokenUsageUpdated(let usage, let turnID):
            if let turnID {
                setUsage(usage, for: turnID)
            }
        case .statusChanged(let status):
            switch status {
            case .running, .unknown:
                markRunningIfNeeded()
            case .closed:
                markLoadedIfNotFailed()
            }
        case .closed:
            markLoadedIfNotFailed()
        case .unknown:
            break
        }
    }

    private func mergeItems(
        _ incomingItems: [CodexThreadItem],
        turnID: CodexTurnID?,
        accumulatesOutputDeltas: Bool = false
    ) {
        guard incomingItems.isEmpty == false else {
            return
        }
        let existingByKey = Dictionary(uniqueKeysWithValues: items.map { ($0.mergeKey, $0) })
        var merged = items
        for incomingItem in incomingItems {
            if incomingItem.kind == .reasoning && incomingItem.id.contains(":summary:") == false
                && incomingItem.id.contains(":content:") == false
            {
                removeReasoningParts(parentItemID: incomingItem.id, from: &merged)
            }
            let incomingKey = ItemKey(id: incomingItem.id, turnID: turnID)
            if let existing = existingByKey[incomingKey] {
                if accumulatesOutputDeltas,
                    mergeOutputDelta(incomingItem, into: existing, key: incomingKey)
                {
                    continue
                } else {
                    existing.update(from: incomingItem, turnID: turnID)
                }
            } else {
                if accumulatesOutputDeltas {
                    seedOutputDeltaStateIfNeeded(incomingItem, key: incomingKey)
                }
                merged.append(Item(threadItem: incomingItem, turnID: turnID))
            }
        }
        items = merged
    }

    private func seedOutputDeltaStateIfNeeded(_ item: CodexThreadItem, key: ItemKey) {
        guard let delta = outputDeltaText(from: item) else {
            return
        }
        liveMergeState.outputDeltaTextByItemKey[key] = delta
    }

    @discardableResult
    private func mergeOutputDelta(
        _ incomingItem: CodexThreadItem,
        into existing: Item,
        key: ItemKey
    ) -> Bool {
        guard existing.kind == incomingItem.kind,
            let delta = outputDeltaText(from: incomingItem)
        else {
            return false
        }

        let previousAccumulatedText = liveMergeState.outputDeltaTextByItemKey[key] ?? ""
        let accumulatedText = previousAccumulatedText + delta
        liveMergeState.outputDeltaTextByItemKey[key] = accumulatedText
        let mergedText = mergedDeltaText(
            existingText: outputText(from: existing.threadItem),
            previousAccumulatedText: previousAccumulatedText,
            accumulatedText: accumulatedText,
            deltaText: delta
        )
        liveMergeState.outputDeltaTextByItemKey[key] = mergedText
        existing.update(
            from: itemByReplacingOutput(
                in: existing.threadItem,
                with: mergedText,
                using: incomingItem
            ),
            turnID: key.turnID
        )
        return true
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

    private func merge(_ delta: CodexMessageDelta, turnID: CodexTurnID?) {
        let itemID = delta.itemID ?? scopedFallbackMessageID(turnID: turnID)
        let key = ItemKey(id: itemID, turnID: turnID)
        let previousAccumulatedText = liveMergeState.messageDeltaTextByItemKey[key] ?? ""
        let accumulatedText = previousAccumulatedText + delta.text
        liveMergeState.messageDeltaTextByItemKey[key] = accumulatedText

        let existingMessage = item(for: key)?.message
        let text = mergedDeltaText(
            existingText: existingMessage?.text,
            previousAccumulatedText: previousAccumulatedText,
            accumulatedText: accumulatedText,
            deltaText: delta.text
        )
        let message = CodexMessage(
            id: itemID,
            role: existingMessage?.role ?? .assistant,
            phase: delta.phase ?? existingMessage?.phase,
            text: text
        )
        mergeItems([
            .init(id: itemID, kind: .agentMessage, content: .message(message)),
        ], turnID: turnID)
    }

    private func start(_ part: CodexReasoningPart, turnID: CodexTurnID?) {
        let key = ItemKey(id: part.id, turnID: turnID)
        guard item(for: key) == nil else {
            return
        }
        mergeItems([
            .init(id: part.id, kind: .reasoning, content: .reasoning(.empty)),
        ], turnID: turnID)
    }

    private func merge(_ delta: CodexReasoningDelta, turnID: CodexTurnID?) {
        let key = ItemKey(id: delta.id, turnID: turnID)
        let previousAccumulatedText = liveMergeState.reasoningDeltaTextByItemKey[key] ?? ""
        let accumulatedText = previousAccumulatedText + delta.delta
        liveMergeState.reasoningDeltaTextByItemKey[key] = accumulatedText

        let existingReasoning = item(for: key)?.reasoning
        let existingText: String?
        switch delta.part.kind {
        case .summary:
            existingText = existingReasoning?.summary.joined(separator: "\n")
        case .text:
            existingText = existingReasoning?.content.joined(separator: "\n")
        }
        let text = mergedDeltaText(
            existingText: existingText,
            previousAccumulatedText: previousAccumulatedText,
            accumulatedText: accumulatedText,
            deltaText: delta.delta
        )
        let reasoning: CodexReasoning
        switch delta.part.kind {
        case .summary:
            reasoning = .init(summary: text)
        case .text:
            reasoning = .init(content: text)
        }
        mergeItems([
            .init(id: delta.id, kind: .reasoning, content: .reasoning(reasoning)),
        ], turnID: turnID)
    }

    private func mergedDeltaText(
        existingText: String?,
        previousAccumulatedText: String,
        accumulatedText: String,
        deltaText: String
    ) -> String {
        guard let existingText, existingText.isEmpty == false else {
            return accumulatedText
        }
        if existingText.hasPrefix(accumulatedText) {
            return existingText
        }
        if existingText == previousAccumulatedText {
            return accumulatedText
        }
        return existingText + deltaText
    }

    private func scopedFallbackMessageID(turnID: CodexTurnID?) -> String {
        turnID.map { "agent-message-delta:\($0.rawValue)" } ?? "agent-message-delta"
    }

    private func setUsage(_ usage: CodexTokenUsage, for turnID: CodexTurnID) {
        if let turn = turns.first(where: { $0.id == turnID }) {
            turn.usage = usage
        } else {
            turns.append(Turn(id: turnID, usage: usage))
        }
    }

    private func item(for key: ItemKey) -> Item? {
        items.first { $0.mergeKey == key }
    }

    private func removeReasoningParts(parentItemID: String, from items: inout [Item]) {
        let prefixes = ["\(parentItemID):summary:", "\(parentItemID):content:"]
        items.removeAll { item in
            prefixes.contains { item.id.hasPrefix($0) }
        }
        liveMergeState.reasoningDeltaTextByItemKey = liveMergeState.reasoningDeltaTextByItemKey
            .filter { key, _ in
                prefixes.contains { key.id.hasPrefix($0) } == false
            }
    }

    private func markRunningIfNeeded() {
        if phase != .loading {
            phase = .loading
        }
    }

    package func syncPhaseWithTurnsAfterRefresh() {
        guard let latestTurn = turns.last else {
            phase = .loaded
            lastErrorDescription = nil
            return
        }
        switch latestTurn.status {
        case .running:
            phase = .loading
            lastErrorDescription = nil
        case .failed, .interrupted, .cancelled:
            fail(with: latestTurn.errorDescription ?? latestTurn.status?.rawValue ?? "Turn failed")
        case .completed, .unknown, .none:
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

    package func fail(with error: any Error) {
        let message = error.localizedDescription
        fail(with: message)
    }

    package func resetLiveMergeState() {
        liveMergeState = LiveMergeState()
    }

    private func fail(with message: String) {
        lastErrorDescription = message
        phase = .failed(message)
    }

    fileprivate struct ItemKey: Hashable {
        var id: String
        var turnID: CodexTurnID?
    }

    private struct LiveMergeState {
        var messageDeltaTextByItemKey: [ItemKey: String] = [:]
        var reasoningDeltaTextByItemKey: [ItemKey: String] = [:]
        var outputDeltaTextByItemKey: [ItemKey: String] = [:]
    }

    @MainActor
    @Observable
    public final class Turn {
        public let id: CodexTurnID
        public var status: CodexTurnStatus?
        public var errorDescription: String?
        public var usage: CodexTokenUsage?

        public init(
            id: CodexTurnID,
            status: CodexTurnStatus? = nil,
            errorDescription: String? = nil,
            usage: CodexTokenUsage? = nil
        ) {
            self.id = id
            self.status = status
            self.errorDescription = errorDescription
            self.usage = usage
        }
    }

    @MainActor
    @Observable
    public final class Item {
        public let id: String
        public var turnID: CodexTurnID?
        public var kind: CodexThreadItem.Kind
        public var content: CodexThreadItem.Content
        public var rawPayload: Data?

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
            CodexThreadItem(id: id, kind: kind, content: content, rawPayload: rawPayload)
        }

        fileprivate var mergeKey: ItemKey {
            .init(id: id, turnID: turnID)
        }

        fileprivate init(threadItem: CodexThreadItem, turnID: CodexTurnID?) {
            self.id = threadItem.id
            self.turnID = turnID
            self.kind = threadItem.kind
            self.content = threadItem.content
            self.rawPayload = threadItem.rawPayload
        }

        fileprivate func update(from threadItem: CodexThreadItem, turnID: CodexTurnID?) {
            self.turnID = turnID
            kind = threadItem.kind
            content = threadItem.content
            rawPayload = threadItem.rawPayload
        }
    }
}
