# CodexDataKit

CodexDataKit provides SwiftData-style `@Observable` app-server backed models on top of `CodexAppServerKit`.

Use this package when app or UI code needs workspace group, workspace, and chat models without rendering directly from JSON-RPC payloads.

## Main Types

- `CodexModelContainer`: Owns the `CodexAppServer` and vends the main `CodexModelContext`.
- `CodexModelContext`: Fetches models, preserves model identity, and performs app-server actions for attached models.
- `CodexFetchRequest`: Describes filters, sort descriptors, sectioning, paging, and the model type to fetch.
- `CodexFetchedResults`: Observable CoreData-style fetch results with items, sections, cursors, loading phase, and errors.
- `CodexWorkspaceGroup`, `CodexWorkspace`, `CodexChat`: Observable model objects attached to a model context.
- `CodexQuery`: A SwiftUI `DynamicProperty` wrapper around `CodexFetchedResults`.
- `CodexDataPhase`: A small data-loading state enum with `idle`, `loading`, `loaded`, and `failed`.

## Quick Start

```swift
import CodexDataKit

let container = try await CodexModelContainer()
let context = container.mainContext

let chats = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
try await chats.performFetch()

for chat in chats.items {
    print(chat.title)
}
```

## Fetching

`CodexFetchRequest` is the CoreData-like API. The request type decides which model is returned.

```swift
let request = CodexFetchRequest<CodexChat>(
    filter: .init(
        archived: false,
        workspace: workspaceURL,
        searchTerm: "review"
    ),
    sortDescriptors: [.recencyAt(.reverse)],
    sectionDescriptor: .workspaceGroup,
    fetchLimit: 50
)

let results = context.fetchedResults(for: request)
try await results.performFetch()
```

Fetches preserve object identity. If the same app-server thread appears in a later refresh, CodexDataKit mutates the existing `CodexChat` instance instead of replacing it.

```swift
try await results.refresh()

if results.nextCursor != nil {
    try await results.loadNextPage()
}
```

## Sectioning

Use `sectionDescriptor` when a UI wants sidebar sections.

```swift
let workspaces = context.fetchedResults(for: CodexFetchRequest<CodexWorkspace>.workspaces(
    sectionedBy: .workspaceGroup
))

let chats = context.fetchedResults(for: CodexFetchRequest<CodexChat>(
    sortDescriptors: [.updatedAt(.reverse)],
    sectionDescriptor: .workspace
))
```

Passing no section descriptor gives a single unsectioned result, matching CoreData's optional `sectionNameKeyPath` shape.

## Models

Models are context-attached observable objects:

```swift
let workspace = try await context.fetch(CodexFetchRequest<CodexWorkspace>.workspaces).first
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

For review UIs that persist app-server review identity, resolve and observe the active review thread without introducing a separate aggregate:

```swift
let observation = try await context.observe(reviewIdentity)
let reviewChat = observation.chat
```

## SwiftUI

Install the container or context in the environment, then use `@CodexQuery` in views.

```swift
import SwiftUI
import CodexDataKit

struct Sidebar: View {
    @CodexQuery(CodexFetchRequest<CodexChat>(
        sortDescriptors: [.updatedAt(.reverse)],
        sectionDescriptor: .workspaceGroup
    ))
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
    let runtime = try await CodexAppServerTestRuntime.start()
    try await runtime.transport.enqueueThreadList(.init(threads: [
        .init(id: "thread-1", name: "First")
    ]))

    let context = CodexModelContainer(appServer: runtime.server).mainContext
    let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
    try await results.performFetch()

    #expect(results.items.first?.title == "First")
}
```

For lower-level app-server APIs, see [../CodexAppServerKit/README.md](../CodexAppServerKit/README.md).
