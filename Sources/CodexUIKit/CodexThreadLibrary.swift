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

    public var phase: CodexUIKitPhase
    public var sections: [Section]
    public var selectedThreadID: CodexThreadID?
    public var nextCursor: String?
    public var backwardsCursor: String?
    public var lastErrorDescription: String?

    @ObservationIgnored
    private let server: CodexAppServer
    public let configuration: Configuration

    public init(
        server: CodexAppServer,
        configuration: Configuration = .init()
    ) {
        self.server = server
        self.configuration = configuration
        self.phase = .idle
        self.sections = []
    }

    public func refresh() async {
        phase = .loading
        lastErrorDescription = nil
        do {
            var query = configuration.query
            query.cursor = nil
            let page = try await server.listThreads(query)
            apply(page.threads, append: false)
            nextCursor = page.nextCursor
            backwardsCursor = page.backwardsCursor
            phase = .loaded
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
        }
    }

    public func loadNextPage() async {
        guard let nextCursor else {
            return
        }
        phase = .loading
        lastErrorDescription = nil
        do {
            var query = configuration.query
            query.cursor = nextCursor
            let page = try await server.listThreads(query)
            apply(page.threads, append: true)
            self.nextCursor = page.nextCursor
            backwardsCursor = page.backwardsCursor
            phase = .loaded
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
        }
    }

    public func selectThread(_ threadID: CodexThreadID?) {
        selectedThreadID = threadID
    }

    @discardableResult
    public func startThread(
        in workspace: URL,
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init()
    ) async throws -> CodexThread {
        phase = .loading
        lastErrorDescription = nil
        do {
            let thread = try await server.startThread(
                in: workspace,
                instructions: instructions,
                options: options
            )
            let snapshot = CodexThreadSnapshot(
                id: thread.id,
                workspace: thread.workspace,
                turns: []
            )
            upsert([snapshot], preferFront: true)
            selectedThreadID = thread.id
            phase = .loaded
            return thread
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    @discardableResult
    public func resumeSelectedThread() async throws -> CodexThread {
        guard let selectedThreadID else {
            throw CodexThreadLibraryError.noSelection
        }
        phase = .loading
        lastErrorDescription = nil
        do {
            let thread = try await server.resumeThread(selectedThreadID)
            upsert([CodexThreadSnapshot(id: thread.id, workspace: thread.workspace, turns: [])])
            phase = .loaded
            return thread
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    public func archive(_ threadID: CodexThreadID) async throws {
        phase = .loading
        lastErrorDescription = nil
        do {
            let thread = try await server.resumeThread(threadID)
            try await thread.archive()
            remove(threadID)
            phase = .loaded
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    public func unarchive(_ threadID: CodexThreadID) async throws {
        phase = .loading
        lastErrorDescription = nil
        do {
            let snapshot = try await server.unarchiveThread(threadID)
            upsert([CodexThreadSnapshot(id: snapshot.id, workspace: snapshot.workspace)])
            phase = .loaded
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    public func delete(_ threadID: CodexThreadID) async throws {
        phase = .loading
        lastErrorDescription = nil
        do {
            try await server.deleteThread(threadID)
            if selectedThreadID == threadID {
                selectedThreadID = nil
            }
            remove(threadID)
            phase = .loaded
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
            throw error
        }
    }

    private func sectionIndex() -> Int {
        let sectionID = Section.defaultID
        if let index = sections.firstIndex(where: { $0.id == sectionID }) {
            return index
        }
        sections.append(Section(id: sectionID, title: configuration.sectionTitle, items: []))
        return sections.count - 1
    }

    private func apply(_ snapshots: [CodexThreadSnapshot], append: Bool) {
        let index = sectionIndex()
        let section = sections[index]
        let sectionItems = apply(snapshots: snapshots, to: section.items, append: append)
        sections[index].items = sectionItems
        if sections[index].title != configuration.sectionTitle {
            sections[index].title = configuration.sectionTitle
        }
        if let selected = selectedThreadID,
           sectionItems.contains(where: { $0.id == selected }) == false {
            selectedThreadID = nil
        }
    }

    private func apply(
        snapshots: [CodexThreadSnapshot],
        to existing: [Item],
        append: Bool
    ) -> [Item] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let incomingItems = snapshots.map { snapshot in
            let item = existingByID[snapshot.id] ?? Item(snapshot: snapshot)
            item.apply(snapshot)
            return item
        }

        let incomingIDs = Set(incomingItems.map(\.id))

        if append {
            let retained = existing.filter { incomingIDs.contains($0.id) == false }
            return retained + incomingItems
        }
        return incomingItems
    }

    private func upsert(_ snapshots: [CodexThreadSnapshot], preferFront: Bool = false) {
        guard snapshots.isEmpty == false else {
            return
        }
        let index = sectionIndex()
        let section = sections[index]
        let existingByID = Dictionary(uniqueKeysWithValues: section.items.map { ($0.id, $0) })
        var items = section.items
        let orderedSnapshots = preferFront ? snapshots.reversed() : snapshots
        for snapshot in orderedSnapshots {
            if let existing = existingByID[snapshot.id] {
                existing.apply(snapshot)
                items.removeAll(where: { $0.id == snapshot.id })
                items.insert(existing, at: 0)
            } else {
                items.insert(Item(snapshot: snapshot), at: 0)
            }
        }
        section.items = items
        section.title = configuration.sectionTitle
        sections[index] = section
    }

    private func remove(_ threadID: CodexThreadID) {
        let index = sectionIndex()
        sections[index].items.removeAll { $0.id == threadID }
        if selectedThreadID == threadID {
            selectedThreadID = nil
        }
    }

    @MainActor
    @Observable
    public final class Section {
        public static let defaultID = "threads"

        public let id: String
        public var title: String
        public var items: [Item]

        public init(
            id: String,
            title: String,
            items: [Item] = []
        ) {
            self.id = id
            self.title = title
            self.items = items
        }
    }

    @MainActor
    @Observable
    public final class Item {
        public let id: CodexThreadID
        public var title: String
        public var subtitle: String?
        public var preview: String?
        public var workspacePath: String?
        public var status: CodexTurnStatus?
        public var turnCount: Int
        public var latestTurnID: CodexTurnID?
        public var errorDescription: String?

        public init(
            id: CodexThreadID,
            title: String,
            subtitle: String? = nil,
            preview: String? = nil,
            workspacePath: String? = nil,
            status: CodexTurnStatus? = nil,
            turnCount: Int = 0,
            latestTurnID: CodexTurnID? = nil,
            errorDescription: String? = nil
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.preview = preview
            self.workspacePath = workspacePath
            self.status = status
            self.turnCount = turnCount
            self.latestTurnID = latestTurnID
            self.errorDescription = errorDescription
        }

        package convenience init(snapshot: CodexThreadSnapshot) {
            let latestTurn = snapshot.turns.last
            self.init(
                id: snapshot.id,
                title: snapshot.codexUIKitTitle,
                subtitle: snapshot.codexUIKitSubtitle,
                preview: snapshot.preview,
                workspacePath: snapshot.workspace?.path,
                status: latestTurn?.status,
                turnCount: snapshot.turns.count,
                latestTurnID: latestTurn?.id,
                errorDescription: latestTurn?.errorMessage
            )
        }

        public func apply(_ snapshot: CodexThreadSnapshot) {
            let latestTurn = snapshot.turns.last
            title = snapshot.codexUIKitTitle
            subtitle = snapshot.codexUIKitSubtitle
            preview = snapshot.preview
            workspacePath = snapshot.workspace?.path
            status = latestTurn?.status
            turnCount = snapshot.turns.count
            latestTurnID = latestTurn?.id
            errorDescription = latestTurn?.errorMessage
        }
    }
}

public enum CodexThreadLibraryError: Error {
    case noSelection
}

private extension CodexThreadSnapshot {
    var codexUIKitTitle: String {
        if let name = name, name.isEmpty == false {
            return name
        }
        if let preview = preview, preview.isEmpty == false {
            return preview
        }
        if let workspace {
            return workspace.lastPathComponent
        }
        return id.rawValue
    }

    var codexUIKitSubtitle: String? {
        workspace?.path
    }
}
