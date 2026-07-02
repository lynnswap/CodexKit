import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Foundation
import Synchronization
import Testing

private actor TestCodexModelActor: CodexModelActor {
    nonisolated let modelContainer: CodexModelContainer
    nonisolated let modelExecutor: any CodexModelExecutor

    init(modelContainer: CodexModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = CodexDefaultSerialModelExecutor(modelContainer: modelContainer)
    }

    func fetchRecentChatIDs() async throws -> [CodexThreadID] {
        try await modelContext.fetch(CodexFetchDescriptor<CodexChat>.recentChats)
            .map(\.id)
    }

    func startReviewID(in workspace: URL, input: CodexReviewInput) async throws -> CodexThreadID {
        let started = try await modelContext.startReview(in: workspace, input: input)
        return started.chat.id
    }
}

@MainActor
struct CodexModelContextTests {
    @Test("container releases its main context without a retain cycle")
    func containerReleasesMainContextWithoutRetainCycle() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        weak var weakContainer: CodexModelContainer?

        do {
            let container = CodexModelContainer(appServer: runtime.server)
            weakContainer = container
            _ = container.mainContext
        }

        #expect(weakContainer == nil)
    }

    @Test("container releases loaded workspace graphs without retain cycles")
    func containerReleasesLoadedWorkspaceGraphsWithoutRetainCycles() async throws {
        weak var weakContainer: CodexModelContainer?
        weak var weakContext: CodexModelContext?
        weak var weakGroup: CodexWorkspaceGroup?
        weak var weakWorkspace: CodexWorkspace?
        weak var weakChat: CodexChat?

        do {
            let runtime = try await CodexAppServerTestRuntime.start()
            let container = CodexModelContainer(appServer: runtime.server)
            let context = container.mainContext
            weakContainer = container
            weakContext = context

            try await runtime.transport.enqueueThreadList(.init(threads: [
                .init(id: "thread-release", workspace: temporaryDirectory(), name: "Release")
            ]))
            let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
            try await results.performFetch()
            let chat = try #require(results.items.first)
            weakChat = chat
            weakWorkspace = chat.workspace
            weakGroup = chat.workspace?.workspaceGroup

            #expect(weakGroup != nil)
            #expect(weakWorkspace != nil)
            #expect(weakChat != nil)
        }

        #expect(weakContainer == nil)
        #expect(weakContext == nil)
        #expect(weakGroup == nil)
        #expect(weakWorkspace == nil)
        #expect(weakChat == nil)
    }

    @Test("model actor creates its own context from a container")
    func modelActorCreatesOwnContextFromContainer() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let container = CodexModelContainer(appServer: runtime.server)
        let modelActor = TestCodexModelActor(modelContainer: container)
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "model-actor-chat", workspace: temporaryDirectory(), name: "Model Actor")
        ]))

        let chatIDs = try await modelActor.fetchRecentChatIDs()

        #expect(chatIDs == [CodexThreadID("model-actor-chat")])
        #expect(container.mainContext.registeredModel(for: CodexThreadID("model-actor-chat")) == nil)
    }

    @Test("parent model refreshes throw after detaching from context")
    func parentModelRefreshesThrowAfterDetachingFromContext() async throws {
        var detachedWorkspace: CodexWorkspace?
        var detachedGroup: CodexWorkspaceGroup?
        weak var weakContext: CodexModelContext?

        do {
            let runtime = try await CodexAppServerTestRuntime.start()
            let container = CodexModelContainer(appServer: runtime.server)
            let context = container.mainContext
            weakContext = context
            let workspaceURL = temporaryDirectory()

            try await runtime.transport.enqueueThreadList(.init(threads: [
                .init(id: "thread-detach", workspace: workspaceURL, name: "Detach")
            ]))
            let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
            try await results.performFetch()
            let chat = try #require(results.items.first)
            guard let workspace = chat.workspace,
                let group = workspace.workspaceGroup
            else {
                Issue.record("Expected fetched chat to have a workspace and group")
                return
            }
            detachedWorkspace = workspace
            detachedGroup = group
        }

        let workspace = try #require(detachedWorkspace)
        let group = try #require(detachedGroup)
        #expect(weakContext == nil)
        #expect(workspace.modelContext == nil)
        #expect(group.modelContext == nil)

        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        do {
            try await context.refresh(workspace)
            Issue.record("Expected detached workspace refresh to throw")
        } catch let error as CodexModelContextError {
            #expect(error == .modelIsDetached)
        } catch {
            Issue.record("Expected modelIsDetached for workspace refresh, got \(error)")
        }

        do {
            try await context.refresh(group)
            Issue.record("Expected detached group refresh to throw")
        } catch let error as CodexModelContextError {
            #expect(error == .modelIsDetached)
        } catch {
            Issue.record("Expected modelIsDetached for group refresh, got \(error)")
        }
    }

    @Test("fetched results use thread/list and mutate existing chat objects")
    func fetchedResultsMutateExistingChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let updatedAt = Date(timeIntervalSince1970: 2_000)

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: "thread-1",
                        name: "First",
                        modelProvider: "openai",
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        turns: [.init(id: "turn-1", status: .running)]
                    )
                ],
                nextCursor: "next"
            ))

        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()

        let first = try #require(results.items.first)
        let firstTurn = try #require(first.turns.first)
        #expect(first.title == "First")
        #expect(first.modelProvider == "openai")
        #expect(first.createdAt == createdAt)
        #expect(first.updatedAt == updatedAt)
        #expect(firstTurn.status == CodexTurnStatus.running)
        #expect(first.modelContext === context)
        #expect(results.nextCursor == "next")

        try await runtime.transport.enqueueThreadList(
            .init(threads: [
                .init(
                    id: "thread-1",
                    name: "First renamed",
                    modelProvider: "openai",
                    createdAt: createdAt,
                    updatedAt: Date(timeIntervalSince1970: 3_000),
                    turns: [.init(id: "turn-1", status: .completed)]
                ),
                .init(id: "thread-2", name: "Second"),
            ]))

        try await results.performFetch()

        #expect(results.items.count == 2)
        #expect(context.model(for: CodexThreadID(rawValue: "thread-1")) === first)
        #expect(results.items.contains { $0 === first })
        #expect(first.title == "First renamed")
        #expect(first.turns.first === firstTurn)
        #expect(firstTurn.status == CodexTurnStatus.completed)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("registered chat lookup does not create placeholders")
    func registeredChatLookupDoesNotCreatePlaceholders() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let threadID = CodexThreadID(rawValue: "thread-unloaded")

        #expect(context.registeredModel(for: threadID) == nil)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").isEmpty)

        let placeholder = context.model(for: threadID)

        #expect(placeholder.id == threadID)
        #expect(context.registeredModel(for: threadID) === placeholder)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").isEmpty)
    }

    @Test("seeded app-server test runtime drives DataKit through public APIs")
    func seededAppServerRuntimeDrivesDataKitThroughPublicAPIs() async throws {
        let workspace = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start(threads: [
            .init(
                id: "thread-seeded",
                workspace: workspace,
                name: "Seeded review",
                preview: "Loaded from fake app-server",
                modelProvider: "gpt-test",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        ])
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()

        let chat = try #require(results.items.first)
        #expect(chat.title == "Seeded review")
        #expect(chat.preview == "Loaded from fake app-server")
        #expect(chat.modelProvider == "gpt-test")
        #expect(chat.workspace?.url == workspace)

        try await context.refresh(chat, includeTurns: false)
        #expect(chat.title == "Seeded review")
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").count == 1)
    }

    @Test("seeded app-server test runtime supports starting chats through DataKit")
    func seededAppServerRuntimeSupportsStartingChatsThroughDataKit() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ])
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let workspaces = try await context.fetch(CodexFetchDescriptor<CodexWorkspace>.workspaces)
        let workspace = try #require(workspaces.first)

        let chat = try await workspace.startChat(.init(
            options: .init(model: "gpt-test", modelProvider: "openai", ephemeral: true)
        ))
        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(chats.first === chat)
        #expect(chat.workspace === workspace)
        #expect(chat.modelProvider == "openai")
        #expect(chat.ephemeral == true)

        let startRequest = try #require(
            await runtime.transport.recordedRequests(method: "thread/start").first)
        let params = try startRequest.decodeParams(ThreadStartParams.self)
        #expect(params.cwd == workspaceURL.path)
        #expect(params.model == "gpt-test")
        #expect(params.modelProvider == "openai")
        #expect(params.ephemeral == true)
    }

    @Test("fetch requests are translated to app-server thread/list query params")
    func fetchRequestTranslatesToThreadListParams() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let request = CodexFetchRequest<CodexChat>(
            predicate: .init(
                archived: true,
                workspace: workspace,
                searchTerm: "needle",
                modelProviders: ["gpt-5"],
                sourceKinds: [.appServer, .subAgent],
                useStateDBOnly: true
            ),
            sortDescriptors: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 25
        )

        _ = try await context.fetch(request)

        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == true)
        #expect(params.cursor == nil)
        #expect(params.cwd == .paths([workspace.path]))
        #expect(params.limit == 25)
        #expect(params.searchTerm == "needle")
        #expect(params.modelProviders == ["gpt-5"])
        #expect(params.sortDirection == "desc")
        #expect(params.sortKey == "recency_at")
        #expect(params.sourceKinds == ["appServer", "subAgent"])
        #expect(params.useStateDbOnly == true)
    }

    @Test("fetch requests pass multiple workspace filters to thread list")
    func fetchRequestTranslatesMultipleWorkspaceFilters() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let app = temporaryDirectory()
        let tools = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        _ = try await context.fetch(CodexFetchRequest<CodexChat>(
            predicate: .init(workspaces: [app, tools])
        ))

        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.cwd == .paths([app.path, tools.path]))
    }

    @Test("key path sort descriptors translate known chat dates to thread list params")
    func keyPathSortDescriptorsTranslateKnownChatDatesToThreadListParams() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let descriptor = CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 25
        )
        _ = try await context.fetch(descriptor)

        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.limit == 25)
        #expect(params.sortDirection == "desc")
        #expect(params.sortKey == "updated_at")
    }

    @Test("query descriptors accept key path sorts and section aliases")
    func queryDescriptorsAcceptKeyPathSortsAndSectionAliases() {
        let workspaceQuery = CodexQuery<CodexWorkspace>(sort: \.name)
        let chatQuery = CodexQuery<CodexChat>(sort: \.updatedAt, order: .reverse)
        let sectionedChatQuery = CodexQuery<CodexChat>(
            filter: .init(archived: false),
            sort: \.recencyAt,
            order: .reverse,
            sectionBy: .workspaceGroup
        )

        #expect(workspaceQuery.wrappedValue.items.isEmpty)
        #expect(chatQuery.wrappedValue.items.isEmpty)
        #expect(sectionedChatQuery.wrappedValue.items.isEmpty)
    }

    @Test("fetched results controller emits an initial fetch transaction")
    func fetchedResultsControllerEmitsInitialFetchTransaction() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))

        let controller = context.fetchedResultsController(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.title)]
        ))
        var transactions = controller.transactions.makeAsyncIterator()

        try await controller.performFetch()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .initialFetch)
        #expect(transaction.isInitialFetch)
        #expect(transaction.oldSnapshot.sections.isEmpty)
        #expect(transaction.newSnapshot.sectionIDs == [.default])
        #expect(transaction.newSnapshot.itemIDs.map(\.rawValue) == ["thread-alpha", "thread-beta"])
        #expect(transaction.sectionChanges == [
            .insert(sectionID: .default, index: 0),
        ])
        #expect(transaction.itemChanges == [
            .insert(
                itemID: CodexThreadID(rawValue: "thread-alpha"),
                indexPath: .init(section: 0, item: 0)
            ),
            .insert(
                itemID: CodexThreadID(rawValue: "thread-beta"),
                indexPath: .init(section: 0, item: 1)
            ),
        ])
        #expect(controller.snapshot == transaction.newSnapshot)
        #expect(controller.items.map(\.id.rawValue) == ["thread-alpha", "thread-beta"])
        #expect(controller.sections.first?.items.first === controller.items.first)
    }

    @Test("workspace-group controller emits section and item inserts")
    func workspaceGroupControllerEmitsSectionAndItemInserts() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archived", workspace: workspaceURL, name: "Archived")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            predicate: .init(archived: true)
        ))
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)
        let groupID = try #require(workspace.workspaceGroup?.id)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let controller = context.fetchedResultsController(
            for: CodexFetchRequest<CodexChat>.recentChats,
            sectionedBy: .workspaceGroup
        )
        var transactions = controller.transactions.makeAsyncIterator()
        try await controller.performFetch()
        _ = await transactions.next()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        let chat = try await workspace.startChat()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .insert)
        #expect(transaction.oldSnapshot.sections.isEmpty)
        #expect(transaction.newSnapshot.sectionIDs == [.workspaceGroup(groupID)])
        #expect(transaction.newSnapshot.itemIDs == [chat.id])
        #expect(transaction.sectionChanges == [
            .insert(sectionID: .workspaceGroup(groupID), index: 0),
        ])
        #expect(transaction.itemChanges == [
            .insert(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(controller.items.first === chat)
        #expect(controller.sections.first?.items.first === chat)
    }

    @Test("workspace-group controller emits section and item deletes when archiving")
    func workspaceGroupControllerEmitsDeletesWhenArchiving() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let controller = context.fetchedResultsController(
            for: CodexFetchRequest<CodexChat>.recentChats,
            sectionedBy: .workspaceGroup
        )
        var transactions = controller.transactions.makeAsyncIterator()
        try await controller.performFetch()
        _ = await transactions.next()

        let chat = try #require(controller.items.first)
        let groupID = try #require(chat.workspace?.workspaceGroup?.id)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await chat.archive()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .archive)
        #expect(transaction.oldSnapshot.sectionIDs == [.workspaceGroup(groupID)])
        #expect(transaction.newSnapshot.sections.isEmpty)
        #expect(transaction.sectionChanges == [
            .delete(sectionID: .workspaceGroup(groupID), index: 0),
        ])
        #expect(transaction.itemChanges == [
            .delete(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(controller.items.isEmpty)
        #expect(controller.sections.isEmpty)
    }

    @Test("unsectioned controller emits item and default-section deletes when deleting")
    func unsectionedControllerEmitsDeletesWhenDeleting() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-delete", name: "Delete")
        ]))
        let controller = context.fetchedResultsController(
            for: CodexFetchRequest<CodexChat>.recentChats
        )
        var transactions = controller.transactions.makeAsyncIterator()
        try await controller.performFetch()
        _ = await transactions.next()

        let chat = try #require(controller.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await chat.delete()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .remove)
        #expect(transaction.oldSnapshot.sectionIDs == [.default])
        #expect(transaction.newSnapshot.sections.isEmpty)
        #expect(transaction.sectionChanges == [
            .delete(sectionID: .default, index: 0),
        ])
        #expect(transaction.itemChanges == [
            .delete(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(controller.items.isEmpty)
        #expect(controller.sections.isEmpty)
    }

    @Test("workspace controller reloads stable rows after chat deletion")
    func workspaceControllerReloadsStableRowsAfterChatDeletion() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete"),
            .init(id: "thread-keep", workspace: workspaceURL, name: "Keep"),
        ]))
        let controller = context.fetchedResultsController(
            for: CodexFetchRequest<CodexWorkspace>.workspaces
        )
        var transactions = controller.transactions.makeAsyncIterator()
        try await controller.performFetch()
        _ = await transactions.next()
        let workspace = try #require(controller.items.first)
        let chat = try #require(workspace.chats.first { $0.id.rawValue == "thread-delete" })

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await chat.delete()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .remove)
        #expect(transaction.sectionChanges.isEmpty)
        #expect(transaction.itemChanges == [
            .update(itemID: workspace.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(controller.items.first === workspace)
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-keep"])
    }

    @Test("controller does not emit moves for item shifts after deletion")
    func controllerDoesNotEmitMovesForItemShiftsAfterDeletion() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        let controller = context.fetchedResultsController(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.title)]
        ))
        var transactions = controller.transactions.makeAsyncIterator()
        try await controller.performFetch()
        _ = await transactions.next()
        let alpha = try #require(controller.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await alpha.delete()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .remove)
        #expect(transaction.itemChanges == [
            .delete(itemID: alpha.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(controller.items.map(\.title) == ["Beta"])
    }

    @Test("workspace-group controller does not emit moves for section shifts after deletion")
    func workspaceGroupControllerDoesNotEmitMovesForSectionShiftsAfterDeletion() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try gitRepository(named: "First")
        let secondRepo = try gitRepository(named: "Second")
        let firstWorkspaceURL = try createDirectory("App", in: firstRepo)
        let secondWorkspaceURL = try createDirectory("App", in: secondRepo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: secondWorkspaceURL, name: "Beta"),
        ]))
        let controller = context.fetchedResultsController(
            for: CodexFetchRequest<CodexChat>(
                sortDescriptors: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: .workspaceGroup
        )
        var transactions = controller.transactions.makeAsyncIterator()
        try await controller.performFetch()
        _ = await transactions.next()
        let alpha = try #require(controller.items.first)
        let firstGroupID = try #require(alpha.workspace?.workspaceGroup?.id)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await alpha.delete()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .remove)
        #expect(transaction.sectionChanges == [
            .delete(sectionID: .workspaceGroup(firstGroupID), index: 0),
        ])
        #expect(transaction.itemChanges == [
            .delete(itemID: alpha.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(controller.items.map(\.title) == ["Beta"])
        #expect(controller.sections.count == 1)
    }

    @Test("workspace-group controller suppresses no-op moves in mixed refresh diffs")
    func workspaceGroupControllerSuppressesNoOpMovesInMixedRefreshDiffs() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try gitRepository(named: "First")
        let secondRepo = try gitRepository(named: "Second")
        let thirdRepo = try gitRepository(named: "Third")
        let firstWorkspaceURL = try createDirectory("App", in: firstRepo)
        let secondWorkspaceURL = try createDirectory("App", in: secondRepo)
        let thirdWorkspaceURL = try createDirectory("App", in: thirdRepo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: secondWorkspaceURL, name: "Beta"),
        ]))
        let controller = context.fetchedResultsController(
            for: CodexFetchRequest<CodexChat>(
                sortDescriptors: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: .workspaceGroup
        )
        var transactions = controller.transactions.makeAsyncIterator()
        try await controller.performFetch()
        _ = await transactions.next()
        let alpha = try #require(controller.items.first { $0.id.rawValue == "thread-alpha" })
        let beta = try #require(controller.items.first { $0.id.rawValue == "thread-beta" })
        let firstGroupID = try #require(alpha.workspace?.workspaceGroup?.id)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-gamma", workspace: thirdWorkspaceURL, name: "Aardvark"),
            .init(id: "thread-beta", workspace: secondWorkspaceURL, name: "Beta"),
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Zulu"),
        ]))

        try await controller.refresh()

        let transaction = try #require(await transactions.next())
        let gamma = try #require(controller.items.first { $0.id.rawValue == "thread-gamma" })
        let thirdGroupID = try #require(gamma.workspace?.workspaceGroup?.id)
        #expect(transaction.reason == .refresh)
        #expect(transaction.sectionChanges == [
            .insert(sectionID: .workspaceGroup(thirdGroupID), index: 0),
            .move(sectionID: .workspaceGroup(firstGroupID), from: 0, to: 2),
        ])
        #expect(transaction.itemChanges == [
            .insert(itemID: gamma.id, indexPath: .init(section: 0, item: 0)),
            .update(itemID: beta.id, indexPath: .init(section: 1, item: 0)),
            .update(itemID: alpha.id, indexPath: .init(section: 2, item: 0)),
        ])
    }

    @Test("workspace-group controller emits delete and insert for non-surviving section moves")
    func workspaceGroupControllerEmitsDeleteInsertForNonSurvivingSectionMoves() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try gitRepository(named: "First")
        let secondRepo = try gitRepository(named: "Second")
        let firstWorkspaceURL = try createDirectory("App", in: firstRepo)
        let secondWorkspaceURL = try createDirectory("App", in: secondRepo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: firstWorkspaceURL, name: "Move"),
        ]))
        let controller = context.fetchedResultsController(
            for: CodexFetchRequest<CodexChat>(
                sortDescriptors: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: .workspaceGroup
        )
        var transactions = controller.transactions.makeAsyncIterator()
        try await controller.performFetch()
        _ = await transactions.next()
        let chat = try #require(controller.items.first)
        let firstGroupID = try #require(chat.workspace?.workspaceGroup?.id)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: secondWorkspaceURL,
            name: "Move"
        ))
        try await context.refresh(chat, includeTurns: false)

        let transaction = try #require(await transactions.next())
        let secondGroupID = try #require(chat.workspace?.workspaceGroup?.id)
        #expect(transaction.reason == .revalidate)
        #expect(transaction.sectionChanges == [
            .delete(sectionID: .workspaceGroup(firstGroupID), index: 0),
            .insert(sectionID: .workspaceGroup(secondGroupID), index: 0),
        ])
        #expect(transaction.itemChanges == [
            .delete(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
            .insert(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
        ])
    }

    @Test("controller suppresses unrelated revalidation transactions")
    func controllerSuppressesUnrelatedRevalidationTransactions() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try gitRepository(named: "First")
        let secondRepo = try gitRepository(named: "Second")
        let firstWorkspaceURL = try createDirectory("App", in: firstRepo)
        let secondWorkspaceURL = try createDirectory("App", in: secondRepo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: secondWorkspaceURL, name: "Beta"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.title)]
        ))
        try await allResults.performFetch()
        let alpha = try #require(allResults.items.first { $0.id.rawValue == "thread-alpha" })
        let beta = try #require(allResults.items.first { $0.id.rawValue == "thread-beta" })
        let firstWorkspace = try #require(alpha.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Alpha"),
        ]))
        let controller = context.fetchedResultsController(
            for: CodexFetchRequest<CodexChat>.chats(
                in: firstWorkspace,
                sortDescriptors: [CodexSortDescriptor(\.title)]
            )
        )
        let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
        try await controller.performFetch()
        #expect(await eventually { recorder.transactions.count == 1 })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-beta"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-beta",
            workspace: secondWorkspaceURL,
            name: "Beta Updated"
        ))
        try await context.refresh(beta, includeTurns: false)

        #expect(await recorder.count(after: .milliseconds(20)) == 1)
        #expect(controller.items.map(\.id) == [alpha.id])
    }

    @Test("controller keeps update changes for items that move")
    func controllerKeepsUpdateChangesForItemsThatMove() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        let controller = context.fetchedResultsController(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.title)]
        ))
        var transactions = controller.transactions.makeAsyncIterator()
        try await controller.performFetch()
        _ = await transactions.next()
        let alpha = try #require(controller.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-alpha",
            name: "Zulu"
        ))
        try await context.refresh(alpha, includeTurns: false)

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .revalidate)
        #expect(controller.items.map(\.title) == ["Beta", "Zulu"])
        #expect(transaction.itemChanges.contains(
            .move(
                itemID: alpha.id,
                from: .init(section: 0, item: 0),
                to: .init(section: 0, item: 1)
            )
        ))
        #expect(transaction.itemChanges.contains(
            .update(itemID: alpha.id, indexPath: .init(section: 0, item: 1))
        ))
    }

    @Test("fetched chat exposes app-server thread status and recency")
    func fetchedChatExposesThreadStatusAndRecency() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let recencyAt = Date(timeIntervalSince1970: 1234)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-active",
                name: "Active",
                recencyAt: recencyAt,
                status: .active(activeFlags: [.waitingOnUserInput])
            )
        ]))

        let chats = try await context.fetch(CodexFetchRequest<CodexChat>.recentChats)
        let chat = try #require(chats.first)

        #expect(chat.recencyAt == recencyAt)
        #expect(chat.status == .active(activeFlags: [.waitingOnUserInput]))
    }

    @Test("fetched results apply configured fetch offset on initial fetch")
    func fetchedResultsApplyConfiguredFetchOffsetOnInitialFetch() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-a", name: "A"),
            .init(id: "thread-b", name: "B"),
        ]))

        let request = CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1,
            fetchOffset: 1
        )
        let results = context.fetchedResults(for: request)
        try await results.performFetch()

        #expect(results.items.map(\.title) == ["B"])
    }

    @Test("offset chat fetches do not preserve live chats omitted from the page")
    func offsetChatFetchesDoNotPreserveLiveChatsOmittedFromPage() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let liveChat = context.model(for: CodexThreadID(rawValue: "thread-a"))
        liveChat.apply(
            .init(
                id: "thread-a",
                name: "A",
                status: .active(activeFlags: [])
            ),
            workspace: nil
        )

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-b", name: "B"),
            .init(id: "thread-c", name: "C"),
        ]))

        let request = CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1,
            fetchOffset: 1
        )
        let results = context.fetchedResults(for: request)
        try await results.performFetch()

        #expect(results.items.map(\.title) == ["C"])
    }

    @Test("name-sorted chat pages are sliced after local sorting")
    func nameSortedChatPagesAreSlicedAfterLocalSorting() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [.init(id: "thread-zulu", workspace: workspace, name: "Zulu")],
                nextCursor: "server-next"
            ))
        try await runtime.transport.enqueueThreadList(
            .init(threads: [.init(id: "thread-alpha", workspace: workspace, name: "Alpha")]))

        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()

        let fetchedWorkspace = try #require(results.items.first?.workspace)
        #expect(results.items.map(\.title) == ["Alpha"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])
        #expect(results.nextCursor?.isEmpty == false)

        let initialRequests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(initialRequests.count == 2)
        let firstParams = try #require(initialRequests.first).decodeParams(ThreadListParams.self)
        let secondParams = try #require(initialRequests.dropFirst().first)
            .decodeParams(ThreadListParams.self)
        #expect(firstParams.cursor == nil)
        #expect(firstParams.limit == nil)
        #expect(secondParams.cursor == "server-next")
        #expect(secondParams.limit == nil)

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [.init(id: "thread-zulu", workspace: workspace, name: "Zulu")],
                nextCursor: "server-next"
            ))
        try await runtime.transport.enqueueThreadList(
            .init(threads: [.init(id: "thread-alpha", workspace: workspace, name: "Alpha")]))

        try await results.loadNextPage()

        #expect(results.items.map(\.title) == ["Alpha", "Zulu"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])
        #expect(results.nextCursor == nil)
    }

    @Test("appended local pages preserve the loaded window backwards cursor")
    func appendedLocalPagesPreserveLoadedWindowBackwardsCursor() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()
        let page = CodexThreadPage(threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspace, name: "Beta"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ])

        try await runtime.transport.enqueueThreadList(page)
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.title) == ["Alpha"])
        #expect(results.backwardsCursor == nil)

        try await runtime.transport.enqueueThreadList(page)
        try await results.loadNextPage()

        #expect(results.items.map(\.title) == ["Alpha", "Beta"])
        #expect(results.backwardsCursor == nil)
    }

    @Test("appended local pages preserve live chats omitted from complete relationships")
    func appendedLocalPagesPreserveLiveChatsOmittedFromCompleteRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-running",
                workspace: workspace,
                name: "A Running",
                status: .active(activeFlags: [])
            ),
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.id.rawValue) == ["thread-running"])
        #expect(results.nextCursor != nil)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.id.rawValue).contains("thread-running"))
        #expect(results.items.first?.id.rawValue == "thread-running")
    }

    @Test("local paged chat load reconciles stale loaded items")
    func localPagedChatLoadReconcilesStaleLoadedItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.title) == ["Alpha"])

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-beta", workspace: workspace, name: "Beta"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.title) == ["Beta", "Zulu"])
    }

    @Test("name-sorted chat pages prune stale workspace relationships from full local results")
    func nameSortedChatPagesPruneStaleWorkspaceRelationshipsFromFullLocalResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)
        let staleChat = context.model(for: CodexThreadID(rawValue: "thread-zulu"))
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspace, name: "Beta"),
        ]))
        try await results.refresh()

        #expect(results.items.map(\.title) == ["Alpha"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Beta"])
        #expect(staleChat.workspace == nil)
    }

    @Test("one-shot name-sorted fetches prune stale workspace relationships from full local results")
    func oneShotNameSortedFetchesPruneStaleWorkspaceRelationshipsFromFullLocalResults()
        async throws
    {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        let allChats = try await context.fetch(CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)]
        ))
        let fetchedWorkspace = try #require(allChats.first?.workspace)
        let staleChat = context.model(for: CodexThreadID(rawValue: "thread-zulu"))
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspace, name: "Beta"),
        ]))
        let firstPage = try await context.fetch(CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))

        #expect(firstPage.map(\.title) == ["Alpha"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Beta"])
        #expect(staleChat.workspace == nil)
    }

    @Test("one-shot chat fetch notifies registered results after pruning stale chats")
    func oneShotChatFetchNotifiesRegisteredResultsAfterPruningStaleChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()
        let initialPage = CodexThreadPage(threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale")
        ])

        try await runtime.transport.enqueueThreadList(initialPage)
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueThreadList(initialPage)
        let chatResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)]
        ))
        try await chatResults.performFetch()

        try await runtime.transport.enqueueThreadList(initialPage)
        let groupResults = context.fetchedResults(
            for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups
        )
        try await groupResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        _ = try await context.fetch(CodexFetchRequest<CodexChat>.recentChats)

        #expect(chatResults.items.isEmpty)
        #expect(workspaceResults.items.isEmpty)
        #expect(workspaceResults.sections.isEmpty)
        #expect(groupResults.items.isEmpty)
        #expect(groupResults.sections.isEmpty)
    }

    @Test("thread list fetch inserts first-seen chats into registered scoped results")
    func threadListFetchInsertsFirstSeenChatsIntoRegisteredScopedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialPage = CodexThreadPage(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ])

        try await runtime.transport.enqueueThreadList(initialPage)
        let initialChats = try await context.fetch(CodexFetchRequest<CodexChat>.recentChats)
        let workspace = try #require(initialChats.first?.workspace)

        try await runtime.transport.enqueueThreadList(initialPage)
        let scopedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.chats(
            in: workspace,
            sortDescriptors: [CodexSortDescriptor(\.name)]
        ), sectionedBy: CodexSectionDescriptor(\.workspaceID))
        try await scopedResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing"),
            .init(id: "thread-new", workspace: workspaceURL, name: "New"),
        ]))
        _ = try await context.fetch(CodexFetchRequest<CodexChat>.recentChats)

        #expect(scopedResults.items.map(\.id.rawValue) == ["thread-existing", "thread-new"])
        #expect(scopedResults.sections.count == 1)
        #expect(scopedResults.sections.first?.items.map(\.id.rawValue) == [
            "thread-existing",
            "thread-new",
        ])
    }

    @Test("workspace-scoped chat fetch applies scoped workspace when snapshots omit cwd")
    func workspaceScopedChatFetchAppliesScopedWorkspaceWhenSnapshotsOmitCWD() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueJSON(
            """
            {
              "data": [
                {
                  "id": "thread-new",
                  "name": "New"
                }
              ]
            }
            """,
            for: "thread/list"
        )
        let scopedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.chats(
            in: workspace
        ))
        try await scopedResults.performFetch()

        let chat = try #require(scopedResults.items.first)
        #expect(chat.workspace === workspace)
        #expect(workspace.chats.first === chat)
        #expect(chat.title == "New")
    }

    @Test("thread list fetch inserts first-seen parents into registered results")
    func threadListFetchInsertsFirstSeenParentsIntoRegisteredResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let groupResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups)
        try await groupResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-new", workspace: workspaceURL, name: "New")
        ]))
        _ = try await context.fetch(CodexFetchRequest<CodexChat>.recentChats)

        let workspace = try #require(workspaceResults.items.first)
        let group = try #require(groupResults.items.first)
        #expect(workspaceResults.items.count == 1)
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-new"])
        #expect(groupResults.items.count == 1)
        #expect(group.workspaces.contains { $0 === workspace })
        #expect(workspaceResults.sections.count == 1)
        #expect(groupResults.sections.count == 1)
    }

    @Test("workspace chats preserve fetched chat order")
    func workspaceChatsPreserveFetchedChatOrder() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
        ]))

        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)]
        ))
        try await results.performFetch()

        let fetchedWorkspace = try #require(results.items.first?.workspace)
        #expect(results.items.map(\.title) == ["Alpha", "Zulu"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])
    }

    @Test("filtered chat fetches keep previously loaded workspace chats")
    func filteredChatFetchesKeepPreviouslyLoadedWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-keep", workspace: workspace, name: "Keep"),
            .init(id: "thread-match", workspace: workspace, name: "Match"),
        ]))
        let allChats = try await context.fetch(CodexFetchRequest<CodexChat>.recentChats)
        let fetchedWorkspace = try #require(allChats.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-match", workspace: workspace, name: "Match")
        ]))
        let filteredResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(searchTerm: "Match")
        ))
        try await filteredResults.performFetch()

        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == ["thread-keep", "thread-match"])
    }

    @Test("empty search terms behave like unfiltered chat fetches")
    func emptySearchTermsBehaveLikeUnfilteredChatFetches() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(searchTerm: "")
        ))
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let firstParams = try #require(requests.first).decodeParams(ThreadListParams.self)
        #expect(firstParams.searchTerm == nil)
        #expect(results.items.map(\.id.rawValue) == ["thread-remaining"])
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("empty source-kind filters behave like unfiltered chat fetches")
    func emptySourceKindFiltersBehaveLikeUnfilteredChatFetches() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(sourceKinds: [])
        ))
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let firstParams = try #require(requests.first).decodeParams(ThreadListParams.self)
        #expect(firstParams.sourceKinds == nil)
        #expect(results.items.map(\.id.rawValue) == ["thread-remaining"])
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("filtered workspace fetches keep previously loaded workspace chats")
    func filteredWorkspaceFetchesKeepPreviouslyLoadedWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-keep", workspace: workspace, name: "Keep"),
            .init(id: "thread-match", workspace: workspace, name: "Match"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await allResults.performFetch()
        let fetchedWorkspace = try #require(allResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-match", workspace: workspace, name: "Match")
        ]))
        let filteredResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            predicate: .init(searchTerm: "Match")
        ))
        try await filteredResults.performFetch()

        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == ["thread-keep", "thread-match"])
    }

    @Test("unfiltered chat refresh prunes stale workspace chats")
    func unfilteredChatRefreshPrunesStaleWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)
        let staleChat = try #require(results.items.first { $0.id.rawValue == "thread-stale" })

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
        #expect(staleChat.workspace == nil)
    }

    @Test("workspace fetch preserves live-only workspace omitted from refresh")
    func workspaceFetchPreservesLiveOnlyWorkspaceOmittedFromRefresh() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-running",
                workspace: workspace,
                name: "Running",
                status: .active(activeFlags: [])
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first)
        let runningChat = try #require(fetchedWorkspace.chats.first)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await results.refresh()

        #expect(results.items.map(\.url) == [workspace])
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-running"])
        #expect(runningChat.workspace === fetchedWorkspace)
    }

    @Test("workspace group fetch preserves live-only workspace omitted from refresh")
    func workspaceGroupFetchPreservesLiveOnlyWorkspaceOmittedFromRefresh() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository(named: "LiveOnly")
        let workspace = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-running",
                workspace: workspace,
                name: "Running",
                status: .active(activeFlags: [])
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups)
        try await results.performFetch()
        let group = try #require(results.items.first)
        let fetchedWorkspace = try #require(group.workspaces.first)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await results.refresh()

        #expect(results.items.map(\.id) == [group.id])
        #expect(group.workspaces.map(\.url) == [workspace])
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-running"])
    }

    @Test("started review prepared threads do not preserve stale fetched chat rows")
    func startedReviewPreparedThreadsDoNotPreserveStaleFetchedChatRows() async throws {
        let workspace = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            .init(
                id: "turn-review",
                status: .running,
                items: [
                    .init(
                        id: "review-mode",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
            reviewThreadID: "thread-review"
        )

        let started = try await context.startReview(
            in: workspace,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let chat = started.chat
        #expect(chat.workspace != nil)

        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-review",
            workspace: workspace,
            status: .idle
        ))
        try await context.refresh(chat, includeTurns: false)
        #expect(chat.status == .idle)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()

        #expect(results.items.isEmpty)
        #expect(chat.workspace == nil)
    }

    @Test("archived false chat refresh prunes stale workspace chats")
    func archivedFalseChatRefreshPrunesStaleWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(archived: false),
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("chat refresh removes chat from previous workspace when reparented")
    func chatRefreshRemovesChatFromPreviousWorkspaceWhenReparented() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let oldWorkspaceURL = temporaryDirectory()
        let newWorkspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let oldWorkspace = try #require(chat.workspace)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: newWorkspaceURL,
            name: "Move"
        ))
        try await context.refresh(chat, includeTurns: false)

        #expect(oldWorkspace.chats.isEmpty)
        #expect(chat.workspace?.url == newWorkspaceURL)
        #expect(chat.workspace?.chats.first === chat)
    }

    @Test("chat refresh revalidates active fetched results")
    func chatRefreshRevalidatesActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let oldWorkspaceURL = temporaryDirectory()
        let newWorkspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let allResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await allResults.performFetch()
        let chat = try #require(allResults.items.first)
        let oldWorkspace = try #require(chat.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let oldWorkspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.chats(
            in: oldWorkspace
        ))
        try await oldWorkspaceResults.performFetch()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: newWorkspaceURL,
            name: "Move"
        ))
        try await context.refresh(chat, includeTurns: false)

        #expect(oldWorkspaceResults.items.isEmpty)
        #expect(allResults.items.first === chat)
    }

    @Test("thread list fetch revalidates workspace scoped fetched results")
    func threadListFetchRevalidatesWorkspaceScopedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let oldWorkspaceURL = temporaryDirectory()
        let newWorkspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let allResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await allResults.performFetch()
        let chat = try #require(allResults.items.first)
        let oldWorkspace = try #require(chat.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let oldWorkspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.chats(
            in: oldWorkspace
        ))
        try await oldWorkspaceResults.performFetch()
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let sectionedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)]
        ), sectionedBy: CodexSectionDescriptor(\.workspaceID))
        try await sectionedResults.performFetch()
        let oldWorkspaceSectionID = CodexFetchSectionID.workspace(.init(rawValue: oldWorkspaceURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path))
        #expect(sectionedResults.sections.first?.id == oldWorkspaceSectionID)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: newWorkspaceURL, name: "Move")
        ]))
        let fetchedChats = try await context.fetch(CodexFetchRequest<CodexChat>.recentChats)
        let newWorkspaceSectionID = CodexFetchSectionID.workspace(.init(rawValue: newWorkspaceURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path))

        #expect(fetchedChats.first === chat)
        #expect(chat.workspace?.url == newWorkspaceURL)
        #expect(oldWorkspaceResults.items.isEmpty)
        #expect(sectionedResults.items.first === chat)
        #expect(sectionedResults.sections.first?.id == newWorkspaceSectionID)
    }

    @Test("thread list fetch revalidates metadata sorted fetched results")
    func threadListFetchRevalidatesMetadataSortedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialPage = CodexThreadPage(threads: [
            .init(
                id: "thread-alpha",
                workspace: workspaceURL,
                name: "Alpha",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
            .init(
                id: "thread-zulu",
                workspace: workspaceURL,
                name: "Zulu",
                updatedAt: Date(timeIntervalSince1970: 2_000)
            ),
        ])

        try await runtime.transport.enqueueThreadList(initialPage)
        let nameResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)]
        ))
        try await nameResults.performFetch()

        try await runtime.transport.enqueueThreadList(initialPage)
        let updatedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await updatedResults.performFetch()

        try await runtime.transport.enqueueThreadList(initialPage)
        let sectionedNameResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)]
        ), sectionedBy: CodexSectionDescriptor(\.workspaceID))
        try await sectionedNameResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-alpha",
                workspace: workspaceURL,
                name: "Omega",
                updatedAt: Date(timeIntervalSince1970: 3_000)
            ),
            .init(
                id: "thread-zulu",
                workspace: workspaceURL,
                name: "Aardvark",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))
        _ = try await context.fetch(CodexFetchRequest<CodexChat>.recentChats)

        #expect(nameResults.items.map(\.title) == ["Aardvark", "Omega"])
        #expect(updatedResults.items.map(\.title) == ["Omega", "Aardvark"])
        #expect(sectionedNameResults.items.map(\.title) == ["Aardvark", "Omega"])
        #expect(sectionedNameResults.sections.first?.items.map(\.title) == ["Aardvark", "Omega"])
    }

    @Test("chat refresh preserves archived fetched result membership")
    func chatRefreshPreservesArchivedFetchedResultMembership() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archived", workspace: workspaceURL, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(archived: true),
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let chat = try #require(archivedResults.items.first)
        #expect(chat.isArchived)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let activeResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await activeResults.performFetch()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-archived"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-archived",
            workspace: workspaceURL,
            name: "Archived"
        ))
        try await context.refresh(chat, includeTurns: false)

        #expect(archivedResults.items.first === chat)
        #expect(activeResults.items.isEmpty)
    }

    @Test("archived fetch revalidates active fetched result membership")
    func archivedFetchRevalidatesActiveFetchedResultMembership() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let activeResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await activeResults.performFetch()
        let chat = try #require(activeResults.items.first)
        #expect(chat.isArchived == false)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(archived: true),
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()

        #expect(chat.isArchived)
        #expect(activeResults.items.isEmpty)
        #expect(archivedResults.items.first === chat)
    }

    @Test("chat refresh preserves server-only filtered fetched results")
    func chatRefreshPreservesServerOnlyFilteredFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-source", workspace: workspaceURL, name: "Source")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-source",
            workspace: workspaceURL,
            name: "Source"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-source", workspace: workspaceURL, name: "Source")
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.first === chat)
    }

    @Test("chat refresh rebuilds server-only filtered sections")
    func chatRefreshRebuildsServerOnlyFilteredSections() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let oldWorkspaceURL = temporaryDirectory()
        let newWorkspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-source", workspace: oldWorkspaceURL, name: "Source")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(sourceKinds: [.appServer])
        ), sectionedBy: CodexSectionDescriptor(\.workspaceID))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(
            results.sections.first?.id == .workspace(.init(rawValue: oldWorkspaceURL.standardizedFileURL
                .resolvingSymlinksInPath().path))
        )

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-source",
            workspace: newWorkspaceURL,
            name: "Source"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-source", workspace: newWorkspaceURL, name: "Source")
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.first === chat)
        #expect(
            results.sections.first?.id == .workspace(.init(rawValue: newWorkspaceURL.standardizedFileURL
                .resolvingSymlinksInPath().path))
        )
    }

    @Test("recency sort preserves app-server ordering")
    func recencySortPreservesAppServerOrdering() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-server-first",
                name: "Server first",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
            .init(
                id: "thread-server-second",
                name: "Server second",
                updatedAt: Date(timeIntervalSince1970: 2_000)
            ),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchRequest<CodexChat>(sortDescriptors: [CodexSortDescriptor(\.recencyAt, order: .reverse)])
        )
        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == ["thread-server-first", "thread-server-second"])
    }

    @Test("primary recency sort preserves app-server ordering when secondary descriptors exist")
    func primaryRecencySortPreservesAppServerOrderingWithSecondaryDescriptors() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-zulu", name: "Zulu"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchRequest<CodexChat>(sortDescriptors: [CodexSortDescriptor(\.recencyAt, order: .reverse), CodexSortDescriptor(\.name)])
        )
        try await results.performFetch()

        #expect(results.items.map(\.title) == ["Zulu", "Alpha"])
    }

    @Test("primary recency sort keeps server paging with secondary descriptors")
    func primaryRecencySortKeepsServerPagingWithSecondaryDescriptors() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [.init(id: "thread-zulu", name: "Zulu")],
                nextCursor: "server-next"
            ))
        try await runtime.transport.enqueueThreadList(
            .init(threads: [.init(id: "thread-alpha", name: "Alpha")]))

        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.recencyAt, order: .reverse), CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let params = try #require(requests.first).decodeParams(ThreadListParams.self)
        #expect(requests.count == 1)
        #expect(params.limit == 1)
        #expect(params.sortKey == "recency_at")
        #expect(results.nextCursor == "server-next")
    }

    @Test("default chat ordering reloads app-server order after refresh")
    func defaultChatOrderingReloadsAppServerOrderAfterRefresh() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>())
        try await results.performFetch()
        let alpha = try #require(results.items.first { $0.id.rawValue == "thread-alpha" })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-alpha", name: "Alpha"))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-beta", name: "Beta"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))
        try await context.refresh(alpha, includeTurns: false)

        #expect(results.items.map(\.id.rawValue) == ["thread-beta", "thread-alpha"])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("non-recency sort descriptors still apply when recency is present")
    func nonRecencySortDescriptorsStillApplyWhenRecencyIsPresent() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-zulu", name: "Zulu"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchRequest<CodexChat>(sortDescriptors: [CodexSortDescriptor(\.name), CodexSortDescriptor(\.recencyAt, order: .reverse)])
        )
        try await results.performFetch()

        #expect(results.items.map(\.title) == ["Alpha", "Zulu"])
    }

    @Test("reverse date sorts keep missing dates behind dated chats")
    func reverseDateSortsKeepMissingDatesBehindDatedChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-undated", name: "Undated"),
            .init(
                id: "thread-dated",
                name: "Dated",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchRequest<CodexChat>(sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)])
        )
        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == ["thread-dated", "thread-undated"])
    }

    @Test("workspace and chat fetches can be sectioned by relationship aliases")
    func fetchesSupportWorkspaceSections() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        let page = CodexThreadPage(threads: [
            .init(id: "thread-app", workspace: app, name: "App chat"),
            .init(id: "thread-tools", workspace: tools, name: "Tools chat"),
        ])
        try await runtime.transport.enqueueThreadList(page)

        #expect(CodexSectionDescriptor<CodexWorkspace>.workspaceGroup == .init(\.workspaceGroupID))
        #expect(CodexSectionDescriptor<CodexChat>.workspaceGroup == .init(\.workspaceGroupID))
        #expect(CodexSectionDescriptor<CodexChat>.workspace == .init(\.workspaceID))

        let workspaceResults = context.fetchedResults(
            for: CodexFetchRequest<CodexWorkspace>.workspaces(),
            sectionedBy: .workspaceGroup
        )
        try await workspaceResults.performFetch()

        let workspaceSection = try #require(workspaceResults.sections.first)
        #expect(workspaceResults.items.map(\.name).sorted() == ["App", "Tools"])
        #expect(workspaceResults.sections.count == 1)
        #expect(workspaceSection.title == repo.lastPathComponent)
        #expect(workspaceSection.items.map(\.name).sorted() == ["App", "Tools"])
        let workspaceGroup = try #require(workspaceSection.workspaceGroup)
        #expect(workspaceSection.workspaceGroupID == workspaceGroup.id)
        #expect(workspaceSection.workspaces.map(\.id) == workspaceSection.items.map(\.id))

        try await runtime.transport.enqueueThreadList(page)

        let chatResults = context.fetchedResults(
            for: CodexFetchRequest<CodexChat>(
                sortDescriptors: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: .workspace
        )
        try await chatResults.performFetch()

        #expect(chatResults.sections.compactMap(\.title).sorted() == ["App", "Tools"])
        #expect(
            chatResults.items.map(\.workspace?.workspaceGroup?.id).allSatisfy {
                $0 == workspaceResults.items.first?.workspaceGroup?.id
            })
        let appSection = try #require(chatResults.sections.first { $0.title == "App" })
        let appWorkspace = try #require(appSection.workspaces.first)
        #expect(appSection.workspaceID == appWorkspace.id)
        #expect(appSection.workspaceGroup === workspaceGroup)
        #expect(appSection.workspaces.map(\.name) == ["App"])
        #expect(appSection.uncategorizedChats.isEmpty)
        #expect(appSection.chats(in: appWorkspace.id).map(\.id.rawValue) == ["thread-app"])
        #expect(appSection.chat(id: "thread-app")?.id.rawValue == "thread-app")
        #expect(appSection.chat(id: "thread-tools")?.id.rawValue == nil)
    }

    @Test("chat section exposes uncategorized chats")
    func chatSectionExposesUncategorizedChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: workspaceURL, name: "App"),
            .init(id: "thread-uncategorized", name: "Uncategorized"),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchRequest<CodexChat>(
                sortDescriptors: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: CodexSectionDescriptor(\.workspaceID)
        )
        try await results.performFetch()

        let section = try #require(results.sections.first { $0.uncategorizedChats.isEmpty == false })
        #expect(section.workspaceGroupID == nil)
        #expect(section.workspaceID == nil)
        #expect(section.workspaceGroup == nil)
        #expect(section.workspaces.isEmpty)
        #expect(section.uncategorizedChats.map(\.id.rawValue) == ["thread-uncategorized"])
        #expect(section.chats(in: .init(rawValue: workspaceURL.standardizedFileURL.path)).isEmpty)
        #expect(section.chat(id: "thread-uncategorized")?.id.rawValue == "thread-uncategorized")
    }

    @Test("workspace fetch pagination is applied after workspace deduplication")
    func workspaceFetchPaginationIsAppliedAfterWorkspaceDeduplication() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstWorkspace = temporaryDirectory()
        let secondWorkspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-first-a", workspace: firstWorkspace, name: "First A"),
                .init(id: "thread-first-b", workspace: firstWorkspace, name: "First B"),
            ],
            nextCursor: "server-next"
        ))
        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-second", workspace: secondWorkspace, name: "Second")
            ]
        ))

        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await results.performFetch()

        #expect(Set(results.items.map(\.url)) == Set([firstWorkspace, secondWorkspace]))
        #expect(results.nextCursor == nil)

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(requests.count == 2)
    }

    @Test("local paged workspace load reconciles stale loaded items")
    func localPagedWorkspaceLoadReconcilesStaleLoadedItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstWorkspace = temporaryDirectory().appendingPathComponent("Alpha", isDirectory: true)
        let secondWorkspace = temporaryDirectory().appendingPathComponent("Beta", isDirectory: true)
        let thirdWorkspace = temporaryDirectory().appendingPathComponent("Zulu", isDirectory: true)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: firstWorkspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: thirdWorkspace, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.name) == ["Alpha"])

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-beta", workspace: secondWorkspace, name: "Beta"),
            .init(id: "thread-zulu", workspace: thirdWorkspace, name: "Zulu"),
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.name) == ["Beta", "Zulu"])
    }

    @Test("workspace regrouping removes it from previous group")
    func workspaceRegroupingRemovesItFromPreviousGroup() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-regroup", workspace: workspaceURL, name: "Regroup")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await results.performFetch()
        let workspace = try #require(results.items.first)
        let previousGroup = try #require(workspace.workspaceGroup)

        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-regroup", workspace: workspaceURL, name: "Regroup")
        ]))
        try await results.performFetch()
        let currentGroup = try #require(workspace.workspaceGroup)

        #expect(currentGroup !== previousGroup)
        #expect(previousGroup.workspaces.contains { $0 === workspace } == false)
        #expect(currentGroup.workspaces.contains { $0 === workspace })
    }

    @Test("group refresh preserves workspace contents when it moves groups")
    func groupRefreshPreservesWorkspaceContentsWhenItMovesGroups() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-regroup", workspace: workspaceURL, name: "Regroup")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups)
        try await results.performFetch()
        let previousGroup = try #require(results.items.first)
        let workspace = try #require(previousGroup.workspaces.first)
        let chat = try #require(workspace.chats.first)

        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-regroup", workspace: workspaceURL, name: "Regroup")
        ]))
        try await context.refresh(previousGroup)

        let currentGroup = try #require(workspace.workspaceGroup)
        #expect(currentGroup !== previousGroup)
        #expect(previousGroup.workspaces.isEmpty)
        #expect(currentGroup.workspaces.contains { $0 === workspace })
        #expect(workspace.chats.first === chat)
        #expect(chat.workspace === workspace)
        #expect(results.items.map(\.id) == [currentGroup.id])
    }

    @Test("group refresh prunes stale chats when a workspace moves groups")
    func groupRefreshPrunesStaleChatsWhenWorkspaceMovesGroups() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale"),
            .init(id: "thread-keep", workspace: workspaceURL, name: "Keep"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups)
        try await results.performFetch()
        let previousGroup = try #require(results.items.first)
        let workspace = try #require(previousGroup.workspaces.first)
        let staleChat = try #require(workspace.chats.first { $0.id.rawValue == "thread-stale" })
        let keepChat = try #require(workspace.chats.first { $0.id.rawValue == "thread-keep" })

        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-keep", workspace: workspaceURL, name: "Keep")
        ]))
        try await context.refresh(previousGroup)

        let currentGroup = try #require(workspace.workspaceGroup)
        #expect(currentGroup !== previousGroup)
        #expect(previousGroup.workspaces.isEmpty)
        #expect(currentGroup.workspaces.contains { $0 === workspace })
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-keep"])
        #expect(keepChat.workspace === workspace)
        #expect(staleChat.workspace == nil)
        #expect(results.items.map(\.id) == [currentGroup.id])
    }

    @Test("paged workspace fetches prune stale workspace chats")
    func pagedWorkspaceFetchesPruneStaleWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("paged workspace revalidation backfills when new parent cannot be inserted")
    func pagedWorkspaceRevalidationBackfillsWhenNewParentCannotBeInserted() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let backfill = try createDirectory("Backfill", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: app, name: "Move"),
            .init(id: "thread-backfill", workspace: backfill, name: "Backfill"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first?.chats.first)
        #expect(results.items.map(\.url) == [app])

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: tools,
            name: "Move"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-backfill", workspace: backfill, name: "Backfill"),
            .init(id: "thread-move", workspace: tools, name: "Move"),
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.map(\.url) == [backfill])
    }

    @Test("paged workspace revalidation refreshes when a new parent precedes visible items")
    func pagedWorkspaceRevalidationRefreshesWhenNewParentPrecedesVisibleItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let incoming = try createDirectory("AIncoming", in: repo)
        let visible = try createDirectory("BVisible", in: repo)
        let moving = try createDirectory("CMove", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-visible", workspace: visible, name: "Visible"),
            .init(id: "thread-move", workspace: moving, name: "Move"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = context.model(for: CodexThreadID(rawValue: "thread-move"))
        #expect(chat.workspace?.url == moving)
        #expect(results.items.map(\.url) == [visible])

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: incoming,
            name: "Move"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: incoming, name: "Move"),
            .init(id: "thread-visible", workspace: visible, name: "Visible"),
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.map(\.url) == [incoming])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("paged group revalidation refreshes when a new parent precedes visible items")
    func pagedGroupRevalidationRefreshesWhenNewParentPrecedesVisibleItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let incomingRepo = try gitRepository(named: "AIncoming")
        let visibleRepo = try gitRepository(named: "BVisible")
        let movingRepo = try gitRepository(named: "CMove")
        let incoming = try createDirectory("App", in: incomingRepo)
        let visible = try createDirectory("App", in: visibleRepo)
        let moving = try createDirectory("App", in: movingRepo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-visible", workspace: visible, name: "Visible"),
            .init(id: "thread-move", workspace: moving, name: "Move"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = context.model(for: CodexThreadID(rawValue: "thread-move"))
        #expect(chat.workspace?.url == moving)
        #expect(results.items.map(\.name) == ["BVisible"])

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: incoming,
            name: "Move"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: incoming, name: "Move"),
            .init(id: "thread-visible", workspace: visible, name: "Visible"),
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.map(\.name) == ["AIncoming"])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("local paged group load reconciles stale loaded items")
    func localPagedGroupLoadReconcilesStaleLoadedItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let alphaRepo = try gitRepository(named: "Alpha")
        let betaRepo = try gitRepository(named: "Beta")
        let zuluRepo = try gitRepository(named: "Zulu")
        let alpha = try createDirectory("App", in: alphaRepo)
        let beta = try createDirectory("App", in: betaRepo)
        let zulu = try createDirectory("App", in: zuluRepo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: alpha, name: "Alpha"),
            .init(id: "thread-zulu", workspace: zulu, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.name) == ["Alpha"])

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-beta", workspace: beta, name: "Beta"),
            .init(id: "thread-zulu", workspace: zulu, name: "Zulu"),
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.name) == ["Beta", "Zulu"])
    }

    @Test("server paginated chat fetches preserve existing workspace relationships")
    func serverPaginatedChatFetchesPreserveExistingWorkspaceRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspace, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let fetchedWorkspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-new", workspace: workspace, name: "New")
            ],
            nextCursor: "server-next"
        ))
        let chatResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await chatResults.performFetch()

        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == ["thread-existing", "thread-new"])
    }

    @Test("server paginated chat appends preserve previously loaded items")
    func serverPaginatedChatAppendsPreservePreviouslyLoadedItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-existing", workspace: workspace, name: "Existing")
            ],
            nextCursor: "server-next"
        ))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-new", workspace: workspace, name: "New")
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.id.rawValue) == ["thread-existing", "thread-new"])
    }

    @Test("fully loaded paginated chat fetches prune stale workspace relationships")
    func fullyLoadedPaginatedChatFetchesPruneStaleWorkspaceRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let fetchedWorkspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-new", workspace: workspace, name: "New")
            ],
            nextCursor: "server-next"
        ))
        let chatResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await chatResults.performFetch()
        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == ["thread-stale", "thread-new"])

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await chatResults.loadNextPage()

        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-new", "thread-remaining"])
    }

    @Test("active sync preserves archived workspace chats")
    func activeSyncPreservesArchivedWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archived", workspace: workspace, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            predicate: .init(archived: true)
        ))
        try await archivedResults.performFetch()
        let fetchedWorkspace = try #require(archivedResults.items.first)
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-archived"])

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-active", workspace: workspace, name: "Active")
        ]))
        let activeResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await activeResults.performFetch()

        #expect(activeResults.items.map(\.id.rawValue) == ["thread-active"])
        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == [
            "thread-archived",
            "thread-active",
        ])
        #expect(archivedResults.items.first?.chats.contains {
            $0.id.rawValue == "thread-archived"
        } == true)
    }

    @Test("paged chat fetches append loaded workspace relationships")
    func pagedChatFetchesAppendLoadedWorkspaceRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-before", workspace: workspace, name: "Before"),
            .init(id: "thread-middle", workspace: workspace, name: "Middle"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await allResults.performFetch()
        let fetchedWorkspace = try #require(allResults.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-middle", workspace: workspace, name: "Middle")
            ],
            nextCursor: "next"
        ))
        let cursorResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await cursorResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-after", workspace: workspace, name: "After")
        ]))
        try await cursorResults.loadNextPage()

        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == [
            "thread-middle",
            "thread-after",
        ])
    }

    @Test("group refresh rebuilds workspaces from fetched result")
    func groupRefreshRebuildsWorkspacesFromFetchedResult() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups)
        try await results.performFetch()
        let group = try #require(results.items.first)
        #expect(Set(group.workspaces.map(\.url)) == Set([app, tools]))

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        try await context.refresh(group)

        #expect(group.workspaces.map(\.url) == [app])
    }

    @Test("group refresh removes stale chats from active fetched results")
    func groupRefreshRemovesStaleChatsFromActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        let chatResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let group = try #require(chatResults.items.first?.workspace?.workspaceGroup)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        try await context.refresh(group)

        #expect(chatResults.items.map(\.id.rawValue) == ["thread-app"])
        #expect(group.workspaces.map(\.url) == [app])
    }

    @Test("group refresh preserves chats that moved to another group")
    func groupRefreshPreservesChatsThatMovedToAnotherGroup() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let appRepo = try gitRepository(named: "AppRepo")
        let toolsRepo = try gitRepository(named: "ToolsRepo")
        let app = try createDirectory("App", in: appRepo)
        let tools = try createDirectory("Tools", in: toolsRepo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: app, name: "Move")
        ]))
        let chatResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let chat = try #require(chatResults.items.first)
        let group = try #require(chat.workspace?.workspaceGroup)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: tools, name: "Move")
        ]))
        try await context.refresh(group)

        #expect(chat.workspace?.url == tools)
        #expect(chatResults.items.first === chat)
        #expect(group.workspaces.isEmpty)
    }

    @Test("group refresh does not prune unrelated groups")
    func groupRefreshDoesNotPruneUnrelatedGroups() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let app = temporaryDirectory()
        let tools = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        let chatResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let appChat = try #require(chatResults.items.first { $0.id.rawValue == "thread-app" })
        let toolsChat = try #require(chatResults.items.first { $0.id.rawValue == "thread-tools" })
        let appGroup = try #require(appChat.workspace?.workspaceGroup)
        let toolsWorkspace = try #require(toolsChat.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        try await context.refresh(appGroup)

        #expect(toolsWorkspace.chats.first === toolsChat)
        #expect(toolsChat.workspace === toolsWorkspace)
        #expect(chatResults.items.contains { $0 === toolsChat })
    }

    @Test("group refresh preserves archived-only workspaces")
    func groupRefreshPreservesArchivedOnlyWorkspaces() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let archived = try createDirectory("Archived", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archived", workspace: archived, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>(
            predicate: .init(archived: true)
        ))
        try await archivedResults.performFetch()
        let group = try #require(archivedResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-active", workspace: app, name: "Active")
        ]))
        try await context.refresh(group)

        #expect(Set(group.workspaces.map(\.url)) == Set([app, archived]))
    }

    @Test("active group fetch preserves archived-only workspaces")
    func activeGroupFetchPreservesArchivedOnlyWorkspaces() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let archived = try createDirectory("Archived", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archived", workspace: archived, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>(
            predicate: .init(archived: true)
        ))
        try await archivedResults.performFetch()
        let group = try #require(archivedResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-active", workspace: app, name: "Active")
        ]))
        let activeResults = context.fetchedResults(
            for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups)
        try await activeResults.performFetch()

        #expect(activeResults.items.first === group)
        #expect(Set(group.workspaces.map(\.url)) == Set([app, archived]))
    }

    @Test("workspace-scoped group fetches preserve sibling workspaces")
    func workspaceScopedGroupFetchesPreserveSiblingWorkspaces() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        let allGroups = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups)
        try await allGroups.performFetch()
        let group = try #require(allGroups.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        let scopedGroups = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>(
            predicate: .init(workspace: app)
        ))
        try await scopedGroups.performFetch()

        #expect(scopedGroups.items.first === group)
        #expect(Set(group.workspaces.map(\.url)) == Set([app, tools]))
    }

    @Test("workspace refresh revalidates scoped fetched results")
    func workspaceRefreshRevalidatesScopedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let scopedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.chats(
            in: workspace
        ))
        try await scopedResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining")
        ]))
        try await context.refresh(workspace)

        #expect(scopedResults.items.map(\.id.rawValue) == ["thread-remaining"])
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("workspace refresh inserts newly loaded scoped fetched results")
    func workspaceRefreshInsertsNewlyLoadedScopedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let scopedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.chats(
            in: workspace
        ))
        try await scopedResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing"),
            .init(id: "thread-new", workspace: workspaceURL, name: "New"),
        ]))
        try await context.refresh(workspace)

        #expect(Set(scopedResults.items.map(\.id.rawValue)) == ["thread-existing", "thread-new"])
        #expect(Set(workspace.chats.map(\.id.rawValue)) == ["thread-existing", "thread-new"])
    }

    @Test("workspace refresh applies scoped workspace when snapshots omit cwd")
    func workspaceRefreshAppliesScopedWorkspaceWhenSnapshotsOmitCWD() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueJSON(
            """
            {
              "data": [
                {
                  "id": "thread-new",
                  "name": "New"
                }
              ]
            }
            """,
            for: "thread/list"
        )
        try await context.refresh(workspace)

        let chat = try #require(workspace.chats.first)
        #expect(chat.workspace === workspace)
        #expect(chat.id.rawValue == "thread-new")
        #expect(chat.title == "New")
    }

    @Test("workspace refresh revalidates unscoped fetched results")
    func workspaceRefreshRevalidatesUnscopedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining")
        ]))
        try await context.refresh(workspace)

        #expect(results.items.map(\.id.rawValue) == ["thread-remaining"])
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("group refresh inserts newly loaded workspace fetched results")
    func groupRefreshInsertsNewlyLoadedWorkspaceFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let group = try #require(workspaceResults.items.first?.workspaceGroup)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        try await context.refresh(group)

        #expect(Set(workspaceResults.items.map(\.url)) == Set([app, tools]))
        #expect(Set(group.workspaces.map(\.url)) == Set([app, tools]))
    }

    @Test("workspace refresh preserves archived chats")
    func workspaceRefreshPreservesArchivedChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archived", workspace: workspaceURL, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            predicate: .init(archived: true)
        ))
        try await archivedResults.performFetch()
        let workspace = try #require(archivedResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-active", workspace: workspaceURL, name: "Active")
        ]))
        try await context.refresh(workspace)

        #expect(Set(workspace.chats.map(\.id.rawValue)) == [
            "thread-archived",
            "thread-active",
        ])
    }

    @Test("workspace refresh revalidates unscoped filtered chat results")
    func workspaceRefreshRevalidatesUnscopedFilteredChatResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-match", workspace: workspaceURL, name: "Match")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(searchTerm: "Match")
        ))
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-match", workspace: workspaceURL, name: "Renamed")
        ]))
        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await context.refresh(workspace)

        #expect(results.items.isEmpty)
        #expect(workspace.chats.map(\.title) == ["Renamed"])
    }

    @Test("workspace refresh reloads search-filtered results from server")
    func workspaceRefreshReloadsSearchFilteredResultsFromServer() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-search", workspace: workspaceURL, name: "Untitled")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(searchTerm: "needle")
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let workspace = try #require(chat.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-search", workspace: workspaceURL, name: "Untitled")
        ]))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-search", workspace: workspaceURL, name: "Untitled")
        ]))
        try await context.refresh(workspace)

        #expect(results.items.first === chat)
        #expect(workspace.chats.first === chat)
    }

    @Test("workspace refresh removes known server-filtered chats when refresh fails")
    func workspaceRefreshRemovesKnownServerFilteredChatsWhenRefreshFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remove", workspace: workspaceURL, name: "Remove")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let workspace = try #require(chat.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        await runtime.transport.enqueueFailure(code: -32000, message: "offline", for: "thread/list")
        try await context.refresh(workspace)

        #expect(results.items.isEmpty)
        #expect(workspace.chats.isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 3)
    }

    @Test("workspace refresh prunes empty workspace from group")
    func workspaceRefreshPrunesEmptyWorkspaceFromGroup() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale")
        ]))
        let groupResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups)
        try await groupResults.performFetch()
        let group = try #require(groupResults.items.first)
        let workspace = try #require(group.workspaces.first)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await context.refresh(workspace)

        #expect(workspace.chats.isEmpty)
        #expect(group.workspaces.isEmpty)
    }

    @Test("workspace refresh backfills paged chat results after removals")
    func workspaceRefreshBackfillsPagedChatResultsAfterRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let backfillURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
            ],
            nextCursor: "next"
        ))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-backfill", workspace: backfillURL, name: "Backfill")
        ]))
        try await context.refresh(workspace)

        #expect(results.items.map(\.id.rawValue) == ["thread-backfill"])
    }

    @Test("group refresh backfills paged chat results after removals")
    func groupRefreshBackfillsPagedChatResultsAfterRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let backfillURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
            ],
            nextCursor: "next"
        ))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let group = try #require(results.items.first?.workspace?.workspaceGroup)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-backfill", workspace: backfillURL, name: "Backfill")
        ]))
        try await context.refresh(group)

        #expect(results.items.map(\.id.rawValue) == ["thread-backfill"])
    }

    @Test("filtered workspace results drop parents with no matching chats")
    func filteredWorkspaceResultsDropParentsWithNoMatchingChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-keep", workspace: workspaceURL, name: "Keep"),
            .init(id: "thread-match", workspace: workspaceURL, name: "Match"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await allResults.performFetch()
        let chat = try #require(allResults.items.first { $0.id.rawValue == "thread-match" })

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-match", workspace: workspaceURL, name: "Match")
        ]))
        let filteredResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            predicate: .init(searchTerm: "Match")
        ))
        try await filteredResults.performFetch()
        #expect(filteredResults.items.isEmpty == false)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-match"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-match",
            workspace: workspaceURL,
            name: "Renamed"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await context.refresh(chat, includeTurns: false)

        #expect(filteredResults.items.isEmpty)
    }

    @Test("removing the last chat removes the workspace from its group")
    func removingLastChatRemovesWorkspaceFromGroup() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
        ]))

        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let workspace = try #require(chat.workspace)
        let group = try #require(workspace.workspaceGroup)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await chat.delete()

        #expect(workspace.chats.isEmpty)
        #expect(group.workspaces.isEmpty)
    }

    @Test("deleting a chat removes it from active fetched results")
    func deletingChatRemovesItFromActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)
        let page = CodexThreadPage(threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
        ])

        try await runtime.transport.enqueueThreadList(page)
        let chatResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let chat = try #require(chatResults.items.first)

        try await runtime.transport.enqueueThreadList(page)
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueThreadList(page)
        let groupResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>.workspaceGroups)
        try await groupResults.performFetch()

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await chat.delete()

        #expect(chatResults.items.isEmpty)
        #expect(chatResults.sections.isEmpty)
        #expect(workspaceResults.items.isEmpty)
        #expect(groupResults.items.isEmpty)
        #expect(chat.modelContext == nil)
    }

    @Test("server-filtered delete removes known chat when refresh fails")
    func serverFilteredDeleteRemovesKnownChatWhenRefreshFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-delete", name: "Delete")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.enqueueFailure(code: -32000, message: "offline", for: "thread/list")
        try await chat.delete()

        #expect(results.items.isEmpty)
        #expect(chat.modelContext == nil)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("server-only parent results keep parents after local child removal")
    func serverOnlyParentResultsKeepParentsAfterLocalChildRemoval() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let chatResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let chat = try #require(chatResults.items.first { $0.id.rawValue == "thread-delete" })

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            predicate: .init(sourceKinds: [.appServer])
        ))
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let groupResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>(
            predicate: .init(sourceKinds: [.appServer])
        ))
        try await groupResults.performFetch()

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining")
        ]))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining")
        ]))
        try await chat.delete()

        #expect(workspaceResults.items.first?.url == workspaceURL)
        #expect(groupResults.items.first?.workspaces.first?.url == workspaceURL)
    }

    @Test("paged fetched results backfill after local removals")
    func pagedFetchedResultsBackfillAfterLocalRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
            ],
            nextCursor: "next"
        ))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-backfill", workspace: workspaceURL, name: "Backfill")
        ]))
        try await chat.delete()

        #expect(results.items.map(\.id.rawValue) == ["thread-backfill"])
    }

    @Test("server-paginated fetched results backfill without explicit limits")
    func serverPaginatedFetchedResultsBackfillWithoutExplicitLimits() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
            ],
            nextCursor: "next"
        ))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-backfill", workspace: workspaceURL, name: "Backfill")
        ]))
        try await chat.delete()

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let backfillParams = try #require(requests.last).decodeParams(ThreadListParams.self)
        #expect(backfillParams.cursor == "next")
        #expect(backfillParams.limit == 1)
        #expect(results.items.map(\.id.rawValue) == ["thread-backfill"])
    }

    @Test("paged fetched results preserve loaded pages while backfilling")
    func pagedFetchedResultsPreserveLoadedPagesWhileBackfilling() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
            ],
            nextCursor: "page-2"
        ))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-keep", workspace: workspaceURL, name: "Keep")
            ],
            nextCursor: "page-3"
        ))
        try await results.loadNextPage()

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-backfill", workspace: workspaceURL, name: "Backfill")
        ]))
        try await chat.delete()

        #expect(results.items.map(\.id.rawValue) == ["thread-keep", "thread-backfill"])
    }

    @Test("local paged fetched results recompute backfill cursors after removals")
    func localPagedFetchedResultsRecomputeBackfillCursorsAfterRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-a", workspace: workspaceURL, name: "A"),
            .init(id: "thread-b", workspace: workspaceURL, name: "B"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-b", workspace: workspaceURL, name: "B"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]))
        try await chat.delete()

        #expect(results.items.map(\.id.rawValue) == ["thread-b", "thread-c"])
    }

    @Test("local paged fetched results preserve starting cursor when loading next page")
    func localPagedFetchedResultsPreserveStartingCursorWhenLoadingNextPage() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let threads = [
            CodexThreadSnapshot(id: "thread-a", workspace: workspaceURL, name: "A"),
            CodexThreadSnapshot(id: "thread-b", workspace: workspaceURL, name: "B"),
            CodexThreadSnapshot(id: "thread-c", workspace: workspaceURL, name: "C"),
            CodexThreadSnapshot(id: "thread-d", workspace: workspaceURL, name: "D"),
        ]

        try await runtime.transport.enqueueThreadList(.init(threads: threads))
        let firstPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await firstPage.performFetch()
        _ = try #require(firstPage.nextCursor)

        try await runtime.transport.enqueueThreadList(.init(threads: threads))
        let offsetPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1,
            fetchOffset: 2
        ))
        try await offsetPage.performFetch()
        #expect(offsetPage.items.map(\.title) == ["C"])

        try await runtime.transport.enqueueThreadList(.init(threads: threads))
        try await offsetPage.loadNextPage()

        #expect(offsetPage.items.map(\.title) == ["C", "D"])
        #expect(offsetPage.nextCursor == nil)
    }

    @Test("local paged fetched results backfill from starting cursor offset after removals")
    func localPagedFetchedResultsBackfillFromStartingCursorOffsetAfterRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialThreads = [
            CodexThreadSnapshot(id: "thread-a", workspace: workspaceURL, name: "A"),
            CodexThreadSnapshot(id: "thread-b", workspace: workspaceURL, name: "B"),
            CodexThreadSnapshot(id: "thread-c", workspace: workspaceURL, name: "C"),
            CodexThreadSnapshot(id: "thread-d", workspace: workspaceURL, name: "D"),
            CodexThreadSnapshot(id: "thread-e", workspace: workspaceURL, name: "E"),
        ]

        try await runtime.transport.enqueueThreadList(.init(threads: initialThreads))
        let firstPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await firstPage.performFetch()
        _ = try #require(firstPage.nextCursor)

        try await runtime.transport.enqueueThreadList(.init(threads: initialThreads))
        let offsetPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 2,
            fetchOffset: 2
        ))
        try await offsetPage.performFetch()
        let deletedChat = try #require(offsetPage.items.first)
        #expect(offsetPage.items.map(\.title) == ["C", "D"])

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-a", workspace: workspaceURL, name: "A"),
            .init(id: "thread-b", workspace: workspaceURL, name: "B"),
            .init(id: "thread-d", workspace: workspaceURL, name: "D"),
            .init(id: "thread-e", workspace: workspaceURL, name: "E"),
        ]))
        try await deletedChat.delete()

        #expect(offsetPage.items.map(\.title) == ["D", "E"])
        #expect(offsetPage.nextCursor == nil)
    }

    @Test("cursor-started local pages refetch when earlier chats are removed")
    func cursorStartedLocalPagesRefetchWhenEarlierChatsAreRemoved() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialThreads = [
            CodexThreadSnapshot(id: "thread-a", workspace: workspaceURL, name: "A"),
            CodexThreadSnapshot(id: "thread-b", workspace: workspaceURL, name: "B"),
            CodexThreadSnapshot(id: "thread-c", workspace: workspaceURL, name: "C"),
            CodexThreadSnapshot(id: "thread-d", workspace: workspaceURL, name: "D"),
            CodexThreadSnapshot(id: "thread-e", workspace: workspaceURL, name: "E"),
        ]

        try await runtime.transport.enqueueThreadList(.init(threads: initialThreads))
        var firstPage: CodexFetchedResults<CodexChat>? = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await firstPage?.performFetch()
        _ = try #require(firstPage?.nextCursor)
        let deletedChat = context.model(for: CodexThreadID(rawValue: "thread-a"))
        firstPage = nil

        try await runtime.transport.enqueueThreadList(.init(threads: initialThreads))
        let offsetPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 2,
            fetchOffset: 2
        ))
        try await offsetPage.performFetch()
        #expect(offsetPage.items.map(\.title) == ["C", "D"])

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-b", workspace: workspaceURL, name: "B"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
            .init(id: "thread-d", workspace: workspaceURL, name: "D"),
            .init(id: "thread-e", workspace: workspaceURL, name: "E"),
        ]))
        try await deletedChat.delete()

        #expect(offsetPage.items.map(\.title) == ["D", "E"])
    }

    @Test("cursor-started local pages refetch when visible chats move before the cursor")
    func cursorStartedLocalPagesRefetchWhenVisibleChatsMoveBeforeCursor() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialThreads = [
            CodexThreadSnapshot(id: "thread-a", workspace: workspaceURL, name: "A"),
            CodexThreadSnapshot(id: "thread-b", workspace: workspaceURL, name: "B"),
            CodexThreadSnapshot(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]

        try await runtime.transport.enqueueThreadList(.init(threads: initialThreads))
        let firstPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await firstPage.performFetch()
        _ = try #require(firstPage.nextCursor)

        try await runtime.transport.enqueueThreadList(.init(threads: initialThreads))
        let offsetPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 2,
            fetchOffset: 1
        ))
        try await offsetPage.performFetch()
        let movingChat = try #require(offsetPage.items.first)
        #expect(offsetPage.items.map(\.title) == ["B", "C"])
        #expect(offsetPage.nextCursor == nil)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-b"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-b",
            workspace: workspaceURL,
            name: "0"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-b", workspace: workspaceURL, name: "0"),
            .init(id: "thread-a", workspace: workspaceURL, name: "A"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-b", workspace: workspaceURL, name: "0"),
            .init(id: "thread-a", workspace: workspaceURL, name: "A"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]))
        try await context.refresh(movingChat, includeTurns: false)

        #expect(offsetPage.items.map(\.title) == ["A", "C"])
        #expect(offsetPage.nextCursor == nil)
    }

    @Test("starting a chat inserts it into active fetched results")
    func startingChatInsertsItIntoActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-existing",
                workspace: workspaceURL,
                name: "Existing",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        let chat = try await workspace.startChat()

        #expect(results.items.first === chat)
        #expect(results.sections.first?.items.first === chat)
    }

    @Test("starting a chat preserves requested provider for filtered results")
    func startingChatPreservesRequestedProviderForFilteredResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let providerResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(modelProviders: ["openai"])
        ))
        try await providerResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-new",
                workspace: workspaceURL,
                name: "New",
                modelProvider: "openai"
            )
        ]))
        let chat = try await workspace.startChat(.init(
            options: .init(modelProvider: "openai")
        ))

        #expect(chat.modelProvider == "openai")
        #expect(providerResults.items.first === chat)
    }

    @Test("starting a chat refreshes provider-filtered results when provider is unknown")
    func startingChatRefreshesProviderFilteredResultsWhenProviderIsUnknown() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let providerResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(modelProviders: ["openai"])
        ))
        try await providerResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-new",
                workspace: workspaceURL,
                name: "New",
                modelProvider: "openai"
            )
        ]))
        let chat = try await workspace.startChat()

        #expect(chat.modelProvider == "openai")
        #expect(providerResults.items.first === chat)
    }

    @Test("starting a chat refreshes server-filtered fetched results")
    func startingChatRefreshesServerFilteredFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let serverResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(sourceKinds: [.appServer])
        ))
        try await serverResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-new", workspace: workspaceURL, name: "New")
        ]))
        let chat = try await workspace.startChat()

        #expect(serverResults.items.first === chat)
    }

    @Test("empty provider filters revalidate as all providers")
    func emptyProviderFiltersRevalidateAsAllProviders() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-any-provider", name: "Before")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(modelProviders: [])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-any-provider"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-any-provider",
            name: "After"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-any-provider", name: "After")
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.first === chat)
        #expect(chat.title == "After")
    }

    @Test("starting a chat updates limited fetched results without overfilling")
    func startingChatUpdatesLimitedFetchedResultsWithoutOverfilling() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let pagedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await pagedResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        _ = try await workspace.startChat()

        #expect(pagedResults.items.count == 1)
        #expect(pagedResults.items.first?.id.rawValue == "thread-new")
        #expect(pagedResults.nextCursor != nil)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-new", workspace: workspaceURL, name: "New", updatedAt: Date()),
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing"),
        ]))
        try await pagedResults.loadNextPage()

        #expect(pagedResults.items.map(\.id.rawValue) == ["thread-new", "thread-existing"])
        #expect(pagedResults.nextCursor == nil)
        let listRequests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(listRequests.count == 3)
        let nextPageParams = try #require(listRequests.last).decodeParams(ThreadListParams.self)
        #expect(nextPageParams.cursor == nil)
    }

    @Test("starting a chat inserts into underfilled limited fetched results")
    func startingChatInsertsIntoUnderfilledLimitedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let limitedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 2
        ))
        try await limitedResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        _ = try await workspace.startChat()

        #expect(limitedResults.items.map(\.id.rawValue) == ["thread-new", "thread-existing"])
    }

    @Test("starting a chat refreshes incomplete paged fetched results")
    func startingChatRefreshesIncompletePagedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
            ],
            nextCursor: "next"
        ))
        let pagedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await pagedResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-new", workspace: workspaceURL, name: "New")
            ],
            nextCursor: "next"
        ))
        _ = try await workspace.startChat()

        #expect(pagedResults.items.map(\.id.rawValue) == ["thread-new"])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 3)
    }

    @Test("loaded limited pages stay loaded after local revalidation")
    func loadedLimitedPagesStayLoadedAfterLocalRevalidation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspaceURL, name: "Beta"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspaceURL, name: "Beta"),
        ]))
        try await results.loadNextPage()
        let beta = try #require(results.items.last)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-beta"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-beta",
            workspace: workspaceURL,
            name: "Gamma"
        ))
        try await context.refresh(beta, includeTurns: false)

        #expect(results.items.map(\.title) == ["Alpha", "Gamma"])
    }

    @Test("starting a chat extends fully loaded paged results")
    func startingChatExtendsFullyLoadedPagedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-newer", workspace: workspaceURL, name: "Newer", updatedAt: newer)
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-newer", workspace: workspaceURL, name: "Newer", updatedAt: newer)
            ],
            nextCursor: "page-2"
        ))
        let pagedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await pagedResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(id: "thread-older", workspace: workspaceURL, name: "Older", updatedAt: older)
            ],
            backwardsCursor: "page-1"
        ))
        try await pagedResults.loadNextPage()
        let listRequestCount = await runtime.transport.recordedRequests(method: "thread/list").count

        try await runtime.transport.enqueueThreadStart(threadID: "thread-started")
        _ = try await workspace.startChat()

        #expect(pagedResults.items.map(\.id.rawValue) == [
            "thread-started",
            "thread-newer",
            "thread-older",
        ])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == listRequestCount)
    }

    @Test("archiving a chat moves it between active fetched results")
    func archivingChatMovesItBetweenActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(archived: true),
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let unarchivedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await unarchivedResults.performFetch()
        let chat = try #require(unarchivedResults.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await chat.archive()

        #expect(unarchivedResults.items.isEmpty)
        #expect(archivedResults.items.first === chat)
    }

    @Test("server-filtered archive removes active chat when refresh fails")
    func serverFilteredArchiveRemovesActiveChatWhenRefreshFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        await runtime.transport.enqueueFailure(code: -32000, message: "offline", for: "thread/list")
        try await chat.archive()

        #expect(results.items.isEmpty)
        #expect(chat.isArchived)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("unarchiving a chat moves it between active fetched results")
    func unarchivingChatMovesItBetweenActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-unarchive", workspace: workspaceURL, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(archived: true),
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let chat = try #require(archivedResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let unarchivedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await unarchivedResults.performFetch()

        try await runtime.transport.enqueueThreadUnarchive(.init(
            id: "thread-unarchive",
            workspace: workspaceURL,
            name: "Restored"
        ))
        try await chat.unarchive()

        #expect(chat.isArchived == false)
        #expect(chat.title == "Restored")
        #expect(archivedResults.items.isEmpty)
        #expect(unarchivedResults.items.first === chat)
        #expect(chat.workspace?.chats.first === chat)
    }

    @Test("server-filtered unarchive removes archived chat when refresh fails")
    func serverFilteredUnarchiveRemovesArchivedChatWhenRefreshFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-unarchive", workspace: workspaceURL, name: "Archived")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(archived: true, sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadUnarchive(.init(
            id: "thread-unarchive",
            workspace: workspaceURL,
            name: "Restored"
        ))
        await runtime.transport.enqueueFailure(code: -32000, message: "offline", for: "thread/list")
        try await chat.unarchive()

        #expect(results.items.isEmpty)
        #expect(chat.isArchived == false)
        #expect(chat.title == "Restored")
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("archiving a chat inserts parents into archived fetched results")
    func archivingChatInsertsParentsIntoArchivedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let archivedWorkspaceResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>(
            predicate: .init(archived: true)
        ))
        try await archivedWorkspaceResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let archivedGroupResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>(
            predicate: .init(archived: true)
        ))
        try await archivedGroupResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let unarchivedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await unarchivedResults.performFetch()
        let chat = try #require(unarchivedResults.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await chat.archive()

        #expect(archivedWorkspaceResults.items.first?.url == workspaceURL)
        #expect(archivedWorkspaceResults.items.first?.chats.first === chat)
        #expect(archivedGroupResults.items.first?.workspaces.first?.url == workspaceURL)
        #expect(archivedGroupResults.items.first?.workspaces.first?.chats.first === chat)
    }

    @Test("archived refresh prunes removed archived relationships")
    func archivedRefreshPrunesRemovedArchivedRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archived", workspace: workspaceURL, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(archived: true),
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let chat = try #require(archivedResults.items.first)
        let workspace = try #require(chat.workspace)
        let group = try #require(workspace.workspaceGroup)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await archivedResults.performFetch()

        #expect(archivedResults.items.isEmpty)
        #expect(workspace.chats.isEmpty)
        #expect(group.workspaces.contains { $0 === workspace } == false)
    }

    @Test("archiving a chat refreshes server-filtered archived results")
    func archivingChatRefreshesServerFilteredArchivedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let archivedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(archived: true, sourceKinds: [.appServer])
        ))
        try await archivedResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let activeResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await activeResults.performFetch()
        let chat = try #require(activeResults.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        try await chat.archive()

        #expect(activeResults.items.isEmpty)
        #expect(archivedResults.items.first === chat)
    }

    @Test("metadata-only chat refresh preserves existing turn objects")
    func metadataOnlyRefreshPreservesTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let updatedAt = Date(timeIntervalSince1970: 1_000)

        try await runtime.transport.enqueueThreadList(
            .init(threads: [
                .init(
                    id: "thread-refresh",
                    workspace: workspaceURL,
                    name: "Before",
                    modelProvider: "openai",
                    updatedAt: updatedAt,
                    turns: [.init(id: "turn-refresh", status: .running)]
                )
            ]))

        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let turn = try #require(chat.turns.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh"))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: "thread-refresh",
                name: "After",
                turns: []
            ))

        try await context.refresh(chat, includeTurns: false)

        #expect(chat.title == "After")
        #expect(chat.workspace?.url == workspaceURL)
        #expect(chat.modelProvider == "openai")
        #expect(chat.updatedAt == updatedAt)
        #expect(chat.turns.first === turn)
        #expect(turn.status == CodexTurnStatus.running)

        let request = try #require(
            await runtime.transport.recordedRequests(method: "thread/read").first)
        let params = try request.decodeParams(ThreadReadParams.self)
        #expect(params.threadID == "thread-refresh")
        #expect(params.includeTurns == false)
    }

    @Test("metadata-only chat refresh derives phase from fresh thread status")
    func metadataOnlyRefreshDerivesPhaseFromFreshThreadStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-metadata-phase"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-metadata-phase",
            status: .active(activeFlags: []),
            turns: [.init(id: "turn-stale", status: .running)]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-metadata-phase"))
        try await context.refresh(chat)
        #expect(chat.phase == .loading)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-metadata-phase"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-metadata-phase",
            status: .idle
        ))

        try await context.refresh(chat, includeTurns: false)

        #expect(chat.turn(id: "turn-stale")?.status == .completed)
        #expect(chat.phase == .loaded)
        #expect(chat.status == .idle)
    }

    @Test("turn snapshots without fresh thread status preserve app-server thread status")
    func turnSnapshotsWithoutFreshThreadStatusPreserveAppServerThreadStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-stale-status"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-stale-status",
            status: .idle
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-stale-status"))
        try await context.refresh(chat, includeTurns: false)
        #expect(chat.status == .idle)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-stale-status"))
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-running-after-idle",
                status: .running,
                items: [
                    .init(
                        id: "command-running-after-idle",
                        kind: .commandExecution,
                        content: .command(.init(
                            command: "/bin/zsh -lc",
                            status: .running,
                            startedAt: Date(timeIntervalSince1970: 4_000)
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-stale-status"))

        try await context.refresh(chat)

        let turn = try #require(chat.turn(id: "turn-running-after-idle"))
        let commandItem = try #require(chat.items.first { $0.itemID == "command-running-after-idle" })
        guard case .command(let command) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(turn.status == .running)
        #expect(command.status == .running)
        #expect(command.completedAt == nil)
        #expect(chat.status == .idle)
        #expect(chat.phase == .loading)
    }

    @Test("fresh idle thread status wins over stale running turn snapshots")
    func freshIdleThreadStatusWinsOverStaleRunningTurnSnapshots() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-idle-with-running-turn"))
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-stale-running",
                status: .running,
                items: [
                    .init(
                        id: "command-stale-running",
                        kind: .commandExecution,
                        content: .command(.init(
                            command: "/bin/zsh -lc",
                            status: .running,
                            startedAt: Date(timeIntervalSince1970: 4_500)
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-idle-with-running-turn",
            status: .idle
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-idle-with-running-turn"))
        try await context.refresh(chat)

        #expect(chat.status == .idle)
        #expect(chat.phase == .loaded)
        #expect(chat.turn(id: "turn-stale-running")?.status == .completed)
    }

    @Test("server-only chat refresh re-sorts current results")
    func serverOnlyChatRefreshResortsCurrentResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-beta", name: "Beta"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(sourceKinds: [.appServer]),
            sortDescriptors: [CodexSortDescriptor(\.name)]
        ))
        try await results.performFetch()
        let beta = try #require(results.items.first { $0.id.rawValue == "thread-beta" })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-beta"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-beta", name: "Aardvark"))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-beta", name: "Aardvark"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))
        try await context.refresh(beta, includeTurns: false)

        #expect(results.items.map(\.title) == ["Aardvark", "Alpha"])
    }

    @Test("server-only chat refresh applies local workspace filters")
    func serverOnlyChatRefreshAppliesLocalWorkspaceFilters() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: app, name: "Move")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(workspace: app, sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: tools,
            name: "Move"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.isEmpty)
    }

    @Test("search-filtered chat refresh reloads server membership")
    func searchFilteredChatRefreshReloadsServerMembership() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-search", name: "Untitled")
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(searchTerm: "needle")
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-search"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-search", name: "Untitled"))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-search", name: "Untitled")
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.first === chat)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("thread list fetch coalesces server-filtered revalidations")
    func threadListFetchCoalescesServerFilteredRevalidations() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-first", name: "First"),
            .init(id: "thread-second", name: "Second"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await allResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-first", name: "First"),
            .init(id: "thread-second", name: "Second"),
        ]))
        let searchResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            predicate: .init(searchTerm: "needle")
        ))
        try await searchResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-first", name: "First renamed"),
            .init(id: "thread-second", name: "Second renamed"),
        ]))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-first", name: "First renamed"),
            .init(id: "thread-second", name: "Second renamed"),
        ]))
        try await allResults.performFetch()

        #expect(searchResults.items.map(\.title) == ["First renamed", "Second renamed"])
        let recordedRequests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(recordedRequests.count == 4)
        let refreshParams = try #require(recordedRequests.last).decodeParams(ThreadListParams.self)
        #expect(refreshParams.searchTerm == "needle")
    }

    @Test("paged chat refresh reloads incomplete results after sort key changes")
    func pagedChatRefreshReloadsIncompleteResultsAfterSortKeyChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let alpha = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-alpha", name: "Zulu"))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", name: "Zulu"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        try await context.refresh(alpha, includeTurns: false)

        #expect(results.items.map(\.id.rawValue) == ["thread-beta"])
    }

    @Test("thread list empty turn arrays preserve cached turns and items")
    func threadListEmptyTurnArraysPreserveCachedTurnsAndItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-clear",
                name: "Before",
                turns: [
                    .init(
                        id: "turn-clear",
                        status: .completed,
                        items: [
                            .init(
                                id: "message-clear",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-clear",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Done"
                                ))
                            ),
                        ]
                    )
                ]
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(chat.turns.isEmpty == false)
        #expect(chat.items.isEmpty == false)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-clear", name: "After", turns: [])
        ]))
        try await results.refresh()

        #expect(chat.title == "After")
        #expect(chat.turns.isEmpty == false)
        #expect(chat.items.isEmpty == false)
    }

    @Test("thread list summary turns preserve cached transcript items")
    func threadListSummaryTurnsPreserveCachedTranscriptItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-summary",
                name: "Before",
                turns: [
                    .init(
                        id: "turn-summary",
                        status: .running,
                        items: [
                            .init(
                                id: "message-summary",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-summary",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Done"
                                ))
                            ),
                        ]
                    ),
                    .init(
                        id: "turn-omitted",
                        status: .running
                    )
                ]
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let turn = try #require(chat.turns.first)
        let item = try #require(chat.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-summary",
                name: "After",
                turns: [
                    .init(
                        id: "turn-summary",
                        status: .completed,
                        itemsLoadState: .summary,
                        items: [
                            .init(
                                id: "message-summary",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-summary",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Summary placeholder"
                                ))
                            ),
                        ]
                    )
                ]
            )
        ]))
        try await results.refresh()

        #expect(chat.title == "After")
        #expect(chat.turns.first === turn)
        #expect(turn.status == CodexTurnStatus.completed)
        #expect(chat.turns.contains { $0.id == "turn-omitted" })
        #expect(chat.items.first === item)
        #expect(item.text == "Done")
        #expect(chat.transcript.finalAnswer == "Done")
    }

    @Test("explicit empty read turn lists clear cached turns and items")
    func explicitEmptyReadTurnListsClearCachedTurnsAndItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-clear",
                name: "Before",
                turns: [
                    .init(
                        id: "turn-clear",
                        status: .completed,
                        items: [
                            .init(
                                id: "message-clear",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-clear",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Done"
                                ))
                            ),
                        ]
                    )
                ]
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(chat.turns.isEmpty == false)
        #expect(chat.items.isEmpty == false)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-clear"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-clear",
            name: "After",
            turns: []
        ))
        try await context.refresh(chat)

        #expect(chat.turns.isEmpty)
        #expect(chat.items.isEmpty)
    }

    @Test("included reads without turns clear cached turns and items")
    func includedReadsWithoutTurnsClearCachedTurnsAndItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-omitted-read",
                name: "Before",
                turns: [
                    .init(
                        id: "turn-omitted-read",
                        status: .completed,
                        items: [
                            .init(
                                id: "message-omitted-read",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-omitted-read",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Done"
                                ))
                            ),
                        ]
                    )
                ]
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(chat.turns.isEmpty == false)
        #expect(chat.items.isEmpty == false)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-omitted-read"))
        try await runtime.transport.enqueueJSON(
            """
            {
              "thread": {
                "id": "thread-omitted-read",
                "name": "After"
              }
            }
            """,
            for: "thread/read"
        )
        try await context.refresh(chat)

        #expect(chat.title == "After")
        #expect(chat.turns.isEmpty)
        #expect(chat.items.isEmpty)
    }

    @Test("chat refresh populates transcript items from turn history")
    func chatRefreshPopulatesTranscriptItemsFromTurnHistory() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-history"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-history",
            turns: [
                .init(
                    id: "turn-history",
                    status: .completed,
                    items: [
                        .init(
                            id: "message-history",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-history",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Done"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-history"))
        try await context.refresh(chat)

        let item = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(item.itemID == "message-history")
        #expect(item.turnID == "turn-history")
        #expect(item.text == "Done")
        #expect(chat.transcript.finalAnswer == "Done")
    }

    @Test("chat refresh loads full turn items through thread turns list")
    func chatRefreshLoadsFullTurnItemsThroughThreadTurnsList() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-turns-list"))
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-live",
                status: .running,
                items: [
                    .init(
                        id: "message-live",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-live",
                            role: .assistant,
                            text: "Active turn snapshot"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-turns-list",
            name: "Turns list"
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-turns-list"))
        try await context.refresh(chat)

        #expect(chat.title == "Turns list")
        #expect(chat.items.map(\.text) == ["Active turn snapshot"])
        #expect(await runtime.transport.recordedRequests(method: "thread/turns/list").count == 1)
        let readRequest = try #require(await runtime.transport.recordedRequests(method: "thread/read").first)
        let readParams = try readRequest.decodeParams(ThreadReadParams.self)
        #expect(readParams.includeTurns == false)
    }

    @Test("chat refresh follows all turn-list pages before applying authoritative turns")
    func chatRefreshFollowsAllTurnListPagesBeforeApplyingAuthoritativeTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-turns-pages"))
        try await runtime.transport.enqueueThreadTurns(.init(
            turns: [
                .init(
                    id: "turn-page-1",
                    status: .completed,
                    items: [
                        .init(
                            id: "message-page-1",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-page-1",
                                role: .assistant,
                                text: "First page"
                            ))
                        ),
                    ]
                ),
            ],
            nextCursor: "page-2"
        ))
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-page-2",
                status: .completed,
                items: [
                    .init(
                        id: "message-page-2",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-page-2",
                            role: .assistant,
                            text: "Second page"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-turns-pages",
            name: "Turns pages"
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-turns-pages"))
        try await context.refresh(chat)

        #expect(chat.items.map(\.text) == ["First page", "Second page"])
        #expect(chat.turns.map(\.id.rawValue) == ["turn-page-1", "turn-page-2"])
        let requests = await runtime.transport.recordedRequests(method: "thread/turns/list")
        #expect(requests.count == 2)
        let firstParams = try #require(requests.first).decodeParams(ThreadTurnsListParams.self)
        let secondParams = try #require(requests.dropFirst().first).decodeParams(ThreadTurnsListParams.self)
        #expect(firstParams.cursor == nil)
        #expect(secondParams.cursor == "page-2")
    }

    @Test("chat turn helpers scope items and preserve identity")
    func chatTurnHelpersScopeItemsAndPreserveIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-snapshot"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-snapshot",
            turns: [
                .init(
                    id: "turn-alpha",
                    status: .completed,
                    items: [
                        .init(
                            id: "message-alpha-user",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "message-alpha-user",
                                role: .user,
                                text: "Question"
                            ))
                        ),
                        .init(
                            id: "message-alpha-agent",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-alpha-agent",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Alpha answer"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-beta",
                    status: .running,
                    items: [
                        .init(
                            id: "message-beta",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-beta",
                                role: .assistant,
                                text: "Beta update"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-snapshot"))
        try await context.refresh(chat)

        let alphaTurn = try #require(chat.turn(id: "turn-alpha"))
        let alphaItem = try #require(chat.items.first { $0.itemID == "message-alpha-user" })
        let alphaItems = chat.items(in: "turn-alpha")
        let betaItems = chat.items(in: "turn-beta")
        let alphaThreadItems = threadItems(from: alphaItems)

        #expect(alphaItems.map(\.itemID) == ["message-alpha-user", "message-alpha-agent"])
        #expect(betaItems.map(\.itemID) == ["message-beta"])
        #expect(alphaItems.first === alphaItem)
        #expect(alphaTurn.status == CodexTurnStatus.completed)
        #expect(alphaTurn.errorDescription == nil)
        #expect(alphaTurn.usage == nil)
        #expect(alphaThreadItems.map(\.id) == ["message-alpha-user", "message-alpha-agent"])
        #expect(CodexTranscript(items: alphaThreadItems).finalAnswer == "Alpha answer")
    }

    @Test("chat turn helpers expose metadata and missing turn results")
    func chatTurnHelpersExposeMetadataAndMissingTurnResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-turn-metadata"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-turn-metadata",
            turns: [
                .init(
                    id: "turn-completed",
                    status: .completed,
                    items: [
                        .init(
                            id: "message-completed",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-completed",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Done"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-failed",
                    status: .failed,
                    errorMessage: "Tool failed",
                    items: [
                        .init(
                            id: "message-failed",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-failed",
                                role: .assistant,
                                text: "Failed"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-turn-metadata"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        let failedTurn = try #require(chat.turn(id: "turn-failed"))
        #expect(failedTurn.status == CodexTurnStatus.failed)
        #expect(failedTurn.errorDescription == "Tool failed")
        #expect(failedTurn.usage == nil)
        #expect(chat.turn(id: "turn-missing") == nil)
        #expect(chat.items(in: "turn-missing").isEmpty)

        try await runtime.transport.emitServerNotification(
            method: "thread/tokenUsage/updated",
            params: TokenUsageParams(
                threadID: "thread-turn-metadata",
                turnID: "turn-completed",
                tokenUsage: .init(
                    total: .init(inputTokens: 13, outputTokens: 21, totalTokens: 34),
                    modelContextWindow: 128_000
                )
            )
        )

        #expect(await eventually {
            chat.turn(id: "turn-completed")?.usage?.totalTokens == 34
        })
        let completedTurn = try #require(chat.turn(id: "turn-completed"))
        #expect(completedTurn.usage?.inputTokens == 13)
        #expect(completedTurn.usage?.outputTokens == 21)
        #expect(completedTurn.usage?.modelContextWindow == 128_000)
        withExtendedLifetime(changes) {}
    }

    @Test("chat send merges response transcript into observable items")
    func chatSendMergesTranscriptItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-send"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-send", status: "running")

        let chat = context.model(for: CodexThreadID(rawValue: "thread-send"))
        let sendTask = Task {
            try await chat.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-send",
                turnID: "turn-send",
                item: .init(
                    id: "message-1",
                    type: "agentMessage",
                    text: "Done",
                    phase: "final_answer"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-send", status: "completed"))
        )

        let response = try await sendTask.value
        let item = try #require(chat.items.first)
        #expect(response.turnID == "turn-send")
        #expect(chat.turns.first?.status == CodexTurnStatus.completed)
        #expect(item.text == "Done")
        #expect(item.turnID == "turn-send")
        #expect(chat.transcript.finalAnswer == "Done")
    }

    @Test("observed chat send emits a loaded phase change")
    func observedChatSendEmitsLoadedPhaseChange() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-send-phase"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-send-phase",
            status: .active(activeFlags: []),
            turns: [.init(id: "turn-existing", status: .running)]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-send-phase"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let updateRecorder = ChatUpdateRecorder(stream: observation.updates)
        #expect(chat.phase == .loading)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-send-phase"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-send-phase", status: "running")
        let sendTask = Task {
            try await chat.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-send-phase", status: "completed"))
        )

        _ = try await sendTask.value

        let phaseChange = await updateRecorder.phaseChanged(.loaded)
        #expect(phaseChange != nil)
        #expect(chat.phase == .loaded)
    }

    @Test("thread event lifecycle updates observable chat status")
    func threadEventLifecycleUpdatesObservableChatStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-status-lifecycle"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-status-lifecycle",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-status-lifecycle"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let updateRecorder = ChatUpdateRecorder(stream: observation.updates)

        #expect(chat.status == .idle)
        #expect(chat.phase == .loaded)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-status-lifecycle",
                turnID: "turn-status-lifecycle"
            )
        )

        #expect(await updateRecorder.statusChanged(.active(activeFlags: [])) != nil)
        #expect(chat.status == .active(activeFlags: []))
        #expect(chat.phase == .loading)

        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-status-lifecycle", status: "completed"))
        )

        #expect(await updateRecorder.statusChanged(.idle) != nil)
        #expect(chat.status == .idle)
        #expect(chat.phase == .loaded)
    }

    @Test("item lifecycle updates observable command status")
    func itemLifecycleUpdatesObservableCommandStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-lifecycle"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-command-lifecycle",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-lifecycle"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-lifecycle",
                turnID: "turn-command-lifecycle"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-command-lifecycle",
                turnID: "turn-command-lifecycle",
                startedAtMs: 1_782_900_000_000,
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )

        #expect(await changes.itemInserted(id: "command-1") != nil)
        let commandItem = try #require(chat.items.first { $0.itemID == "command-1" })
        guard case .command(let startedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(startedCommand.status == .running)
        #expect(startedCommand.startedAt != nil)

        try await runtime.transport.emitServerNotification(
            method: "item/updated",
            params: ThreadItemParams(
                threadID: "thread-command-lifecycle",
                turnID: "turn-command-lifecycle",
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "/bin/zsh -lc",
                    output: "done"
                )
            )
        )
        #expect(await changes.itemUpdated(id: "command-1") != nil)
        guard case .command(let updatedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(updatedCommand.status == .running)

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-command-lifecycle",
                turnID: "turn-command-lifecycle",
                completedAtMs: 1_782_900_001_000,
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "/bin/zsh -lc",
                    output: "done",
                    exitCode: 0,
                    status: "running"
                )
            )
        )
        #expect(await changes.itemUpdated(id: "command-1") != nil)
        guard case .command(let completedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(completedCommand.status == .completed)
        #expect(completedCommand.completedAt != nil)
    }

    @Test("thread inactive status terminalizes running command items when item completion is omitted")
    func threadInactiveStatusTerminalizesRunningCommandItemsWhenItemCompletionIsOmitted() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-status-terminal"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-command-status-terminal",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-status-terminal"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-status-terminal",
                turnID: "turn-command-status-terminal"
            )
        )
        let startedAt = Date().addingTimeInterval(-45)
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-command-status-terminal",
                turnID: "turn-command-status-terminal",
                startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1_000).rounded()),
                item: .init(
                    id: "command-status-terminal",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )

        #expect(await changes.itemInserted(id: "command-status-terminal") != nil)
        let commandItem = try #require(chat.items.first { $0.itemID == "command-status-terminal" })

        try await runtime.transport.emitServerNotification(
            method: "thread/status/changed",
            params: ThreadStatusParams(
                threadID: "thread-command-status-terminal",
                status: .init(type: "idle")
            )
        )

        #expect(await eventually {
            guard case .command(let command) = commandItem.content else {
                return false
            }
            guard let startedAt = command.startedAt,
                let completedAt = command.completedAt
            else {
                return false
            }
            return chat.turn(id: "turn-command-status-terminal")?.status == .completed
                && command.status == .completed
                && completedAt > startedAt
        })
        #expect(await changes.itemUpdated(id: "command-status-terminal") != nil)
        #expect(chat.phase == .loaded)
        #expect(chat.status == .idle)
    }

    @Test("existing later turn content terminalizes running command when item completion is omitted")
    func existingLaterTurnContentTerminalizesRunningCommandWhenItemCompletionIsOmitted()
        async throws
    {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-existing-progress"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-command-existing-progress", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-existing-progress"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-existing-progress",
                turnID: "turn-command-existing-progress"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-command-existing-progress",
                turnID: "turn-command-existing-progress",
                itemID: "message-around-command",
                delta: "Before command"
            )
        )
        let startedAt = Date().addingTimeInterval(-45)
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-command-existing-progress",
                turnID: "turn-command-existing-progress",
                startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1_000).rounded()),
                item: .init(
                    id: "command-existing-progress",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )
        #expect(await eventually {
            chat.items.contains { $0.itemID == "command-existing-progress" }
                && chat.items.contains { $0.itemID == "message-around-command" }
        })
        let commandItem = try #require(chat.items.first { $0.itemID == "command-existing-progress" })
        guard case .command(let startedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(startedCommand.status == .running)

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-command-existing-progress",
                turnID: "turn-command-existing-progress",
                itemID: "message-around-command",
                delta: " after command"
            )
        )

        #expect(await eventually {
            guard case .command(let command) = commandItem.content else {
                return false
            }
            guard let startedAt = command.startedAt,
                let completedAt = command.completedAt
            else {
                return false
            }
            return command.status == .completed
                && completedAt > startedAt
                && chat.items.first { $0.itemID == "message-around-command" }?.text
                    == "Before command after command"
        })
        withExtendedLifetime(changes) {}
    }

    @Test("later turn content terminalizes running command when item completion is omitted")
    func laterTurnContentTerminalizesRunningCommandWhenItemCompletionIsOmitted() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-progress"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-command-progress", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-progress"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-progress",
                turnID: "turn-command-progress"
            )
        )
        let startedAt = Date().addingTimeInterval(-45)
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-command-progress",
                turnID: "turn-command-progress",
                startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1_000).rounded()),
                item: .init(
                    id: "command-progress",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )
        #expect(await eventually {
            chat.items.contains { $0.itemID == "command-progress" }
        })
        let commandItem = try #require(chat.items.first { $0.itemID == "command-progress" })
        guard case .command(let startedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(startedCommand.status == .running)

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-command-progress",
                turnID: "turn-command-progress",
                itemID: "message-after-command",
                delta: "Next step"
            )
        )

        #expect(await eventually {
            guard case .command(let command) = commandItem.content else {
                return false
            }
            guard let startedAt = command.startedAt,
                let completedAt = command.completedAt
            else {
                return false
            }
            return command.status == .completed
                && completedAt > startedAt
                && chat.items.contains { $0.itemID == "message-after-command" }
        })
        withExtendedLifetime(changes) {}
    }

    @Test("late prior command update does not regress terminalized lifecycle items")
    func latePriorCommandUpdateDoesNotRegressTerminalizedLifecycleItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-late-update"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-command-late-update", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-late-update"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-late-update",
                turnID: "turn-command-late-update"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-command-late-update",
                turnID: "turn-command-late-update",
                item: .init(
                    id: "command-first",
                    type: "commandExecution",
                    command: "git status"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-command-late-update",
                turnID: "turn-command-late-update",
                item: .init(
                    id: "command-second",
                    type: "commandExecution",
                    command: "git diff"
                )
            )
        )

        #expect(await eventually {
            chat.items.contains { $0.itemID == "command-first" }
                && chat.items.contains { $0.itemID == "command-second" }
        })
        let firstCommand = try #require(chat.items.first { $0.itemID == "command-first" })
        let secondCommand = try #require(chat.items.first { $0.itemID == "command-second" })
        #expect(await eventually {
            guard case .command(let first) = firstCommand.content,
                case .command(let second) = secondCommand.content
            else {
                return false
            }
            return first.status == .completed && second.status == .running
        })

        try await runtime.transport.emitServerNotification(
            method: "item/updated",
            params: ThreadItemParams(
                threadID: "thread-command-late-update",
                turnID: "turn-command-late-update",
                item: .init(
                    id: "command-first",
                    type: "commandExecution",
                    command: "git status",
                    output: "late output",
                    status: "inProgress"
                )
            )
        )

        #expect(await eventually {
            guard case .command(let first) = firstCommand.content,
                case .command(let second) = secondCommand.content
            else {
                return false
            }
            return first.status == .completed
                && first.output == "late output"
                && second.status == .running
        })
        withExtendedLifetime(changes) {}
    }

    @Test("chat send with revert policy refreshes observed transcript after failure")
    func chatSendWithRevertPolicyRefreshesObservedTranscriptAfterFailure() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-revert"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-revert", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-revert"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-revert"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-revert", status: "running")
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-revert", turns: []))

        let sendTask = Task {
            try await chat.send(
                "hello",
                options: .init(transcriptErrorHandlingPolicy: .revertTranscript)
            )
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-revert",
                turnID: "turn-revert",
                item: .init(
                    id: "message-revert",
                    type: "agentMessage",
                    text: "Failed output",
                    phase: "final_answer"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-revert", status: "failed"))
        )

        do {
            _ = try await sendTask.value
            Issue.record("Expected failed send to throw.")
        } catch {
        }

        #expect(await runtime.transport.recordedRequests(method: "thread/rollback").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").count == 2)
        #expect(chat.items.isEmpty)
        #expect(chat.turns.isEmpty)
    }

    @Test("chat observation refreshes a snapshot and applies live events in place")
    func chatObservationRefreshesSnapshotAndAppliesLiveEventsInPlace() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let completedAt = Date(timeIntervalSince1970: 4_000)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-live"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-live",
            turns: [
                .init(
                    id: "turn-existing",
                    status: .completed,
                    items: [
                        .init(
                            id: "message-existing",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-existing",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Snapshot"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-live"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        let snapshotItem = try #require(chat.items.first)
        #expect(observation.chat === chat)
        #expect(chat.phase == .loaded)
        #expect(snapshotItem.text == "Snapshot")

        try await runtime.transport.emitServerNotification(
            method: "item/updated",
            params: ThreadItemParams(
                threadID: "thread-live",
                turnID: "turn-existing",
                item: .init(
                    id: "message-existing",
                    type: "agentMessage",
                    text: "Snapshot updated",
                    phase: "final_answer"
                )
            )
        )
        #expect(await eventually { snapshotItem.text == "Snapshot updated" })
        #expect(chat.items.first === snapshotItem)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-live", turnID: "turn-live")
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-live",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Hel",
                phase: "final_answer"
            )
        )
        #expect(await eventually {
            chat.items.contains { $0.itemID == "message-live" && $0.text == "Hel" }
        })
        let liveItem = try #require(chat.items.first { $0.itemID == "message-live" })

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-live",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "lo",
                phase: "final_answer"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "thread/tokenUsage/updated",
            params: TokenUsageParams(
                threadID: "thread-live",
                turnID: "turn-live",
                tokenUsage: .init(
                    total: .init(inputTokens: 5, outputTokens: 7, totalTokens: 12),
                    modelContextWindow: 200_000
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-live",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        #expect(await eventually {
            chat.turns.contains { $0.id == "turn-live" && $0.status == .completed }
                && liveItem.text == "Hello"
                && chat.phase == .loaded
        })
        let liveTurn = try #require(chat.turns.first { $0.id == "turn-live" })
        #expect(chat.items.first { $0.itemID == "message-live" } === liveItem)
        #expect(liveTurn.usage?.totalTokens == 12)
        #expect(liveTurn.usage?.modelContextWindow == 200_000)
        #expect(chat.updatedAt == completedAt)
        #expect(chat.transcript.finalAnswer == "Hello")
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        withExtendedLifetime(changes) {}

        observation.cancel()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-live"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-live",
            turns: [
                .init(
                    id: "turn-live",
                    status: .completed,
                    items: [
                        .init(
                            id: "message-live",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-live",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Hello"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let restartedObservation = try await chat.observe()
        defer {
            restartedObservation.cancel()
        }

        #expect(await eventually {
            chat.items.first { $0.itemID == "message-live" }?.text == "Hello"
        })
        #expect(chat.items.filter { $0.itemID == "message-live" }.count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 2)
    }

    @Test("chat observation rejects concurrent include-turn upgrade")
    func chatObservationRejectsConcurrentIncludeTurnUpgrade() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-upgrade"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-upgrade"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-upgrade"))
        let metadataObservation = try await chat.observe(includeTurns: false)
        defer {
            metadataObservation.cancel()
        }

        #expect(chat.turn(id: "turn-history") == nil)

        do {
            _ = try await chat.observe(includeTurns: true)
            Issue.record("Expected concurrent observation to throw.")
        } catch CodexModelContextError.chatObservationAlreadyActive(let id) {
            #expect(id == chat.id)
        }

        metadataObservation.cancel()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-upgrade"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-upgrade",
            turns: [
                .init(
                    id: "turn-history",
                    status: .completed,
                    items: [
                        .init(
                            id: "message-history",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-history",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Loaded from upgrade"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let turnObservation = try await chat.observe(includeTurns: true)
        defer {
            turnObservation.cancel()
        }

        let turn = try #require(chat.turn(id: "turn-history"))
        #expect(turn.status == .completed)
        #expect(chat.items(in: "turn-history").map(\.text) == ["Loaded from upgrade"])
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 2)
        let readRequests = await runtime.transport.recordedRequests(method: "thread/read")
        #expect(readRequests.count == 2)
        let firstParams = try readRequests[0].decodeParams(ThreadReadParams.self)
        let secondParams = try readRequests[1].decodeParams(ThreadReadParams.self)
        #expect(firstParams.includeTurns == false)
        #expect(secondParams.includeTurns == true)
    }

    @Test("finished chat observations are not reused")
    func finishedChatObservationsAreNotReused() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-finished"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-finished"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-finished"))
        let firstObservation = try await chat.observe()
        defer {
            firstObservation.cancel()
        }
        let firstChanges = ChatUpdateRecorder(stream: firstObservation.updates)

        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-finished")
        )
        #expect(await eventually { chat.status == .notLoaded && chat.phase == .loaded })
        #expect(await eventually { firstChanges.isFinished })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-finished"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-finished",
            turns: [.init(id: "turn-restarted", status: .completed)]
        ))

        let restartedObservation = try await chat.observe()
        defer {
            restartedObservation.cancel()
        }
        let restartedChanges = ChatUpdateRecorder(stream: restartedObservation.updates)

        #expect(chat.turn(id: "turn-restarted") != nil)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 2)

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-finished",
                turnID: "turn-restarted",
                itemID: "message-restarted",
                delta: "Live after restart",
                phase: "final_answer"
            )
        )

        #expect(await eventually {
            chat.items.first { $0.itemID == "message-restarted" }?.text == "Live after restart"
        })
        withExtendedLifetime(restartedChanges) {}
    }

    @Test("chat observation change streams finish when setup consumes terminal events")
    func chatObservationChangeStreamsFinishWhenSetupConsumesTerminalEvents() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let gate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-terminal-setup"))
        await runtime.transport.holdNext(method: "thread/read", gate: gate)
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-terminal-setup"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-terminal-setup"))
        var observedChat: CodexChatObservation?
        let observeTask = Task { @MainActor in
            observedChat = try await chat.observe()
        }

        await runtime.transport.waitForRequest(method: "thread/read")
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-terminal-setup")
        )
        await gate.open()

        try await observeTask.value
        let observation = try #require(observedChat)
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)
        #expect(observation.chat === chat)
        #expect(observation.chat.id == "thread-terminal-setup")
        #expect(await eventually { changes.isFinished })
    }

    @Test("chat observation keeps refreshed output snapshots idempotent with replayed deltas")
    func chatObservationKeepsRefreshedOutputSnapshotsIdempotentWithReplayedDeltas() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-replay",
                turnID: "turn-replay",
                itemID: "command-replay",
                delta: "Hel"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-replay",
                turnID: "turn-replay",
                itemID: "command-replay",
                delta: "lo"
            )
        )
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-replay"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-replay",
            turns: [
                .init(
                    id: "turn-replay",
                    status: .running,
                    items: [
                        .init(
                            id: "command-replay",
                            kind: .commandExecution,
                            content: .command(.init(command: "echo hello", output: "Hello"))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-replay"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        try? await Task.sleep(for: .milliseconds(100))

        #expect(chat.items.first { $0.itemID == "command-replay" }?.text == "Hello")
        #expect(chat.items.filter { $0.itemID == "command-replay" }.count == 1)
    }

    @Test("chat observation keeps refreshed message snapshots idempotent with buffered replayed deltas")
    func chatObservationKeepsRefreshedMessageSnapshotsIdempotentWithBufferedReplayedDeltas() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let gate = CodexAppServerTestGate()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-message-replay"))
        await runtime.transport.holdNext(method: "thread/read", gate: gate)
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-message-replay",
            turns: [
                .init(
                    id: "turn-message-replay",
                    status: .running,
                    items: [
                        .init(
                            id: "message-replay",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-replay",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Hello"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-message-replay"))
        var observedChat: CodexChatObservation?
        let observeTask = Task { @MainActor in
            observedChat = try await chat.observe()
        }
        await runtime.transport.waitForRequest(method: "thread/read")

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-message-replay",
                turnID: "turn-message-replay",
                itemID: "message-replay",
                delta: "Hel",
                phase: "final_answer"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-message-replay",
                turnID: "turn-message-replay",
                itemID: "message-replay",
                delta: "lo",
                phase: "final_answer"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-message-replay",
                turnID: "turn-message-replay",
                itemID: "message-replay",
                delta: " world",
                phase: "final_answer"
            )
        )
        await gate.open()

        try await observeTask.value
        let observation = try #require(observedChat)
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        #expect(await eventually {
            chat.items.first { $0.itemID == "message-replay" }?.text == "Hello world"
        })
        #expect(chat.items.filter { $0.itemID == "message-replay" }.count == 1)
        withExtendedLifetime(changes) {}
    }

    @Test("duplicate chat observations are rejected")
    func duplicateChatObservationsAreRejected() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-duplicate"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-duplicate"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-duplicate"))
        let firstObservation = try await chat.observe()
        defer {
            firstObservation.cancel()
        }

        do {
            _ = try await chat.observe()
            Issue.record("Expected duplicate observation to throw.")
        } catch CodexModelContextError.chatObservationAlreadyActive(let id) {
            #expect(id == chat.id)
        }
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    @Test("chat observation coalesces duplicate narrative snapshot items")
    func chatObservationCoalescesDuplicateNarrativeSnapshotItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-duplicate-history"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-duplicate-history",
            turns: [
                .init(
                    id: "turn-duplicate-history",
                    status: .running,
                    items: [
                        .init(
                            id: "review-a",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                        .init(
                            id: "user-a",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "user-a",
                                role: .user,
                                text: "Review current changes"
                            ))
                        ),
                        .init(
                            id: "reasoning-a",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: "Checking diff"))
                        ),
                        .init(
                            id: "command-a",
                            kind: .commandExecution,
                            content: .command(.init(command: "/bin/zsh -lc"))
                        ),
                        .init(
                            id: "review-b",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                        .init(
                            id: "user-b",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "user-b",
                                role: .user,
                                text: "Review current changes"
                            ))
                        ),
                        .init(
                            id: "reasoning-b",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: "Checking diff"))
                        ),
                        .init(
                            id: "command-b",
                            kind: .commandExecution,
                            content: .command(.init(command: "/bin/zsh -lc"))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-duplicate-history"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        #expect(chat.items.map(\.itemID) == [
            "review-a",
            "user-a",
            "reasoning-a",
            "command-a",
            "command-b",
        ])
    }

    @Test("chat observation preserves replay narrative snapshot items across turns")
    func chatObservationPreservesReplayNarrativeSnapshotItemsAcrossTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-replay-history"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-replay-history",
            turns: [
                .init(
                    id: "turn-replay-a",
                    status: .completed,
                    items: [
                        .init(
                            id: "review-a",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                        .init(
                            id: "user-a",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "user-a",
                                role: .user,
                                text: "Review current changes"
                            ))
                        ),
                        .init(
                            id: "reasoning-a",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: "Checking diff"))
                        ),
                        .init(
                            id: "diagnostic-a",
                            kind: .diagnostic,
                            content: .diagnostic("Review was interrupted.")
                        ),
                        .init(
                            id: "answer-a",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "answer-a",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Same final answer"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-replay-b",
                    status: .completed,
                    items: [
                        .init(
                            id: "review-b",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                        .init(
                            id: "user-b",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "user-b",
                                role: .user,
                                text: "Review current changes"
                            ))
                        ),
                        .init(
                            id: "reasoning-b",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: "Checking diff"))
                        ),
                        .init(
                            id: "diagnostic-b",
                            kind: .diagnostic,
                            content: .diagnostic("Review was interrupted.")
                        ),
                        .init(
                            id: "answer-b",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "answer-b",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Same final answer"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-replay-c",
                    status: .completed,
                    items: [
                        .init(
                            id: "reasoning-c",
                            kind: .reasoning,
                            content: .reasoning(.init(
                                summary: ["Checking diff"],
                                content: ["Distinct raw trace"]
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-replay-history"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        #expect(chat.items.map(\.itemID) == [
            "review-a",
            "user-a",
            "reasoning-a",
            "diagnostic-a",
            "answer-a",
            "review-b",
            "user-b",
            "reasoning-b",
            "diagnostic-b",
            "answer-b",
            "reasoning-c",
        ])
    }

    @Test("chat observation preserves replay narrative live items across turns")
    func chatObservationPreservesReplayNarrativeLiveItemsAcrossTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-replay-live"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-replay-live", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-replay-live"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        for turnID in ["turn-replay-a", "turn-replay-b"] {
            try await runtime.transport.emitServerNotification(
                method: "item/started",
                params: ThreadItemParams(
                    threadID: "thread-replay-live",
                    turnID: turnID,
                    item: .init(
                        id: "reasoning-\(turnID)",
                        type: "reasoning",
                        text: "Checking diff"
                    )
                )
            )
            try await runtime.transport.emitServerNotification(
                method: "item/started",
                params: ThreadItemParams(
                    threadID: "thread-replay-live",
                    turnID: turnID,
                    item: .init(
                        id: "diagnostic-\(turnID)",
                        type: "diagnostic",
                        text: "Review was interrupted."
                    )
                )
            )
        }

        #expect(await eventually {
            chat.items.map(\.itemID) == [
                "reasoning-turn-replay-a",
                "diagnostic-turn-replay-a",
                "reasoning-turn-replay-b",
                "diagnostic-turn-replay-b",
            ]
        })
        withExtendedLifetime(changes) {}
    }

    @Test("chat observation removes reasoning parts only within the same turn")
    func chatObservationRemovesReasoningPartsOnlyWithinSameTurn() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-reasoning-parts"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-reasoning-parts", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-reasoning-parts"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        for turnID in ["turn-a", "turn-b"] {
            try await runtime.transport.emitServerNotification(
                method: "item/started",
                params: ThreadItemParams(
                    threadID: "thread-reasoning-parts",
                    turnID: turnID,
                    item: .init(
                        id: "reasoning-parent:summary:0",
                        type: "reasoning",
                        text: "Checking diff"
                    )
                )
            )
        }
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-reasoning-parts",
                turnID: "turn-b",
                item: .init(
                    id: "reasoning-parent",
                    type: "reasoning",
                    text: "Checked diff"
                )
            )
        )

        #expect(await eventually {
            chat.items.map { "\($0.turnID?.rawValue ?? "nil"):\($0.itemID)" } == [
                "turn-a:reasoning-parent:summary:0",
                "turn-b:reasoning-parent",
            ]
        })
        withExtendedLifetime(changes) {}
    }

    @Test("chat observation coalesces duplicate narrative live items")
    func chatObservationCoalescesDuplicateNarrativeLiveItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-duplicate-live"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-duplicate-live", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-duplicate-live"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "review-a",
                    type: "enteredReviewMode",
                    text: "current changes"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "reasoning-a",
                    type: "reasoning",
                    text: "Checking diff"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "command-a",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "review-b",
                    type: "enteredReviewMode",
                    text: "current changes"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "reasoning-b",
                    type: "reasoning",
                    text: "Checking diff"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "command-b",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )

        #expect(await eventually {
            chat.items.map(\.itemID) == [
                "review-a",
                "reasoning-a",
                "command-a",
                "command-b",
            ]
        })
        withExtendedLifetime(changes) {}
    }

    @Test("chat observations stream snapshots and item text changes")
    func chatObservationsStreamSnapshotsAndItemTextChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-changes"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-changes",
            turns: [
                .init(
                    id: "turn-existing",
                    status: .completed,
                    items: [
                        .init(
                            id: "message-existing",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-existing",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Snapshot"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-changes"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)
        #expect(observation.chat === chat)
        #expect(chat.items.map(\.text) == ["Snapshot"])

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-changes",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Hel",
                phase: "final_answer"
            )
        )

        let insertedChange = await changes.itemInserted(id: "message-live")
        #expect(insertedChange != nil)
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Hel")

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-changes",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "lo",
                phase: "final_answer"
            )
        )

        guard case .itemTextAppended(let id, let turnID, let delta) =
            await changes.itemTextAppended(id: "message-live", delta: "lo")
        else {
            Issue.record("Expected appended text change.")
            return
        }
        #expect(id == "message-live")
        #expect(turnID == "turn-live")
        #expect(delta == "lo")
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Hello")

        try await runtime.transport.emitServerNotification(
            method: "item/updated",
            params: ThreadItemParams(
                threadID: "thread-changes",
                turnID: "turn-live",
                item: .init(
                    id: "message-live",
                    type: "agentMessage",
                    text: "Rewritten",
                    phase: "final_answer"
                )
            )
        )

        let updatedChange = await changes.itemUpdated(id: "message-live")
        #expect(updatedChange != nil)
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Rewritten")
    }

    @Test("turnless item identities are scoped per chat")
    func turnlessItemIdentitiesAreScopedPerChat() async throws {
        let runtime = try await CodexAppServerTestRuntime.start(threads: [
            .init(id: "thread-turnless-alpha", status: .active(activeFlags: []), turns: []),
            .init(id: "thread-turnless-beta", status: .active(activeFlags: []), turns: []),
        ])
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let alpha = context.model(for: CodexThreadID(rawValue: "thread-turnless-alpha"))
        let beta = context.model(for: CodexThreadID(rawValue: "thread-turnless-beta"))
        let alphaObservation = try await alpha.observe()
        let betaObservation = try await beta.observe()
        defer {
            alphaObservation.cancel()
            betaObservation.cancel()
        }
        let alphaChanges = ChatUpdateRecorder(stream: alphaObservation.updates)
        let betaChanges = ChatUpdateRecorder(stream: betaObservation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: ThreadScopedDeltaParams(
                threadID: "thread-turnless-alpha",
                itemID: "shared-message",
                delta: "Alpha",
                phase: "final_answer"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: ThreadScopedDeltaParams(
                threadID: "thread-turnless-beta",
                itemID: "shared-message",
                delta: "Beta",
                phase: "final_answer"
            )
        )

        #expect(await alphaChanges.itemInserted(id: "shared-message") != nil)
        #expect(await betaChanges.itemInserted(id: "shared-message") != nil)
        let alphaItem = try #require(alpha.items.first { $0.itemID == "shared-message" })
        let betaItem = try #require(beta.items.first { $0.itemID == "shared-message" })
        #expect(alphaItem !== betaItem)
        #expect(alphaItem.chat === alpha)
        #expect(betaItem.chat === beta)
        #expect(alphaItem.text == "Alpha")
        #expect(betaItem.text == "Beta")
    }

    @Test("chat item identity ignores kind changes from baseline to live updates")
    func chatItemIdentityIgnoresKindChangesFromBaselineToLiveUpdates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-kind-change"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-kind-change",
            turns: [
                .init(
                    id: "turn-kind-change",
                    status: .running,
                    items: [
                        .init(
                            id: "item-kind-change",
                            kind: .unknown("progress"),
                            content: .diagnostic("Initial")
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-kind-change"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)
        let originalItem = try #require(chat.items.first)

        try await runtime.transport.emitServerNotification(
            method: "item/updated",
            params: ThreadItemParams(
                threadID: "thread-kind-change",
                turnID: "turn-kind-change",
                item: .init(
                    id: "item-kind-change",
                    type: "diagnostic",
                    text: "Updated"
                )
            )
        )

        let updatedChange = await changes.itemUpdated(id: "item-kind-change")
        #expect(updatedChange != nil)
        #expect(chat.items.count == 1)
        #expect(chat.items.first === originalItem)
        #expect(chat.items.first?.kind == .diagnostic)
        #expect(chat.items.first?.text == "Updated")
    }

    @Test("active chat refresh emits snapshots after phase reconciliation")
    func activeChatRefreshEmitsSnapshotsAfterPhaseReconciliation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-stream"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-stream",
            status: .active(activeFlags: []),
            turns: [.init(id: "turn-running", status: .running)]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-stream"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)
        #expect(chat.phase == .loading)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-stream"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-stream",
            status: .idle,
            turns: []
        ))

        try await context.refresh(chat)

        #expect(await changes.resynchronized(reason: .refresh) != nil)
        #expect(chat.phase == .loaded)
    }

    @Test("active chat refresh preserves live-streamed items omitted by lagging snapshots")
    func activeChatRefreshPreservesLiveStreamedItemsOmittedByLaggingSnapshots() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-live"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-live",
            status: .active(activeFlags: []),
            turns: [
                .init(
                    id: "turn-existing",
                    status: .running,
                    items: [
                        .init(
                            id: "message-existing",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-existing",
                                role: .assistant,
                                text: "Snapshot baseline"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-live"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-refresh-live",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Live update",
                phase: "final_answer"
            )
        )
        #expect(await changes.itemInserted(id: "message-live") != nil)
        let liveItem = try #require(chat.items.first { $0.itemID == "message-live" })

        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-existing",
                status: .running,
                items: [
                    .init(
                        id: "message-existing",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-existing",
                            role: .assistant,
                            text: "Snapshot baseline"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-live",
            status: .active(activeFlags: [])
        ))

        try await context.refresh(chat)

        #expect(chat.items.first { $0.itemID == "message-live" } === liveItem)
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Live update")
        #expect(chat.turns.contains { $0.id == "turn-live" })
    }

    @Test("active chat refresh preserves replay reasoning across turns")
    func activeChatRefreshPreservesReplayReasoningAcrossTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-replay"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-replay",
            status: .active(activeFlags: []),
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-replay"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-refresh-replay",
                turnID: "turn-live",
                item: .init(
                    id: "reasoning-live",
                    type: "reasoning",
                    text: "Checking diff"
                )
            )
        )
        #expect(await changes.itemInserted(id: "reasoning-live") != nil)

        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-snapshot",
                status: .running,
                items: [
                    .init(
                        id: "reasoning-snapshot",
                        kind: .reasoning,
                        content: .reasoning(.init(summary: "Checking diff"))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-replay",
            status: .active(activeFlags: [])
        ))

        try await context.refresh(chat)

        #expect(chat.items.map(\.itemID) == ["reasoning-live", "reasoning-snapshot"])
        #expect(chat.turns.contains { $0.id == "turn-live" })
        #expect(chat.turns.contains { $0.id == "turn-snapshot" })
    }

    @Test("terminal chat refresh replaces live-streamed items with authoritative snapshot")
    func terminalChatRefreshReplacesLiveStreamedItemsWithAuthoritativeSnapshot() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-terminal"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-terminal",
            status: .active(activeFlags: []),
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-terminal"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-refresh-terminal",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Live duplicate",
                phase: "final_answer"
            )
        )
        #expect(await changes.itemInserted(id: "message-live") != nil)
        #expect(chat.items.map(\.itemID) == ["message-live"])

        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-authoritative",
                status: .completed,
                items: [
                    .init(
                        id: "message-authoritative",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-authoritative",
                            role: .assistant,
                            text: "Authoritative"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-terminal",
            status: .idle
        ))

        try await context.refresh(chat)

        #expect(chat.turns.map(\.id.rawValue) == ["turn-authoritative"])
        #expect(chat.items.map(\.itemID) == ["message-authoritative"])
        #expect(chat.items.map(\.text) == ["Authoritative"])
    }

    @Test("not-loaded metadata refresh replaces live-streamed items with authoritative turns")
    func notLoadedMetadataRefreshReplacesLiveStreamedItemsWithAuthoritativeTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-not-loaded"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-not-loaded",
            status: .active(activeFlags: []),
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-not-loaded"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-refresh-not-loaded",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Live duplicate",
                phase: "final_answer"
            )
        )
        #expect(await changes.itemInserted(id: "message-live") != nil)
        #expect(chat.items.map(\.itemID) == ["message-live"])

        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-authoritative",
                status: .completed,
                items: [
                    .init(
                        id: "message-authoritative",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-authoritative",
                            role: .assistant,
                            text: "Authoritative interruption"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-not-loaded",
            status: .notLoaded
        ))

        try await context.refresh(chat)

        #expect(chat.status == .notLoaded)
        #expect(chat.turns.map(\.id.rawValue) == ["turn-authoritative"])
        #expect(chat.items.map(\.itemID) == ["message-authoritative"])
        #expect(chat.items.map(\.text) == ["Authoritative interruption"])
    }

    @Test("not-loaded metadata fallback preserves live-streamed items omitted by turns")
    func notLoadedMetadataFallbackPreservesLiveStreamedItemsOmittedByTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-not-loaded-fallback"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-not-loaded-fallback",
            status: .active(activeFlags: []),
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-not-loaded-fallback"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-refresh-not-loaded-fallback",
                turnID: "turn-live"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-refresh-not-loaded-fallback",
                turnID: "turn-live",
                item: .init(
                    id: "command-live",
                    type: "commandExecution",
                    command: "/bin/zsh -lc 'git status --short'"
                )
            )
        )
        #expect(await changes.itemInserted(id: "command-live") != nil)
        let liveCommand = try #require(chat.items.first { $0.itemID == "command-live" })

        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-summary",
                status: .interrupted,
                items: [
                    .init(
                        id: "message-interrupted",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-interrupted",
                            role: .assistant,
                            text: "Review was interrupted."
                        ))
                    ),
                ]
            ),
        ]))
        await runtime.transport.enqueueFailure(
            code: -32_004,
            message: "thread not loaded: thread-refresh-not-loaded-fallback",
            for: "thread/read"
        )

        try await context.refresh(chat)

        #expect(chat.status == .notLoaded)
        #expect(chat.items.first { $0.itemID == "command-live" } === liveCommand)
        #expect(chat.items.first { $0.itemID == "message-interrupted" }?.text == "Review was interrupted.")
        #expect(chat.items.map(\.itemID).contains("command-live"))
        #expect(chat.items.map(\.itemID).contains("message-interrupted"))
    }

    @Test("restarted chat observation preserves prior live-streamed items omitted by lagging snapshots")
    func restartedChatObservationPreservesPriorLiveStreamedItemsOmittedByLaggingSnapshots() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-reobserve-live"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-reobserve-live",
            status: .active(activeFlags: []),
            turns: [
                .init(
                    id: "turn-existing",
                    status: .running,
                    items: [
                        .init(
                            id: "message-existing",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-existing",
                                role: .assistant,
                                text: "Snapshot baseline"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-reobserve-live"))
        let observation = try await chat.observe()
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-reobserve-live",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Live update",
                phase: "final_answer"
            )
        )
        #expect(await changes.itemInserted(id: "message-live") != nil)
        let liveItem = try #require(chat.items.first { $0.itemID == "message-live" })
        let liveTurn = try #require(chat.turn(id: "turn-live"))

        observation.cancel()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-reobserve-live"))
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-existing",
                status: .running,
                items: [
                    .init(
                        id: "message-existing",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-existing",
                            role: .assistant,
                            text: "Snapshot baseline"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-reobserve-live",
            status: .active(activeFlags: [])
        ))

        let restartedObservation = try await chat.observe()
        defer {
            restartedObservation.cancel()
        }

        #expect(chat.items.first { $0.itemID == "message-live" } === liveItem)
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Live update")
        #expect(chat.turn(id: "turn-live") === liveTurn)
        #expect(chat.items.map(\.itemID).filter { $0 == "message-live" }.count == 1)
    }

    @Test("active chat refresh applies buffered live events after read failure")
    func activeChatRefreshAppliesBufferedLiveEventsAfterReadFailure() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-failure"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-refresh-failure"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-failure"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        let gate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-failure"))
        await runtime.transport.holdNext(method: "thread/read", gate: gate)
        await runtime.transport.enqueueFailure(
            code: -32000,
            message: "read failed",
            for: "thread/read"
        )

        let refreshTask = Task {
            try await context.refresh(chat)
        }

        await runtime.transport.waitForRequest(method: "thread/read", count: 2)
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-refresh-failure",
                turnID: "turn-buffered",
                itemID: "message-buffered",
                delta: "Buffered",
                phase: "final_answer"
            )
        )
        await gate.open()

        do {
            _ = try await refreshTask.value
            Issue.record("Expected refresh to throw.")
        } catch {
        }

        let inserted = await changes.itemInserted(id: "message-buffered")
        #expect(inserted != nil)
        #expect(chat.items.first { $0.itemID == "message-buffered" }?.text == "Buffered")
    }

    @Test("active chat observation owns the update stream")
    func activeChatObservationOwnsTheUpdateStream() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-shared-changes"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-shared-changes"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-shared-changes"))
        let firstObservation = try await chat.observe()
        defer {
            firstObservation.cancel()
        }
        #expect(firstObservation.chat === chat)

        do {
            _ = try await chat.observe()
            Issue.record("Expected duplicate observation to throw.")
        } catch CodexModelContextError.chatObservationAlreadyActive(let id) {
            #expect(id == chat.id)
        }
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    @Test("chat observation preserves loading phase for active thread snapshots")
    func chatObservationPreservesLoadingPhaseForActiveThreadSnapshots() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-running"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-running",
            status: .active(activeFlags: []),
            turns: [.init(id: "turn-running", status: .running)]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-running"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        #expect(chat.phase == .loading)
        #expect(chat.turn(id: "turn-running")?.status == .running)
    }

    @Test("thread closed notifications preserve failed chat phase")
    func threadClosedNotificationsPreserveFailedChatPhase() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-failed"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-failed"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-failed"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        await runtime.transport.emitServerNotificationJSON(
            method: "turn/failed",
            json: """
            {
              "threadId": "thread-failed",
              "turnId": "turn-failed",
              "error": { "message": "Tool failed" }
            }
            """
        )

        #expect(await eventually { chat.phase == .failed("Tool failed") })

        try await runtime.transport.emitServerNotification(
            method: "thread/status/changed",
            params: ThreadStatusParams(threadID: "thread-failed", status: .init(type: "closed"))
        )
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-failed")
        )

        #expect(await eventually { chat.phase == .failed("Tool failed") })
        withExtendedLifetime(changes) {}
    }

    @Test("thread closed notifications clear active chat status")
    func threadClosedNotificationsClearActiveChatStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-closed-status"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-closed-status"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-closed-status"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "thread/status/changed",
            params: ThreadStatusParams(threadID: "thread-closed-status", status: .init(type: "active"))
        )
        #expect(await eventually {
            if case .active = chat.status {
                return true
            }
            return false
        })

        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-closed-status")
        )

        #expect(await eventually { chat.status == .notLoaded && chat.phase == .loaded })
        withExtendedLifetime(changes) {}
    }

    @Test("live item output deltas accumulate until replacement arrives")
    func liveItemOutputDeltasAccumulateUntilReplacementArrives() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-output"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-output"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-output"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-output",
                turnID: "turn-output",
                itemID: "command-output",
                delta: "Hel"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-output",
                turnID: "turn-output",
                itemID: "command-output",
                delta: "lo"
            )
        )

        #expect(await eventually {
            chat.items.first { $0.itemID == "command-output" }?.text == "Hello"
        })

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-output",
                turnID: "turn-output",
                item: .init(
                    id: "command-output",
                    type: "commandExecution",
                    text: "Completed output",
                    phase: nil
                )
            )
        )

        #expect(await eventually {
            chat.items.first { $0.itemID == "command-output" }?.text == "Completed output"
        })
        withExtendedLifetime(changes) {}
    }

    @Test("replacement file change updates do not append output")
    func replacementFileChangeUpdatesDoNotAppendOutput() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-patch-replacement"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-patch-replacement"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-patch-replacement"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)
        func fileChangePath() -> String? {
            guard let item = chat.items.first(where: { $0.itemID == "file-patch" }),
                case .fileChange(let fileChange) = item.content
            else {
                return nil
            }
            return fileChange.path
        }

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-patch-replacement",
                turnID: "turn-patch-replacement",
                item: .init(
                    id: "file-patch",
                    type: "fileChange",
                    text: "Initial patch",
                    path: "Sources/File.swift"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/fileChange/patchUpdated",
            params: FileChangePatchUpdatedParams(
                threadID: "thread-patch-replacement",
                turnID: "turn-patch-replacement",
                itemID: "file-patch",
                displayText: "Patch one"
            )
        )
        #expect(await eventually {
            chat.items.first { $0.itemID == "file-patch" }?.text == "Patch one"
        })
        #expect(fileChangePath() == "Sources/File.swift")

        try await runtime.transport.emitServerNotification(
            method: "item/fileChange/patchUpdated",
            params: FileChangePatchUpdatedParams(
                threadID: "thread-patch-replacement",
                turnID: "turn-patch-replacement",
                itemID: "file-patch",
                displayText: "Patch two"
            )
        )

        #expect(await eventually {
            chat.items.first { $0.itemID == "file-patch" }?.text == "Patch two"
        })
        #expect(fileChangePath() == "Sources/File.swift")
        withExtendedLifetime(changes) {}
    }

    @Test("chat send revalidates recent fetched results")
    func chatSendRevalidatesRecentFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstUpdate = Date(timeIntervalSince1970: 1_000)
        let secondUpdate = Date(timeIntervalSince1970: 2_000)
        let completedAt = Date(timeIntervalSince1970: 3_000)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", name: "Alpha", updatedAt: firstUpdate),
            .init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let alpha = try #require(results.items.first { $0.id.rawValue == "thread-alpha" })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-alpha", status: "running")
        let sendTask = Task {
            try await alpha.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-alpha",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        _ = try await sendTask.value

        #expect(alpha.updatedAt == completedAt)
        #expect(results.items.map(\.id.rawValue) == ["thread-alpha", "thread-beta"])
    }

    @Test("chat send moves the chat to the front of its workspace")
    func chatSendMovesChatToFrontOfWorkspace() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let firstUpdate = Date(timeIntervalSince1970: 1_000)
        let secondUpdate = Date(timeIntervalSince1970: 2_000)
        let completedAt = Date(timeIntervalSince1970: 3_000)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspaceURL, name: "Alpha", updatedAt: firstUpdate),
            .init(id: "thread-beta", workspace: workspaceURL, name: "Beta", updatedAt: secondUpdate),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await results.performFetch()
        let alpha = try #require(results.items.first { $0.id.rawValue == "thread-alpha" })
        let workspace = try #require(alpha.workspace)
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-beta", "thread-alpha"])

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-alpha", status: "running")
        let sendTask = Task {
            try await alpha.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-alpha",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        _ = try await sendTask.value

        #expect(workspace.chats.map(\.id.rawValue) == ["thread-alpha", "thread-beta"])
    }

    @Test("chat send refreshes primary recency-sorted fetched results")
    func chatSendRefreshesPrimaryRecencySortedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstUpdate = Date(timeIntervalSince1970: 1_000)
        let secondUpdate = Date(timeIntervalSince1970: 2_000)
        let completedAt = Date(timeIntervalSince1970: 3_000)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", name: "Alpha", updatedAt: firstUpdate),
            .init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
        ))
        try await results.performFetch()
        let alpha = try #require(results.items.first { $0.id.rawValue == "thread-alpha" })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-alpha", status: "running")
        let sendTask = Task {
            try await alpha.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate),
            .init(id: "thread-alpha", name: "Alpha", updatedAt: completedAt),
        ]))
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-alpha",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        _ = try await sendTask.value

        #expect(results.items.map(\.id.rawValue) == ["thread-beta", "thread-alpha"])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("chat send refreshes incomplete paged results for off-page updates")
    func chatSendRefreshesIncompletePagedResultsForOffPageUpdates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstUpdate = Date(timeIntervalSince1970: 1_000)
        let secondUpdate = Date(timeIntervalSince1970: 2_000)
        let completedAt = Date(timeIntervalSince1970: 3_000)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", name: "Alpha", updatedAt: firstUpdate),
            .init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await allResults.performFetch()
        let alpha = try #require(allResults.items.first { $0.id.rawValue == "thread-alpha" })

        try await runtime.transport.enqueueThreadList(.init(
            threads: [.init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate)],
            nextCursor: "next"
        ))
        let pagedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await pagedResults.performFetch()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-alpha", status: "running")
        try await runtime.transport.enqueueThreadList(.init(
            threads: [.init(id: "thread-alpha", name: "Alpha", updatedAt: completedAt)],
            nextCursor: "next"
        ))
        let sendTask = Task {
            try await alpha.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-alpha",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        _ = try await sendTask.value

        #expect(pagedResults.items.map(\.id.rawValue) == ["thread-alpha"])
    }

    @Test("workspace starts new chats through its model context")
    func workspaceStartsNewChatThroughContext() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(
            .init(threads: [
                .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
            ]))
        let workspaceResults = context.fetchedResults(
            for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new", model: "gpt-5")

        let chat = try await workspace.startChat(.init(options: .init(model: "gpt-5")))

        #expect(chat.id == "thread-new")
        #expect(chat.workspace === workspace)
        #expect(workspace.chats.first === chat)

        let request = try #require(
            await runtime.transport.recordedRequests(method: "thread/start").first)
        let params = try request.decodeParams(ThreadStartParams.self)
        #expect(params.cwd == workspaceURL.path)
        #expect(params.model == "gpt-5")
    }

    @Test("model context starts reviews and inserts the active review chat into fetched results")
    func modelContextStartsReviewAndInsertsActiveChatIntoFetchedResults() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(
                    id: "thread-existing",
                    workspace: workspaceURL,
                    name: "Existing",
                    modelProvider: "openai",
                    recencyAt: Date(timeIntervalSince1970: 1_000)
                ),
            ],
            nextCursor: "server-next"
        ))
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-review", reviewThreadID: "thread-review")
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
            ))
        try await results.performFetch()

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )

        #expect(results.items.first === started.chat)
        #expect(results.items.map(\.id.rawValue) == ["thread-review", "thread-existing"])
        #expect(started.chat.id == started.session.activeTurnThreadID)
        #expect(started.chat.workspace?.url.path == workspaceURL.path)
        #expect(started.chat.preview == "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings.")
        #expect(started.chat.title == started.chat.preview)

        let requests = await runtime.transport.recordedRequests().map(\.method)
        #expect(requests.contains("thread/start"))
        #expect(requests.contains("review/start"))
        #expect(requests.filter { $0 == "thread/list" }.count == 1)
    }

    @Test("started review seed does not truncate an existing chat transcript")
    func startedReviewSeedDoesNotTruncateExistingChatTranscript() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let existingChat = context.model(for: CodexThreadID(rawValue: "thread-review"))
        let existingSnapshot = CodexThreadSnapshot(
            id: "thread-review",
            workspace: workspaceURL,
            turns: [
                .init(
                    id: "turn-existing-user",
                    status: .completed,
                    itemsLoadState: .full,
                    items: [
                        .init(
                            id: "existing-user-message",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "existing-user-message",
                                role: .user,
                                text: "previous request"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-existing-agent",
                    status: .completed,
                    itemsLoadState: .full,
                    items: [
                        .init(
                            id: "existing-agent-message",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "existing-agent-message",
                                role: .assistant,
                                text: "previous response"
                            ))
                        ),
                    ]
                ),
            ]
        )
        existingChat.apply(
            existingSnapshot,
            workspace: nil
        )

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            .init(
                id: "turn-seed",
                status: .running,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "turn-seed",
                        kind: .userMessage,
                        content: .message(.init(
                            id: "turn-seed",
                            role: .user,
                            text: "current changes"
                        ))
                    ),
                ]
            ),
            reviewThreadID: "thread-review"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )

        #expect(started.chat === existingChat)
        #expect(started.chat.turns.map(\.id.rawValue) == [
            "turn-existing-user",
            "turn-existing-agent",
            "turn-seed",
        ])
        #expect(started.chat.items.map(\.itemID) == [
            "existing-user-message",
            "existing-agent-message",
            "turn-seed",
        ])
        #expect(started.chat.items.map(\.text) == [
            "previous request",
            "previous response",
            "current changes",
        ])
    }

    @Test("model actor review start multicasts the active review to the main context")
    func modelActorReviewStartMulticastsActiveReviewToMainContext() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let container = CodexModelContainer(appServer: runtime.server)
        let mainContext = container.mainContext
        let actor = TestCodexModelActor(modelContainer: container)
        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let results = mainContext.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
            ))
        try await results.performFetch()

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "thread/resume should not be needed for a just-started review",
            for: "thread/resume"
        )
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let reviewChatID = try await actor.startReviewID(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )

        let mainChat = try #require(mainContext.registeredModel(for: reviewChatID))
        #expect(results.items.first === mainChat)
        #expect(results.items.map(\.id.rawValue) == ["thread-review"])
        #expect(mainChat.workspace?.url.path == workspaceURL.path)
        #expect(mainChat.items.map(\.text) == ["current changes"])

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "rollout is empty",
            for: "thread/turns/list"
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "includeTurns is unavailable before first user message",
            for: "thread/read"
        )
        let observation = try await mainChat.observe()
        defer {
            observation.cancel()
        }
        #expect(mainChat.items.map(\.text) == ["current changes"])
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
    }

    @Test("started review chat survives temporary thread list omission")
    func startedReviewChatSurvivesTemporaryThreadListOmission() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-existing",
                workspace: workspaceURL,
                name: "Existing",
                recencyAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
            ))
        try await results.performFetch()

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let reviewChat = started.chat
        let workspace = try #require(reviewChat.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(
                id: "thread-existing",
                workspace: workspaceURL,
                name: "Existing",
                recencyAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))

        try await results.performFetch()

        #expect(results.items.contains { $0 === reviewChat })
        #expect(results.items.map(\.id.rawValue) == ["thread-review", "thread-existing"])
        #expect(workspace.chats.contains { $0 === reviewChat })
        #expect(reviewChat.modelContext === context)
        #expect(context.registeredModel(for: reviewChat.id) === reviewChat)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("started review observation reuses the live event thread without resuming")
    func startedReviewObservationReusesLiveEventThreadWithoutResuming() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "thread/resume should not be needed for a just-started review",
            for: "thread/resume"
        )
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-review",
                status: .running,
                items: [
                    .init(
                        id: "turn-review",
                        kind: .enteredReviewMode,
                        content: .log("Review started")
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-review",
            workspace: workspaceURL,
            name: "Review",
            modelProvider: "openai"
        ))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        #expect(started.chat.items.map(\.text) == ["Review started"])
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/turns/list").count == 1)
        withExtendedLifetime(changes) {}
    }

    @Test("started review consumes its prepared event thread across refresh before observation")
    func startedReviewConsumesPreparedEventThreadAcrossRefreshBeforeObservation() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-review",
            workspace: workspaceURL
        ))
        for text in ["Review started", "Review still running"] {
            try await runtime.transport.enqueueThreadTurns(.init(turns: [
                .init(
                    id: "turn-review",
                    status: .running,
                    items: [
                        .init(
                            id: "turn-review",
                            kind: .enteredReviewMode,
                            content: .log(text)
                        ),
                    ]
                ),
            ]))
            try await runtime.transport.enqueueThreadRead(.init(
                id: "thread-review",
                workspace: workspaceURL,
                name: "Review",
                modelProvider: "openai"
            ))
        }

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        try await context.refresh(started.chat)
        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.items.map(\.text) == ["Review still running"])
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/turns/list").count == 2)
    }

    @Test("started review observation survives empty rollout history reads")
    func startedReviewObservationSurvivesEmptyRolloutHistoryReads() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "thread/resume should not be needed for a just-started review",
            for: "thread/resume"
        )
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "rollout is empty",
            for: "thread/turns/list"
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "includeTurns is unavailable before first user message",
            for: "thread/read"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        #expect(started.chat.items.map(\.text) == ["current changes"])
        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.items.map(\.text) == ["current changes"])
        #expect(started.chat.workspace?.url.path == workspaceURL.path)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/turns/list").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").count == 1)
    }

    @Test("started review observation replays prepared thread events received before observe")
    func startedReviewObservationReplaysPreparedThreadEventsReceivedBeforeObserve() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-review",
                turnID: "turn-review",
                itemID: "message-before-observe",
                delta: "Buffered before observe",
                phase: "final_answer"
            )
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "rollout is empty",
            for: "thread/turns/list"
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "includeTurns is unavailable before first user message",
            for: "thread/read"
        )

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        #expect(await eventually {
            started.chat.items.first { $0.itemID == "message-before-observe" }?.text
                == "Buffered before observe"
        })
        withExtendedLifetime(changes) {}
    }

    @Test("started review observation skips prepared thread history covered by refresh")
    func startedReviewObservationSkipsPreparedThreadHistoryCoveredByRefresh() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-review",
                turnID: "turn-review"
            )
        )
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-review",
                status: .completed,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "final-message",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "final-message",
                            role: .assistant,
                            phase: .finalAnswer,
                            text: "Done"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-review",
            workspace: workspaceURL,
            status: .idle
        ))

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try? await Task.sleep(for: .milliseconds(100))

        #expect(started.chat.turn(id: "turn-review")?.status == .completed)
        #expect(started.chat.phase == .loaded)
        #expect(started.chat.items.map(\.itemID) == ["final-message"])
        withExtendedLifetime(changes) {}
    }

    @Test("started review live turn replaces provisional seed after empty history read")
    func startedReviewLiveTurnReplacesProvisionalSeedAfterEmptyHistoryRead() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "rollout is empty",
            for: "thread/turns/list"
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "includeTurns is unavailable before first user message",
            for: "thread/read"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        #expect(started.chat.turns.map(\.id.rawValue) == ["turn-seed"])
        #expect(started.chat.items.map(\.text) == ["current changes"])

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-review",
                turnID: "turn-live"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-live",
                item: .init(
                    id: "review-mode",
                    type: "enteredReviewMode",
                    text: "current changes"
                )
            )
        )

        #expect(await eventually {
            started.chat.turns.map(\.id.rawValue) == ["turn-live"]
                && started.chat.items.map(\.itemID) == ["review-mode"]
                && started.chat.items.map(\.text) == ["current changes"]
        })
        withExtendedLifetime(changes) {}
    }

    @Test("started review snapshot merge replaces provisional seed with authoritative review turn")
    func startedReviewSnapshotMergeReplacesProvisionalSeedWithAuthoritativeReviewTurn() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        #expect(started.chat.turns.map(\.id.rawValue) == ["turn-seed"])
        #expect(started.chat.items.map(\.text) == ["current changes"])

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "turn-live",
                        status: .running,
                        items: [
                            .init(
                                id: "review-mode",
                                kind: .enteredReviewMode,
                                content: .log("current changes")
                            ),
                            .init(
                                id: "command-1",
                                kind: .commandExecution,
                                content: .command(.init(
                                    command: "/bin/zsh -lc",
                                    status: .running
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        #expect(started.chat.turns.map(\.id.rawValue) == ["turn-live"])
        #expect(started.chat.items.map(\.itemID) == ["review-mode", "command-1"])
        #expect(started.chat.items.map(\.text) == ["current changes", "/bin/zsh -lc"])
    }

    @Test("started review observation replaces response seed with authoritative turn list when available")
    func startedReviewObservationReplacesResponseSeedWithAuthoritativeTurnListWhenAvailable() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-review",
                status: .running,
                items: [
                    .init(
                        id: "turn-review",
                        kind: .enteredReviewMode,
                        content: .log("Review started from live turn list")
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-review", workspace: workspaceURL))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.items.map(\.text) == ["Review started from live turn list"])
    }

    @Test("started review observation drops not-loaded response seed when full turn items arrive")
    func startedReviewObservationDropsNotLoadedSeedWhenFullTurnItemsArrive() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            .init(
                id: "turn-review",
                status: .running,
                itemsLoadState: .notLoaded,
                items: [
                    .init(
                        id: "seed-review",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-review",
                status: .running,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "review-mode",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                    .init(
                        id: "command-1",
                        kind: .commandExecution,
                        content: .command(.init(
                            command: "/bin/zsh -lc",
                            status: .running
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-review", workspace: workspaceURL))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        #expect(started.chat.items.map(\.itemID) == ["seed-review"])

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.items.map(\.itemID) == ["review-mode", "command-1"])
        #expect(started.chat.items.map(\.text) == ["current changes", "/bin/zsh -lc"])
    }

    @Test("started review refresh coalesces review marker raw ID changes")
    func startedReviewRefreshCoalescesReviewMarkerRawIDChanges() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            .init(
                id: "turn-review",
                status: .running,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "turn-review",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-review",
                status: .running,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "review-mode",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-review", workspace: workspaceURL))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let seededItem = try #require(started.chat.items.first)
        #expect(seededItem.itemID == "turn-review")
        #expect(seededItem.id.rawValue == "turn-review:review-marker:enteredReviewMode")

        try await context.refresh(started.chat)

        let reviewMarkers = started.chat.items.filter { $0.kind == .enteredReviewMode }
        let refreshedItem = try #require(reviewMarkers.first)
        #expect(reviewMarkers.count == 1)
        #expect(refreshedItem === seededItem)
        #expect(refreshedItem.itemID == "review-mode")
        #expect(refreshedItem.id.rawValue == "turn-review:review-marker:enteredReviewMode")
    }

    @Test("started review refresh coalesces running command snapshot replay")
    func startedReviewRefreshCoalescesRunningCommandSnapshotReplay() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let startedAt = Date(timeIntervalSince1970: 10)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        started.chat.apply(.itemStarted(
            .init(
                id: "live-command",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/bin/zsh -lc 'git status --short'",
                    cwd: workspaceURL.path,
                    status: .running,
                    startedAt: startedAt,
                    processID: "123",
                    source: .agent
                ))
            ),
            turnID: "turn-review"
        ))
        let seededCommand = try #require(
            started.chat.items.first { $0.kind == .commandExecution }
        )

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "turn-review",
                        status: .running,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "snapshot-command",
                                kind: .commandExecution,
                                content: .command(.init(
                                    command: "/bin/zsh -lc 'git status --short'",
                                    status: .running
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        let commandItems = started.chat.items.filter { $0.kind == .commandExecution }
        let commandItem = try #require(commandItems.first)
        let command: CodexCommand
        switch commandItem.content {
        case .command(let value):
            command = value
        default:
            Issue.record("Expected a command item.")
            return
        }
        #expect(commandItems.count == 1)
        #expect(commandItem === seededCommand)
        #expect(commandItem.itemID == "snapshot-command")
        #expect(command.cwd == workspaceURL.path)
        #expect(command.startedAt == startedAt)
        #expect(command.processID == "123")
        #expect(command.source == .agent)
    }

    @Test("started review refresh moves running command replay into authoritative turn")
    func startedReviewRefreshMovesRunningCommandReplayIntoAuthoritativeTurn() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let startedAt = Date(timeIntervalSince1970: 10)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        _ = started.chat.apply(.turnStarted("turn-seed"))
        _ = started.chat.apply(.itemStarted(
            .init(
                id: "call-live",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/bin/zsh -lc 'git status --short'",
                    cwd: workspaceURL.path,
                    status: .running,
                    startedAt: startedAt,
                    processID: "123",
                    source: .agent
                ))
            ),
            turnID: "turn-seed"
        ))
        _ = started.chat.apply(.turnStarted("turn-live"))
        let liveCommand = try #require(
            started.chat.items.first { $0.kind == .commandExecution }
        )
        #expect(liveCommand.turnID?.rawValue == "turn-seed")

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "turn-live",
                        status: .running,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "call-live",
                                kind: .commandExecution,
                                content: .command(.init(
                                    command: "/bin/zsh -lc 'git status --short'",
                                    cwd: workspaceURL.path,
                                    status: .running,
                                    processID: "123",
                                    source: .agent
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        let commandItems = started.chat.items.filter { $0.kind == .commandExecution }
        let commandItem = try #require(commandItems.first)
        let command: CodexCommand
        switch commandItem.content {
        case .command(let value):
            command = value
        default:
            Issue.record("Expected a command item.")
            return
        }
        #expect(commandItems.count == 1)
        #expect(commandItem !== liveCommand)
        #expect(liveCommand.modelContext == nil)
        #expect(liveCommand.turnID == nil)
        #expect(commandItem.turnID?.rawValue == "turn-live")
        #expect(commandItem.id.rawValue == "turn-live:call-live")
        #expect(started.chat.items(in: "turn-seed").contains { $0.kind == .commandExecution } == false)
        #expect(started.chat.items(in: "turn-live").filter { $0.kind == .commandExecution }.count == 1)
        #expect(command.startedAt == startedAt)
        #expect(command.processID == "123")
        #expect(command.source == .agent)
    }

    @Test("started review preserves seeded row metadata across null metadata refresh")
    func startedReviewPreservesSeededRowMetadataAcrossNullMetadataRefresh() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadTurns(.init(turns: [
            .init(
                id: "turn-review",
                status: .running,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "review-mode",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueJSON(
            """
            {
              "thread": {
                "id": "thread-review",
                "cwd": "\(workspaceURL.path)",
                "name": null,
                "preview": null,
                "modelProvider": null
              }
            }
            """,
            for: "thread/read"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(modelProvider: "openai", ephemeral: false)
            )
        )
        let expectedPreview = "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings."
        #expect(started.chat.preview == expectedPreview)
        #expect(started.chat.modelProvider == "openai")

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.preview == expectedPreview)
        #expect(started.chat.title == expectedPreview)
        #expect(started.chat.modelProvider == "openai")
    }

    @Test("workspace start chat exposes known ephemeral option")
    func workspaceStartChatExposesKnownEphemeralOption() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(
            .init(threads: [
                .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
            ]))
        let workspaceResults = context.fetchedResults(
            for: CodexFetchRequest<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-ephemeral")
        let chat = try await workspace.startChat(.init(options: .init(ephemeral: true)))

        #expect(chat.ephemeral == true)
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func createDirectory(_ name: String, in parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func gitRepository() throws -> URL {
    let repo = temporaryDirectory()
    try createGitMetadata(in: repo)
    return repo
}

private func gitRepository(named name: String) throws -> URL {
    let repo = temporaryDirectory().appendingPathComponent(name, isDirectory: true)
    try createGitMetadata(in: repo)
    return repo
}

private func createGitMetadata(in repo: URL) throws {
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
}

private struct ThreadListParams: Decodable, Sendable {
    var archived: Bool?
    var cursor: String?
    var cwd: CWDFilter?
    var limit: Int?
    var modelProviders: [String]?
    var searchTerm: String?
    var sortDirection: String?
    var sortKey: String?
    var sourceKinds: [String]?
    var useStateDbOnly: Bool?
}

private enum CWDFilter: Decodable, Equatable, Sendable {
    case path(String)
    case paths([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let path = try? container.decode(String.self) {
            self = .path(path)
        } else {
            self = .paths(try container.decode([String].self))
        }
    }
}

private struct ThreadReadParams: Decodable, Sendable {
    var threadID: String
    var includeTurns: Bool?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case includeTurns
    }
}

private struct ThreadTurnsListParams: Decodable, Sendable {
    var threadID: String
    var cursor: String?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case cursor
    }
}

private struct ThreadStartParams: Decodable, Sendable {
    var cwd: String?
    var model: String?
    var modelProvider: String?
    var ephemeral: Bool?
}

private struct ThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var startedAtMs: Int64? = nil
    var completedAtMs: Int64? = nil
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case startedAtMs
        case completedAtMs
        case item
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String? = nil
        var phase: String? = nil
        var command: String? = nil
        var cwd: String? = nil
        var path: String? = nil
        var output: String? = nil
        var exitCode: Int? = nil
        var status: String? = nil
        var durationMs: Int? = nil
    }
}

private struct TurnStartedParams: Encodable, Sendable {
    var threadID: String
    var turnID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
    }
}

private struct TurnDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String?
    var delta: String
    var phase: String?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case phase
    }
}

private struct ThreadScopedDeltaParams: Encodable, Sendable {
    var threadID: String
    var itemID: String?
    var delta: String
    var phase: String?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case itemID = "itemId"
        case delta
        case phase
    }
}

