import CodexAppServerKit
import CodexAppServerKitTesting
import CodexUIKit
import Foundation
import Testing

@MainActor
struct CodexModelContextTests {
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
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha"])
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
