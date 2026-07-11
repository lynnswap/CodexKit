# CodexDataKit

CodexDataKit provides SwiftData-style `@Observable` app-server backed models on top of `CodexAppServerKit`.

Use this package when app or UI code needs workspace group, workspace, and chat models without rendering directly from JSON-RPC payloads.

## Main Types

- `CodexModelContainer`: Owns the `CodexAppServer` and vends the main `CodexModelContext`.
- `CodexModelContext`: Fetches models, preserves model identity, and performs app-server actions for attached models.
- `CodexFetchDescriptor`: SwiftData-style value description of predicate, sort order, limit, offset, and pending-change inclusion.
- `CodexFetchRequest`: CoreData-style mutable request object for predicate, sort descriptors, limit, offset, and pending-change inclusion.
- `CodexFetchedResults`: Observable CoreData-style fetch results with items, optional sections, cursors, loading phase, and errors.
- `CodexFetchedResultsController`: Non-UI fetched-results controller that keeps `CodexFetchedResults` as the current-value owner and exposes ordered snapshot transactions.
- `CodexFetchedResultsSnapshot`, `CodexFetchedResultsTransaction`: Section and item ID snapshots plus section/item changes suitable for conversion to native UI update APIs.
- `CodexPersistentModel`: SwiftData-style model protocol. The protocol itself is not main-actor isolated; concrete context ownership decides the isolation domain.
- `CodexWorkspaceGroup`, `CodexWorkspace`, `CodexChat`, `CodexTurn`, `CodexItem`: Observable model objects attached to a model context.
- `CodexQuery`: A SwiftUI `DynamicProperty` wrapper around `CodexFetchedResults`.
- `CodexFetchPhase`: The typed fetch state. Validation and app-server failures are carried by `CodexFetchFailure`.

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
let workspaceID = CodexWorkspaceID(rawValue: workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path)
let descriptor = CodexFetchDescriptor<CodexChat>(
    predicate: #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.workspaceID == workspaceID
            && chat.searchableText.localizedStandardContains("review")
    },
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
let workspaceID = CodexWorkspaceID(rawValue: workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path)
request.predicate = #Predicate<CodexChat> { chat in
    chat.isArchived == false && chat.workspaceID == workspaceID
}
request.sortDescriptors = [CodexSortDescriptor(\.updatedAt, order: .reverse)]
request.fetchLimit = 100

let results = context.fetchedResults(for: request)
try await results.performFetch()
```

Sort descriptors use the known key-path contract directly. A key path must map to a
supported CodexDataKit model field; arbitrary key paths are not silently treated as
app-server sorts. Section descriptors support the same key-path style, plus
relationship aliases such as `.workspaceGroup` and `.workspace` for the common
sidebar groupings. Unsupported predicate, sort, section, model, limit, and offset
values fail through `CodexFetchFailure.validation` instead of trapping during query
construction or SwiftUI updates.

A nil chat predicate is the active-only convenience scope. An explicit predicate is
evaluated literally: if it does not mention `isArchived`, CodexDataKit fetches and
merges both active and archived server scopes. Add `chat.isArchived == false` when a
consumer wants active chats only.

Chat fetches include pending/live context changes by default, matching SwiftData's
`includePendingChanges` shape. A `CodexChat` created or actively observed by the
context remains eligible for fetch results when the app-server thread list
temporarily omits it, as long as the predicate can be decided locally. Set
`includePendingChanges` to `false` on `CodexFetchDescriptor` or `CodexFetchRequest`
when a fetch should report only the server-owned page membership.

Fetches preserve object identity. If the same app-server thread appears in a later refresh, CodexDataKit mutates the existing `CodexChat` instance instead of replacing it.

```swift
try await results.refresh()

