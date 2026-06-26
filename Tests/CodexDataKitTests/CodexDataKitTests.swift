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

        try await runtime.transport.enqueueThreadList(.init(threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
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
        let chat = try await workspace.startChat(.init(
            options: .init(modelProvider: "openai")
        ))

        #expect(chat.modelProvider == "openai")
        #expect(providerResults.items.first === chat)
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
        try await chat.refresh(includeTurns: false)

        #expect(results.items.first === chat)
        #expect(chat.title == "After")
    }

    @Test("starting a chat does not overfill paged fetched results")
    func startingChatDoesNotOverfillPagedFetchedResults() async throws {
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
        #expect(pagedResults.items.first?.id.rawValue == "thread-existing")
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

    @Test("metadata-only chat refresh preserves existing turn objects")
    func metadataOnlyRefreshPreservesTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(
            .init(threads: [
                .init(
                    id: "thread-refresh",
                    name: "Before",
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
        try await beta.refresh(includeTurns: false)

        #expect(results.items.map(\.title) == ["Aardvark", "Alpha"])
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
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
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

private struct TurnCompletedParams: Encodable, Sendable {
    var turn: Turn

    struct Turn: Encodable, Sendable {
        var id: String
        var status: String?
    }
}
