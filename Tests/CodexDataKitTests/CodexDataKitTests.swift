import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Foundation
import Testing

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

        do {
            try await workspace.refresh()
            Issue.record("Expected detached workspace refresh to throw")
        } catch let error as CodexModelContextError {
            #expect(error == .modelIsDetached)
        } catch {
            Issue.record("Expected modelIsDetached for workspace refresh, got \(error)")
        }

        do {
            try await group.refresh()
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

    @Test("fetch requests are translated to app-server thread/list query params")
    func fetchRequestTranslatesToThreadListParams() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let request = CodexFetchRequest<CodexChat>(
            filter: .init(
                archived: true,
                workspace: workspace,
                searchTerm: "needle",
                modelProviders: ["gpt-5"],
                sourceKinds: [.appServer, .subAgent],
                useStateDBOnly: true
            ),
            sortDescriptors: [.recencyAt(.reverse)],
            fetchLimit: 25,
            cursor: "cursor-1"
        )

        _ = try await context.fetch(request)

        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == true)
        #expect(params.cursor == "cursor-1")
        #expect(params.cwd == .paths([workspace.path]))
        #expect(params.limit == 25)
        #expect(params.searchTerm == "needle")
        #expect(params.modelProviders == ["gpt-5"])
        #expect(params.sortDirection == "desc")
        #expect(params.sortKey == "recency_at")
        #expect(params.sourceKinds == ["appServer", "subAgent"])
        #expect(params.useStateDbOnly == true)
    }

    @Test("fetched results preserve configured cursor on initial fetch")
    func fetchedResultsPreserveConfiguredCursorOnInitialFetch() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let request = CodexFetchRequest<CodexChat>(
            sortDescriptors: [.updatedAt(.reverse)],
            cursor: "cursor-1"
        )
        let results = context.fetchedResults(for: request)
        try await results.performFetch()

        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.cursor == "cursor-1")
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
            sortDescriptors: [.name()],
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
            sortDescriptors: [.name()],
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
            sortDescriptors: [.name()],
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
            sortDescriptors: [.name()],
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
            sortDescriptors: [.name()]
        ))
        let fetchedWorkspace = try #require(allChats.first?.workspace)
        let staleChat = context.model(for: CodexThreadID(rawValue: "thread-zulu"))
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspace, name: "Beta"),
        ]))
        let firstPage = try await context.fetch(CodexFetchRequest<CodexChat>(
            sortDescriptors: [.name()],
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
            sortDescriptors: [.name()]
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
            sortDescriptors: [.name()],
            sectionDescriptor: .workspace
        ))
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
            sortDescriptors: [.name()]
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
        let allResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
        try await allResults.performFetch()
        let fetchedWorkspace = try #require(allResults.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-match", workspace: workspace, name: "Match")
        ]))
        let filteredResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            filter: .init(searchTerm: "Match")
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
            filter: .init(searchTerm: "")
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
            filter: .init(sourceKinds: [])
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
            filter: .init(searchTerm: "Match")
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
            filter: .init(archived: false),
            sortDescriptors: [.updatedAt(.reverse)]
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
        try await chat.refresh(includeTurns: false)

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
        try await chat.refresh(includeTurns: false)

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
            sortDescriptors: [.name()],
            sectionDescriptor: .workspace
        ))
        try await sectionedResults.performFetch()
        let oldWorkspaceSectionID = oldWorkspaceURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        #expect(sectionedResults.sections.first?.id == oldWorkspaceSectionID)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-move", workspace: newWorkspaceURL, name: "Move")
        ]))
        let fetchedChats = try await context.fetch(CodexFetchRequest<CodexChat>.recentChats)
        let newWorkspaceSectionID = newWorkspaceURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path

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
            sortDescriptors: [.name()]
        ))
        try await nameResults.performFetch()

        try await runtime.transport.enqueueThreadList(initialPage)
        let updatedResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [.updatedAt(.reverse)]
        ))
        try await updatedResults.performFetch()

        try await runtime.transport.enqueueThreadList(initialPage)
        let sectionedNameResults = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [.name()],
            sectionDescriptor: .workspace
        ))
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
            filter: .init(archived: true),
            sortDescriptors: [.updatedAt(.reverse)]
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
        try await chat.refresh(includeTurns: false)

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
            filter: .init(archived: true),
            sortDescriptors: [.updatedAt(.reverse)]
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
            filter: .init(sourceKinds: [.appServer])
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
        try await chat.refresh(includeTurns: false)

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
            filter: .init(sourceKinds: [.appServer]),
            sectionDescriptor: .workspace
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(
            results.sections.first?.id == oldWorkspaceURL.standardizedFileURL
                .resolvingSymlinksInPath().path
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
        try await chat.refresh(includeTurns: false)

        #expect(results.items.first === chat)
        #expect(
            results.sections.first?.id == newWorkspaceURL.standardizedFileURL
                .resolvingSymlinksInPath().path
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
            for: CodexFetchRequest<CodexChat>(sortDescriptors: [.recencyAt(.reverse)])
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
            for: CodexFetchRequest<CodexChat>(sortDescriptors: [.recencyAt(.reverse), .name()])
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
            sortDescriptors: [.recencyAt(.reverse), .name()],
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
        try await alpha.refresh(includeTurns: false)

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
            for: CodexFetchRequest<CodexChat>(sortDescriptors: [.name(), .recencyAt(.reverse)])
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
            for: CodexFetchRequest<CodexChat>(sortDescriptors: [.updatedAt(.reverse)])
        )
        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == ["thread-dated", "thread-undated"])
    }

    @Test("workspace and chat fetches can be sectioned by workspace group or workspace")
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

        let workspaceResults = context.fetchedResults(
            for: CodexFetchRequest<CodexWorkspace>.workspaces(
                sectionedBy: .workspaceGroup
            ))
        try await workspaceResults.performFetch()

        let workspaceSection = try #require(workspaceResults.sections.first)
        #expect(workspaceResults.items.map(\.name).sorted() == ["App", "Tools"])
        #expect(workspaceResults.sections.count == 1)
        #expect(workspaceSection.title == repo.lastPathComponent)
        #expect(workspaceSection.items.map(\.name).sorted() == ["App", "Tools"])

        try await runtime.transport.enqueueThreadList(page)

        let chatResults = context.fetchedResults(
            for: CodexFetchRequest<CodexChat>(
                sortDescriptors: [.name()],
                sectionDescriptor: .workspace
            ))
        try await chatResults.performFetch()

        #expect(chatResults.sections.compactMap(\.title).sorted() == ["App", "Tools"])
        #expect(
            chatResults.items.map(\.workspace?.workspaceGroup?.id).allSatisfy {
                $0 == workspaceResults.items.first?.workspaceGroup?.id
            })
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
            sortDescriptors: [.name()],
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
            sortDescriptors: [.name()],
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
        try await previousGroup.refresh()

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
        try await previousGroup.refresh()

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
            sortDescriptors: [.name()],
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
            sortDescriptors: [.name()],
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
        try await chat.refresh(includeTurns: false)

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
            sortDescriptors: [.name()],
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
        try await chat.refresh(includeTurns: false)

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
            sortDescriptors: [.name()],
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
        try await chat.refresh(includeTurns: false)

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
            sortDescriptors: [.name()],
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
            filter: .init(archived: true)
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

    @Test("cursor-started chat fetches never mark workspace relationships complete")
    func cursorStartedChatFetchesNeverMarkWorkspaceRelationshipsComplete() async throws {
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
            sortDescriptors: [.updatedAt(.reverse)],
            cursor: "cursor"
        ))
        try await cursorResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-after", workspace: workspace, name: "After")
        ]))
        try await cursorResults.loadNextPage()

        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == [
            "thread-before",
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
        try await group.refresh()

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
        try await group.refresh()

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
        try await group.refresh()

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
        try await appGroup.refresh()

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
            filter: .init(archived: true)
        ))
        try await archivedResults.performFetch()
        let group = try #require(archivedResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-active", workspace: app, name: "Active")
        ]))
        try await group.refresh()

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
            filter: .init(archived: true)
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
            filter: .init(workspace: app)
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
        try await workspace.refresh()

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
        try await workspace.refresh()

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
        try await workspace.refresh()

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
        try await workspace.refresh()

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
        try await group.refresh()

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
            filter: .init(archived: true)
        ))
        try await archivedResults.performFetch()
        let workspace = try #require(archivedResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-active", workspace: workspaceURL, name: "Active")
        ]))
        try await workspace.refresh()

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
            filter: .init(searchTerm: "Match")
        ))
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-match", workspace: workspaceURL, name: "Renamed")
        ]))
        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await workspace.refresh()

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
            filter: .init(searchTerm: "needle")
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
        try await workspace.refresh()

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
            filter: .init(sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let workspace = try #require(chat.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        await runtime.transport.enqueueFailure(code: -32000, message: "offline", for: "thread/list")
        try await workspace.refresh()

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
        try await workspace.refresh()

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
            sortDescriptors: [.updatedAt(.reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-backfill", workspace: backfillURL, name: "Backfill")
        ]))
        try await workspace.refresh()

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
            sortDescriptors: [.updatedAt(.reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let group = try #require(results.items.first?.workspace?.workspaceGroup)

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-backfill", workspace: backfillURL, name: "Backfill")
        ]))
        try await group.refresh()

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
            filter: .init(searchTerm: "Match")
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
        try await chat.refresh(includeTurns: false)

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
            filter: .init(sourceKinds: [.appServer])
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
            filter: .init(sourceKinds: [.appServer])
        ))
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let groupResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>(
            filter: .init(sourceKinds: [.appServer])
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
            sortDescriptors: [.updatedAt(.reverse)],
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
            sortDescriptors: [.updatedAt(.reverse)],
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
            sortDescriptors: [.name()],
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
            sortDescriptors: [.name()],
            fetchLimit: 2
        ))
        try await firstPage.performFetch()
        let cursor = try #require(firstPage.nextCursor)

        try await runtime.transport.enqueueThreadList(.init(threads: threads))
        let offsetPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [.name()],
            fetchLimit: 1,
            cursor: cursor
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
            sortDescriptors: [.name()],
            fetchLimit: 2
        ))
        try await firstPage.performFetch()
        let cursor = try #require(firstPage.nextCursor)

        try await runtime.transport.enqueueThreadList(.init(threads: initialThreads))
        let offsetPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [.name()],
            fetchLimit: 2,
            cursor: cursor
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
            sortDescriptors: [.name()],
            fetchLimit: 2
        ))
        try await firstPage?.performFetch()
        let cursor = try #require(firstPage?.nextCursor)
        let deletedChat = context.model(for: CodexThreadID(rawValue: "thread-a"))
        firstPage = nil

        try await runtime.transport.enqueueThreadList(.init(threads: initialThreads))
        let offsetPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [.name()],
            fetchLimit: 2,
            cursor: cursor
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
            sortDescriptors: [.name()],
            fetchLimit: 1
        ))
        try await firstPage.performFetch()
        let cursor = try #require(firstPage.nextCursor)

        try await runtime.transport.enqueueThreadList(.init(threads: initialThreads))
        let offsetPage = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            sortDescriptors: [.name()],
            fetchLimit: 2,
            cursor: cursor
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
        try await movingChat.refresh(includeTurns: false)

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
            filter: .init(modelProviders: ["openai"])
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
            filter: .init(modelProviders: ["openai"])
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
            filter: .init(sourceKinds: [.appServer])
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
            filter: .init(modelProviders: [])
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
        try await chat.refresh(includeTurns: false)

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
            sortDescriptors: [.updatedAt(.reverse)],
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
            sortDescriptors: [.updatedAt(.reverse)],
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
            sortDescriptors: [.updatedAt(.reverse)],
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
            sortDescriptors: [.name()],
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
        try await beta.refresh(includeTurns: false)

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
            sortDescriptors: [.updatedAt(.reverse)],
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
            filter: .init(archived: true),
            sortDescriptors: [.updatedAt(.reverse)]
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
            filter: .init(sourceKinds: [.appServer])
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
            filter: .init(archived: true),
            sortDescriptors: [.updatedAt(.reverse)]
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
            filter: .init(archived: true, sourceKinds: [.appServer])
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
            filter: .init(archived: true)
        ))
        try await archivedWorkspaceResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(threads: []))
        let archivedGroupResults = context.fetchedResults(for: CodexFetchRequest<CodexWorkspaceGroup>(
            filter: .init(archived: true)
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
            filter: .init(archived: true),
            sortDescriptors: [.updatedAt(.reverse)]
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
            filter: .init(archived: true, sourceKinds: [.appServer])
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

        try await chat.refresh(includeTurns: false)

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

    @Test("server-only chat refresh re-sorts current results")
    func serverOnlyChatRefreshResortsCurrentResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-beta", name: "Beta"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))
        let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
            filter: .init(sourceKinds: [.appServer]),
            sortDescriptors: [.name()]
        ))
        try await results.performFetch()
        let beta = try #require(results.items.first { $0.id.rawValue == "thread-beta" })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-beta"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-beta", name: "Aardvark"))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-beta", name: "Aardvark"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))
        try await beta.refresh(includeTurns: false)

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
            filter: .init(workspace: app, sourceKinds: [.appServer])
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
        try await chat.refresh(includeTurns: false)

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
            filter: .init(searchTerm: "needle")
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-search"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-search", name: "Untitled"))
        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-search", name: "Untitled")
        ]))
        try await chat.refresh(includeTurns: false)

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
            filter: .init(searchTerm: "needle")
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
            sortDescriptors: [.name()],
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
        try await alpha.refresh(includeTurns: false)

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
                turns: [.init(id: "turn-summary", status: .completed)]
            )
        ]))
        try await results.refresh()

        #expect(chat.title == "After")
        #expect(chat.turns.first === turn)
        #expect(turn.status == CodexTurnStatus.completed)
        #expect(chat.turns.contains { $0.id == "turn-omitted" })
        #expect(chat.items.first === item)
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
        try await chat.refresh()

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
        try await chat.refresh()

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
        try await chat.refresh()

        let item = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(item.id == "message-history")
        #expect(item.turnID == "turn-history")
        #expect(item.text == "Done")
        #expect(chat.transcript.finalAnswer == "Done")
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
        try await chat.refresh()

        let alphaTurn = try #require(chat.turn(id: "turn-alpha"))
        let alphaItem = try #require(chat.items.first { $0.id == "message-alpha-user" })
        let alphaItems = chat.items(in: "turn-alpha")
        let betaItems = chat.items(in: "turn-beta")
        let snapshot = try #require(chat.turnSnapshot(for: "turn-alpha"))

        #expect(alphaItems.map(\.id) == ["message-alpha-user", "message-alpha-agent"])
        #expect(betaItems.map(\.id) == ["message-beta"])
        #expect(alphaItems.first === alphaItem)
        #expect(snapshot.turn === alphaTurn)
        #expect(snapshot.items.first === alphaItem)
        #expect(snapshot.items.map(\.id) == alphaItems.map(\.id))
        #expect(snapshot.threadItems.map(\.id) == ["message-alpha-user", "message-alpha-agent"])
        #expect(snapshot.transcript.finalAnswer == "Alpha answer")
        #expect(snapshot.status == CodexTurnStatus.completed)
        #expect(snapshot.errorDescription == nil)
        #expect(snapshot.usage == nil)
    }

    @Test("chat turn snapshots expose metadata and missing turn results")
    func chatTurnSnapshotsExposeMetadataAndMissingTurnResults() async throws {
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

        let failedSnapshot = try #require(chat.turnSnapshot(for: "turn-failed"))
        #expect(failedSnapshot.status == CodexTurnStatus.failed)
        #expect(failedSnapshot.errorDescription == "Tool failed")
        #expect(failedSnapshot.usage == nil)
        #expect(chat.turn(id: "turn-missing") == nil)
        #expect(chat.items(in: "turn-missing").isEmpty)
        #expect(chat.turnSnapshot(for: "turn-missing") == nil)

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
            chat.turnSnapshot(for: "turn-completed")?.usage?.totalTokens == 34
        })
        let completedTurn = try #require(chat.turn(id: "turn-completed"))
        let completedSnapshot = try #require(chat.turnSnapshot(for: "turn-completed"))
        #expect(completedSnapshot.turn === completedTurn)
        #expect(completedSnapshot.usage?.inputTokens == 13)
        #expect(completedSnapshot.usage?.outputTokens == 21)
        #expect(completedSnapshot.usage?.modelContextWindow == 128_000)
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
            chat.items.contains { $0.id == "message-live" && $0.text == "Hel" }
        })
        let liveItem = try #require(chat.items.first { $0.id == "message-live" })

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
        #expect(chat.items.first { $0.id == "message-live" } === liveItem)
        #expect(liveTurn.usage?.totalTokens == 12)
        #expect(liveTurn.usage?.modelContextWindow == 200_000)
        #expect(chat.updatedAt == completedAt)
        #expect(chat.transcript.finalAnswer == "Hello")
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)

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
            chat.items.first { $0.id == "message-live" }?.text == "Hello"
        })
        #expect(chat.items.filter { $0.id == "message-live" }.count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 2)
    }

    @Test("review identity observation resolves the active review thread chat")
    func reviewIdentityObservationResolvesActiveReviewThreadChat() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-review"))

        let observation = try await context.observe(identity)
        defer {
            observation.cancel()
        }

        #expect(observation.chat.id == "thread-review")
        #expect(context.model(for: identity) === observation.chat)

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    id: "review-message",
                    type: "agentMessage",
                    text: "Review complete",
                    phase: "final_answer"
                )
            )
        )

        #expect(await eventually {
            observation.chat.items.contains {
                $0.id == "review-message" && $0.text == "Review complete"
            }
        })
    }

    @Test("review identity observation seeds turn-only review notifications")
    func reviewIdentityObservationSeedsTurnOnlyReviewNotifications() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-review"))

        let observation = try await context.observe(identity)
        defer {
            observation.cancel()
        }

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnOnlyDeltaParams(
                turnID: "turn-review",
                itemID: "review-message",
                delta: "Turn-only review",
                phase: "final_answer"
            )
        )

        #expect(await eventually {
            observation.chat.items.contains {
                $0.id == "review-message" && $0.text == "Turn-only review"
            }
        })
    }

    @Test("duplicate chat observations share one live consumer")
    func duplicateChatObservationsShareOneLiveConsumer() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-duplicate"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-duplicate"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-duplicate"))
        let firstObservation = try await chat.observe()
        let secondObservation = try await chat.observe()
        defer {
            firstObservation.cancel()
            secondObservation.cancel()
        }

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-duplicate",
                turnID: "turn-duplicate",
                itemID: "message-duplicate",
                delta: "Hel",
                phase: "final_answer"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-duplicate",
                turnID: "turn-duplicate",
                itemID: "message-duplicate",
                delta: "lo",
                phase: "final_answer"
            )
        )

        #expect(await eventually {
            chat.items.first { $0.id == "message-duplicate" }?.text == "Hello"
        })
        #expect(chat.items.filter { $0.id == "message-duplicate" }.count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    @Test("chat observation preserves loading phase for running snapshots")
    func chatObservationPreservesLoadingPhaseForRunningSnapshots() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-running"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-running",
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
            chat.items.first { $0.id == "command-output" }?.text == "Hello"
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
            chat.items.first { $0.id == "command-output" }?.text == "Completed output"
        })
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
            sortDescriptors: [.recencyAt(.reverse)]
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
            sortDescriptors: [.updatedAt(.reverse)],
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

private struct ThreadStartParams: Decodable, Sendable {
    var cwd: String?
    var model: String?
}

private struct ThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String?
        var phase: String?
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