private struct TurnOnlyDeltaParams: Encodable, Sendable {
    var turnID: String
    var itemID: String?
    var delta: String
    var phase: String?

    enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case phase
    }
}

private struct OutputDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

private struct FileChangePatchUpdatedParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var changes: Changes

    init(threadID: String, turnID: String, itemID: String, displayText: String) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.changes = .init(displayText: displayText)
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case changes
    }

    struct Changes: Encodable, Sendable {
        var displayText: String
    }
}

private struct ThreadStatusParams: Encodable, Sendable {
    var threadID: String
    var status: Status

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case status
    }

    struct Status: Encodable, Sendable {
        var type: String
    }
}

private struct ThreadClosedParams: Encodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct TurnCompletedParams: Encodable, Sendable {
    var turn: Turn

    struct Turn: Encodable, Sendable {
        var id: String
        var status: String?
        var completedAt: Int?
    }
}

private struct TokenUsageParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var tokenUsage: TokenUsage

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case tokenUsage
    }

    struct TokenUsage: Encodable, Sendable {
        var total: Breakdown
        var modelContextWindow: Int?
    }

    struct Breakdown: Encodable, Sendable {
        var cachedInputTokens: Int = 0
        var inputTokens: Int
        var outputTokens: Int
        var reasoningOutputTokens: Int = 0
        var totalTokens: Int
    }
}

