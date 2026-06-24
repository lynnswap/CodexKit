import CodexAppServerKit
import Foundation
import Observation

@MainActor
@Observable
public final class CodexThreadLibrary {
    public struct Configuration: Sendable {
        public var query: CodexThreadQuery
        public var sectionTitle: String

        public init(
            query: CodexThreadQuery = .init(),
            sectionTitle: String = "Threads"
        ) {
            self.query = query
            self.sectionTitle = sectionTitle
        }
    }

    public var phase: CodexUIPhase = .idle
    public var sections: [Section] = []
    public var selectedThreadID: CodexThreadID?
    public var nextCursor: String?
    public var backwardsCursor: String?
    public var lastErrorDescription: String?

    public let configuration: Configuration

    @ObservationIgnored
    private let server: CodexAppServer

    public init(
        server: CodexAppServer,
        configuration: Configuration = .init()
    ) {
        self.server = server
        self.configuration = configuration
    }

    public func refresh() async {
        await reload()
    }

    public func loadNextPage() async {
        guard let nextCursor else {
            return
        }
        await load(cursor: nextCursor, appending: true)
    }

    public func selectThread(_ threadID: CodexThreadID?) {
        selectedThreadID = threadID
    }

    public func conversation(
        for threadID: CodexThreadID,
        options: CodexThread.ResumeOptions = .init(),
        configuration: CodexConversation.Configuration = .init()
    ) async throws -> CodexConversation {
        let thread = try await server.resumeThread(threadID, options: options)
        return CodexConversation(thread: thread, configuration: configuration)
    }

    public func selectedConversation(
        options: CodexThread.ResumeOptions = .init(),
        configuration: CodexConversation.Configuration = .init()
    ) async throws -> CodexConversation {
        guard let selectedThreadID else {
            throw CodexThreadLibraryError.noSelection
        }
        return try await conversation(
            for: selectedThreadID,
            options: options,
            configuration: configuration
        )
    }

    @discardableResult
    public func startConversation(
        in workspace: URL,
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init(),
        configuration: CodexConversation.Configuration = .init()
    ) async throws -> CodexConversation {
        phase = .loading
        lastErrorDescription = nil
        do {
            let thread = try await server.startThread(
                in: workspace,
                instructions: instructions,
                options: options
            )
            let isVisible = await reflectThreadMutation(
                id: thread.id,
                workspace: thread.workspace,
                name: nil,
                preview: nil,
                turns: [],
                archived: false,
                preferFront: true
            )
            if isVisible {
                selectedThreadID = thread.id
            }
            markLoadedIfNeeded()
            return CodexConversation(thread: thread, configuration: configuration)
        } catch {
            fail(with: error)
            throw error
        }
    }

    public func archive(_ threadID: CodexThreadID) async throws {
        phase = .loading
        lastErrorDescription = nil
        do {
            try await server.archiveThread(threadID)
            if canEvaluateMutatedThreadVisibilityLocally {
                removeThread(threadID)
                phase = .loaded
            } else {
                await reload()
            }
        } catch {
            fail(with: error)
            throw error
        }
    }

    public func unarchive(_ threadID: CodexThreadID) async throws {
        phase = .loading
        lastErrorDescription = nil
        do {
            let thread = try await server.unarchiveThread(threadID)
            if canEvaluateMutatedThreadVisibilityLocally {
                if isThreadVisible(workspace: thread.workspace, archived: false) {
                    let record = try await thread.read(includeTurns: true)
                    upsertThread(
                        id: record.id,
                        workspace: record.workspace,
                        name: record.name,
                        preview: record.preview,
                        turns: record.turns,
                        archived: false,
                        preferFront: true
                    )
                } else {
                    removeThread(thread.id)
                }
            } else {
                await reload()
            }
            markLoadedIfNeeded()
        } catch {
            fail(with: error)
            throw error
        }
    }

    public func delete(_ threadID: CodexThreadID) async throws {
        phase = .loading
        lastErrorDescription = nil
        do {
            try await server.deleteThread(threadID)
            if canEvaluateMutatedThreadVisibilityLocally {
                removeThread(threadID)
                phase = .loaded
            } else {
                await reload()
            }
        } catch {
            fail(with: error)
            throw error
        }
    }

    private func load(cursor: String?, appending: Bool) async {
        phase = .loading
        lastErrorDescription = nil
        do {
            var query = configuration.query
            query.cursor = cursor
            let page = try await server.listThreads(query)
            replaceThreads(with: page.threads, appending: appending)
            nextCursor = page.nextCursor
            backwardsCursor = page.backwardsCursor
            phase = .loaded
        } catch {
            fail(with: error)
        }
    }

    private func reload() async {
        await load(cursor: configuration.query.cursor, appending: false)
    }

    private func replaceThreads(with records: [CodexThreadSnapshot], appending: Bool) {
        let section = defaultSection()
        let existingByID = Dictionary(uniqueKeysWithValues: section.threads.map { ($0.id, $0) })
        let updated = records.map { record in
            let thread = existingByID[record.id] ?? ThreadSummary(id: record.id)
            thread.update(
                workspace: record.workspace,
                name: record.name,
                preview: record.preview,
                turns: record.turns
            )
            return thread
        }

        if appending {
            let updatedIDs = Set(updated.map(\.id))
            section.threads = section.threads.filter { updatedIDs.contains($0.id) == false } + updated
        } else {
            section.threads = updated
        }

        clearSelectionIfNeeded(in: section.threads)
    }