if results.nextCursor != nil {
    try await results.loadNextPage()
}
```

Each `CodexFetchedResults` serializes fetch, refresh, pagination, and mutation-driven
reloads. A refresh rebuilds the currently loaded window in staging and commits items,
cursors, sections, and phase together. Cancelling a queued load removes it from the
queue; cancelling an in-flight load preserves the prior stable result and phase.
Queries stay live for mutations performed through the same model context. Changes
made by another process or app-server client require an explicit `refresh()`.

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

The controller does not fetch or store a second copy of the model graph. Its `items`, `sections`, `snapshot`, cursors, and phase are forwarded from the underlying `CodexFetchedResults`, and transactions are emitted from the same state updates that mutate those current values. Snapshots contain section IDs, optional titles, and item IDs only; section and item changes are ordered and include insert, delete, move, and update cases. The transaction stream buffers only the newest transaction. Every transaction carries complete old and new identity snapshots, so a consumer whose current snapshot no longer equals `oldSnapshot` replaces it with `newSnapshot` instead of replaying stale granular changes.

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

Current CodexDataKit models are owned by the container's main context. Treat model
instances like Core Data or SwiftData model objects: keep them inside the context
that vended them, mutate same-identity objects in place, and pass semantic IDs or
value DTOs across concurrency domains. Do not make UI-owned mirrors of model
properties just to observe changes.

The main context is the UI-facing context, similar to SwiftData's
`ModelContainer.mainContext`. Future background contexts or model actors should own
their own model instances and merge by semantic IDs, not share mutable model
objects across actors.

Keep review-specific state, parsed findings, and review timelines outside CodexDataKit. CodexDataKit owns generic Codex app-server data models; higher-level packages can layer their own indices on top of `CodexChat.id`, workspace IDs, or sectioned fetch results.

## Live Chat Observation

Use `CodexChat.observe()` or `CodexModelContext.observe(_:)` when a detail view needs an immutable transcript projection followed by live app-server updates.

```swift
let chat = context.model(for: CodexThreadID(rawValue: "thread-1"))
let observation = try await context.observe(chat)

for await event in observation.updates {
    switch event.payload {
    case .snapshot(let snapshot, _):
        projection.replace(with: snapshot)
    case .update(let update):
        projection.apply(update)
    }
}

await observation.close()
```

Observation first refreshes or seeds the chat with `includeTurns: true`, then consumes `CodexThread.events`. Turn, item, message, delta, usage, completion, and failure events still mutate the context-owned model graph, but that graph is not the presentation baseline. `CodexItem.id` is the stable model identity; `CodexItem.itemID` keeps the raw app-server item ID.

Each observation owns one subscriber lease and one iterator. The first event is a complete immutable snapshot. Later events carry a `(generation, sequence)` cursor and either a self-contained update or another complete snapshot barrier. Apply updates only to the immediately preceding projection; a snapshot replaces the projection and covers every event through its cursor. A second consumer must call `observe()` again instead of creating a second iterator from the same `updates` value.

Item removal and text-append updates use `CodexChatItemLocator`, whose turn ID, item kind, and raw item ID match DataKit's semantic merge key. Do not locate those targets by raw item ID alone because distinct item kinds can legally share that wire ID.

`CodexChatObservation.chat` remains the context-owned semantic action and identity handle. Do not reread it to apply an update: the graph may already contain later mutations. Keep selection state as semantic IDs and build app-specific presentation state only from event payloads. `CodexChatUpdate.affectedTurnID` can scope update handling after the projection has validated and applied the event cursor.

Subscriber queues are bounded. A slow subscriber receives a complete `.bufferOverflow` snapshot instead of an unbounded delta backlog. Explicit `close()` finishes that subscriber and waits for its release; closing the last lease also cancels and joins the shared upstream pump. Iterator task cancellation releases the same lease. Dropping the observation sends a synchronous best-effort release, but normal teardown should always await `close()`.

CodexDataKit may read app-server thread snapshots internally to establish or reconcile the current value. Those reads are not part of the observation stream. Once live events have advanced an observed chat, later thread reads are merged into the existing model and must not rewind already-applied live turns or items unless an explicit model operation such as rollback requests replacement.

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