@MainActor
private func eventually(
    attempts: Int = 50,
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
private func threadItems(from items: [CodexItem]) -> [CodexThreadItem] {
    items.map {
        CodexThreadItem(
            id: $0.itemID,
            kind: $0.kind,
            content: $0.content,
            rawPayload: $0.rawPayload
        )
    }
}

@MainActor
private final class FetchedResultsTransactionRecorder<Model: CodexPersistentModel> {
    private(set) var transactions: [CodexFetchedResultsTransaction<Model>] = []
    private var task: Task<Void, Never>?

    init(stream: AsyncStream<CodexFetchedResultsTransaction<Model>>) {
        task = Task { @MainActor [weak self] in
            for await transaction in stream {
                self?.transactions.append(transaction)
            }
        }
    }

    deinit {
        task?.cancel()
    }

    func count(after delay: Duration) async -> Int {
        try? await Task.sleep(for: delay)
        return transactions.count
    }
}

@MainActor
private final class ChatUpdateRecorder {
    private var changes: [CodexChatUpdate] = []
    private var streamFinished = false
    private var task: Task<Void, Never>?

    init(stream: CodexChatUpdates) {
        task = Task { @MainActor [weak self] in
            for await change in stream {
                self?.append(change)
            }
            self?.markFinished()
        }
    }

    deinit {
        task?.cancel()
    }

    func next() async -> CodexChatUpdate? {
        await next { _ in true }
    }

    func itemInserted(id: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemInserted(let changeID, _) = change {
                return changeID == id
            }
            return false
        }
    }

    func itemUpdated(id: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemUpdated(let changeID, _) = change {
                return changeID == id
            }
            return false
        }
    }

    func itemTextAppended(id: String, delta: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemTextAppended(let changeID, _, let changeDelta) = change {
                return changeID == id && changeDelta == delta
            }
            return false
        }
    }

    func phaseChanged(_ phase: CodexDataPhase) async -> CodexChatUpdate? {
        await next { change in
            if case .phaseChanged(let candidate) = change {
                return candidate == phase
            }
            return false
        }
    }

    func statusChanged(_ status: CodexThreadStatus?) async -> CodexChatUpdate? {
        await next { change in
            if case .statusChanged(let candidate) = change {
                return candidate == status
            }
            return false
        }
    }

    func resynchronized(reason: CodexChatResynchronizationReason) async -> CodexChatUpdate? {
        await next { change in
            if case .resynchronized(let candidate) = change {
                return candidate == reason
            }
            return false
        }
    }

    var isFinished: Bool {
        streamFinished
    }

    private func append(_ change: CodexChatUpdate) {
        changes.append(change)
    }

    private func markFinished() {
        streamFinished = true
    }

    private func popFirst(
        matching predicate: (CodexChatUpdate) -> Bool
    ) -> CodexChatUpdate? {
        guard let index = changes.firstIndex(where: predicate) else {
            return nil
        }
        return changes.remove(at: index)
    }

    private func next(
        matching predicate: (CodexChatUpdate) -> Bool
    ) async -> CodexChatUpdate? {
        for _ in 0..<50 {
            if let change = popFirst(matching: predicate) {
                return change
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return popFirst(matching: predicate)
    }
}