    @discardableResult
    private func reflectThreadMutation(
        id: CodexThreadID,
        workspace: URL?,
        name: String?,
        preview: String?,
        turns: [CodexTurnSnapshot],
        archived: Bool,
        preferFront: Bool
    ) async -> Bool {
        guard canEvaluateMutatedThreadVisibilityLocally else {
            await reload()
            return sections.contains { section in
                section.threads.contains { $0.id == id }
            }
        }

        upsertThread(
            id: id,
            workspace: workspace,
            name: name,
            preview: preview,
            turns: turns,
            archived: archived,
            preferFront: preferFront
        )
        return isThreadVisible(workspace: workspace, archived: archived)
    }

    private func upsertThread(
        id: CodexThreadID,
        workspace: URL?,
        name: String?,
        preview: String?,
        turns: [CodexTurnSnapshot],
        archived: Bool,
        preferFront: Bool
    ) {
        let section = defaultSection()
        guard isThreadVisible(workspace: workspace, archived: archived) else {
            section.threads.removeAll { $0.id == id }
            if selectedThreadID == id {
                selectedThreadID = nil
            }
            return
        }

        let thread = section.threads.first { $0.id == id } ?? ThreadSummary(id: id)
        thread.update(workspace: workspace, name: name, preview: preview, turns: turns)
        section.threads.removeAll { $0.id == id }
        if preferFront {
            section.threads.insert(thread, at: 0)
        } else {
            section.threads.append(thread)
        }
    }

    private var canEvaluateMutatedThreadVisibilityLocally: Bool {
        let query = configuration.query
        return query.cursor == nil
            && query.limit == nil
            && query.searchTerm == nil
            && query.modelProviders == nil
            && query.sortDirection == nil
            && query.sortKey == nil
            && query.sourceKinds == nil
            && query.useStateDBOnly == nil
    }

    private func isThreadVisible(workspace: URL?, archived: Bool) -> Bool {
        if let queryArchived = configuration.query.archived,
           queryArchived != archived {
            return false
        }

        guard let queryWorkspace = configuration.query.workspace else {
            return true
        }

        guard let workspace else {
            return false
        }

        return queryWorkspace.standardizedFileURL.path == workspace.standardizedFileURL.path
    }

    private func removeThread(_ threadID: CodexThreadID) {
        let section = defaultSection()
        section.threads.removeAll { $0.id == threadID }
        if selectedThreadID == threadID {
            selectedThreadID = nil
        }
    }

    private func defaultSection() -> Section {
        if let section = sections.first(where: { $0.id == Section.defaultID }) {
            section.title = configuration.sectionTitle
            return section
        }
        let section = Section(id: Section.defaultID, title: configuration.sectionTitle)
        sections.append(section)
        return section
    }

    private func clearSelectionIfNeeded(in threads: [ThreadSummary]) {
        if let selectedThreadID,
           threads.contains(where: { $0.id == selectedThreadID }) == false {
            self.selectedThreadID = nil
        }
    }

    private func fail(with error: any Error) {
        let message = error.localizedDescription
        lastErrorDescription = message
        phase = .failed(message)
    }

    private func markLoadedIfNeeded() {
        if case .failed = phase {
            return
        }
        phase = .loaded
    }

    @MainActor
    @Observable
    public final class Section {
        public static let defaultID = "threads"

        public let id: String
        public var title: String
        public var threads: [ThreadSummary]

        public init(id: String, title: String, threads: [ThreadSummary] = []) {
            self.id = id
            self.title = title
            self.threads = threads
        }
    }

    @MainActor
    @Observable
    public final class ThreadSummary {
        public let id: CodexThreadID
        public var workspace: URL?
        public var name: String?
        public var preview: String?
        public var turnCount: Int = 0
        public var latestTurnID: CodexTurnID?
        public var latestTurnStatus: CodexTurnStatus?
        public var latestErrorDescription: String?

        public var title: String {
            if let name, name.isEmpty == false {
                return name
            }
            if let preview, preview.isEmpty == false {
                return preview
            }
            if let workspace {
                return workspace.lastPathComponent
            }
            return id.rawValue
        }

        public init(
            id: CodexThreadID,
            workspace: URL? = nil,
            name: String? = nil,
            preview: String? = nil
        ) {
            self.id = id
            self.workspace = workspace
            self.name = name
            self.preview = preview
        }

        fileprivate func update(
            workspace: URL?,
            name: String?,
            preview: String?,
            turns: [CodexTurnSnapshot]
        ) {
            self.workspace = workspace
            self.name = name
            self.preview = preview
            turnCount = turns.count
            latestTurnID = turns.last?.id
            latestTurnStatus = turns.last?.status
            latestErrorDescription = turns.last?.errorMessage
        }
    }
}

public enum CodexThreadLibraryError: Error {
    case noSelection
}
