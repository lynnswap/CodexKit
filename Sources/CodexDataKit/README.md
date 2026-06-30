# CodexDataKit

CodexDataKit provides SwiftData-style `@Observable` app-server backed models on top of `CodexAppServerKit`.

Use this package when app or UI code needs workspace group, workspace, and chat models without rendering directly from JSON-RPC payloads.

## Main Types

- `CodexModelContainer`: Owns the `CodexAppServer` and vends the main `CodexModelContext`.
- `CodexModelContext`: Fetches models, preserves model identity, and performs app-server actions for attached models.
- `CodexFetchDescriptor`: SwiftData-style value description of predicate, sort order, limit, and offset.
- `CodexFetchRequest`: CoreData-style mutable request object for predicate, sort descriptors, limit, and offset.
- `CodexFetchedResults`: Observable CoreData-style fetch results with items, optional sections, cursors, loading phase, and errors.
- `CodexFetchedResultsController`: Non-UI fetched-results controller that keeps `CodexFetchedResults` as the current-value owner and exposes ordered snapshot transactions.
- `CodexFetchedResultsSnapshot`, `CodexFetchedResultsTransaction`: Section and item ID snapshots plus section/item changes suitable for conversion to native UI update APIs.
- `CodexWorkspaceGroup`, `CodexWorkspace`, `CodexChat`: Observable model objects attached to a model context.
- `CodexQuery`: A SwiftUI `DynamicProperty` wrapper around `CodexFetchedResults`.
- `CodexDataPhase`: A small data-loading state enum with `idle`, `loading`, `loaded`, and `failed`.

## Quick Start

```swift
import CodexDataKit

let container = try await CodexModelContainer()
let context = container.mainContext

let chats = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
try await chats.performFetch()

for chat in chats.items {
    print(chat.title)
}
```

## Fetching

Use `CodexFetchDescriptor` when you want SwiftData-style value configuration:

```swift
let descriptor = CodexFetchDescriptor<CodexChat>(
    predicate: .init(
        archived: false,
        workspace: workspaceURL,
        searchTerm: "review"
    ),
    sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
    fetchLimit: 50
)

let results = context.fetchedResults(
    for: descriptor,
    sectionedBy: .workspaceGroup
)
try await results.performFetch()
```

Use `CodexFetchRequest` when request construction reads better as a mutable CoreData-like object:

```swift
let request = CodexFetchRequest<CodexChat>()
request.predicate = .init(workspace: workspaceURL)
request.sortDescriptors = [CodexSortDescriptor(\.updatedAt, order: .reverse)]
request.fetchLimit = 100

let results = context.fetchedResults(for: request)
try await results.performFetch()
```

Sort descriptors use the known key-path contract directly. A key path must map to a
supported CodexDataKit model field; arbitrary key paths are not silently treated as
app-server sorts. Section descriptors support the same key-path style, plus
relationship aliases such as `.workspaceGroup` and `.workspace` for the common
sidebar groupings.

Fetches preserve object identity. If the same app-server thread appears in a later refresh, CodexDataKit mutates the existing `CodexChat` instance instead of replacing it.

```swift
try await results.refresh()

if results.nextCursor != nil {
    try await results.loadNextPage()
}
```

Use `registeredModel(for:)` when code needs only models that are already registered in
the context. This lookup does not create placeholder chats and does not issue an
app-server request.

```swift
if let chat = context.registeredModel(for: threadID) {
    render(chat.title)
}
```

`model(for: CodexThreadID)` remains the identity/placeholder API: it returns the
registered chat when present, or registers a placeholder `CodexChat` for that ID.
Workspace and workspace-group IDs also support `registeredModel(for:)` for symmetric
context identity lookups.

## Sectioning

Pass `sectionedBy` at the results/query boundary when a UI wants sidebar sections.

```swift
let workspaces = context.fetchedResults(
    for: CodexFetchDescriptor<CodexWorkspace>.workspaces,
    sectionedBy: .workspaceGroup
)

let chats = context.fetchedResults(
    for: CodexFetchDescriptor<CodexChat>(
        sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
    ),
    sectionedBy: .workspace
)
```

Passing no section descriptor gives a single unsectioned result. Section identifiers stay typed as `CodexFetchSectionID`, so workspace and workspace-group sections can be used directly in UI selection state.

## Fetched Results Transactions

Use `CodexFetchedResultsController` when non-SwiftUI UI code needs ordered changes instead of only the observable current value.

```swift
let controller = context.fetchedResultsController(
    for: CodexFetchDescriptor<CodexChat>.recentChats,
    sectionedBy: .workspaceGroup
)

Task {
    for await transaction in controller.transactions {
        apply(
            oldSnapshot: transaction.oldSnapshot,
            newSnapshot: transaction.newSnapshot,
            sectionChanges: transaction.sectionChanges,
            itemChanges: transaction.itemChanges
        )
    }
}

try await controller.performFetch()
```

The controller does not fetch or store a second copy of the model graph. Its `items`, `sections`, `snapshot`, cursors, phase, and errors are forwarded from the underlying `CodexFetchedResults`, and transactions are emitted from the same state updates that mutate those current values. Snapshots contain section IDs, optional titles, and item IDs only; section and item changes are ordered and include insert, delete, move, and update cases.

CodexDataKit does not import AppKit, UIKit, or SwiftUI for this API. Convert `CodexFetchedResultsTransaction` into `NSCollectionView`, `UICollectionView`, diffable data source, or `NSOutlineView` updates in the UI layer. Detail transcript streams remain the responsibility of `CodexChat.observe()`.

## Models

Models are context-attached observable objects:

```swift
let workspace = try await context.fetch(CodexFetchDescriptor<CodexWorkspace>.workspaces).first
let chat = try await workspace?.startChat()
try await chat?.send("Explain the latest diff.")
```

Attached models expose their context:

```swift
if let server = chat?.modelContext?.appServer {
    print(server)
}
```

Keep review-specific state, parsed findings, and review timelines outside CodexDataKit. CodexDataKit owns generic Codex app-server data models; higher-level packages can layer their own indices on top of `CodexChat.id`, workspace IDs, or sectioned fetch results.

## Live Chat Observation

Use `CodexChat.observe()` or `CodexModelContext.observe(_:)` when a detail view needs an initial transcript snapshot plus live app-server events applied to the same observable chat object.

```swift
let chat = context.model(for: CodexThreadID(rawValue: "thread-1"))
let observation = try await context.observe(chat)

// Render directly from chat.turns, chat.items, chat.phase, and chat.lastErrorDescription.
// Keep observation alive for as long as the UI should receive live updates.
observation.cancel()
```

Observation first refreshes the chat with `includeTurns: true`, then consumes `CodexThread.events`. Turn, item, message, delta, usage, completion, and failure events mutate the existing `CodexChat`, `CodexChat.Turn`, and `CodexChat.Item` instances in place.

When a UI needs one turn at a time, use the turn-scoped read projections instead of filtering the whole chat in higher-level packages:

```swift
if let snapshot = chat.turnSnapshot(for: turnID) {
    render(
        status: snapshot.status,
        error: snapshot.errorDescription,
        usage: snapshot.usage,
        transcript: snapshot.transcript
    )
}
```

`CodexChatTurnSnapshot` keeps references to the existing observable `CodexChat.Turn` and `CodexChat.Item` objects. It is not a separate live model and does not copy ownership of transcript state.

For streaming detail surfaces that render one turn at a time, fold `CodexChatChange` values through `CodexChatTurnProjection`:

```swift
var projection = CodexChatTurnProjection(selection: .latest)

for await change in observation.changes {
    let update = projection.apply(change)
    guard update.affectsSelectedTurn, let snapshot = update.snapshot else {
        continue
    }
    render(snapshot.items)
}
```

`CodexChatTurnProjection` owns generic change folding, item identity, item order, and latest/explicit turn selection. App-specific rendering projections should stay outside CodexDataKit.

When a higher-level package persists an app-specific operation identity, keep that identity outside CodexDataKit. Resolve it to the app-server thread ID at that layer, then observe the generic chat model:

```swift
let chat = context.model(for: operation.threadID)
let observation = try await chat.observe()
```

## SwiftUI

Install the container or context in the environment, then use `@CodexQuery` in views.

```swift
import SwiftUI
import CodexDataKit

struct Sidebar: View {
    @CodexQuery(
        sort: \.updatedAt,
        order: .reverse,
        sectionBy: .workspaceGroup
    )
    private var chats

    var body: some View {
        List {
            ForEach(chats.sections) { section in
                Section(section.title ?? "") {
                    ForEach(section.items) { chat in
                        Text(chat.title)
                    }
                }
            }
        }
    }
}

Sidebar()
    .codexModelContainer(container)
```

## Testing

Use `CodexAppServerKitTesting` to test CodexDataKit owners without a real app-server process.

```swift
import CodexAppServerKitTesting
import CodexDataKit
import Testing

@MainActor
@Test func loadsChats() async throws {
    let runtime = try await CodexAppServerTestRuntime.start(threads: [
        .init(id: "thread-1", name: "First")
    ])

    let context = CodexModelContainer(appServer: runtime.server).mainContext
    let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
    try await results.performFetch()

    #expect(results.items.first?.title == "First")
}
```

For lower-level app-server APIs, see [../CodexAppServerKit/README.md](../CodexAppServerKit/README.md).
