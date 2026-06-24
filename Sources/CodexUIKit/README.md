# CodexUIKit

CodexUIKit provides `@Observable` model objects for building native Codex UIs on top of `CodexAppServerKit`.

Use this package when a native UI needs thread-list state, conversation state, loading/error phase, and user actions without rendering directly from app-server request or notification payloads.

## Main Types

- `CodexThreadLibrary`: Loads thread lists from `CodexAppServer`, tracks selection, supports pagination, starts conversations, and applies archive, unarchive, and delete actions.
- `CodexConversation`: Represents one Codex thread for UI rendering, including title, workspace metadata, turn snapshots, transcript items, loading phase, and send/refresh actions.
- `CodexUIPhase`: A small UI state enum with `idle`, `loading`, `loaded`, and `failed`.

## Quick Start

```swift
import CodexAppServerKit
import CodexUIKit
import Foundation

let server = try await CodexAppServer()
let library = CodexThreadLibrary(
    server: server,
    configuration: .init(query: .init(workspace: workspaceURL, limit: 50))
)

await library.refresh()

let conversation = try await library.startConversation(in: workspaceURL)
try await conversation.send("Summarize this project.")
```

## Thread Lists

`CodexThreadLibrary` fetches `CodexThreadSnapshot` records through `CodexAppServer.listThreads(_:)` and keeps stable observable `Section` and `ThreadSummary` objects for UI rendering.

```swift
let library = CodexThreadLibrary(
    server: server,
    configuration: .init(
        query: .init(archived: false, workspace: workspaceURL, limit: 50),
        sectionTitle: "Workspace Threads"
    )
)

await library.refresh()

for section in library.sections {
    for thread in section.threads {
        print(thread.title)
    }
}
```

Use `loadNextPage()` when `nextCursor` is available:

```swift
if library.nextCursor != nil {
    await library.loadNextPage()
}
```

Selection stays on the library:

```swift
library.selectThread(threadID)
let conversation = try await library.selectedConversation()
```

## Conversations

Create a conversation from a selected or newly started thread, then render from observable properties.

```swift
let conversation = try await library.conversation(for: threadID)
try await conversation.refresh()

print(conversation.title)
for item in conversation.items {
    if let text = item.text {
        print(text)
    }
}
```

Send prompts through the conversation. The conversation updates its `turns`, `items`, `phase`, and `lastErrorDescription` from the returned `CodexResponse`.

```swift
let response = try await conversation.send("Explain the latest diff.")
print(response.finalAnswer ?? "")
```

## Thread Actions

Library actions call the app-server at the right level and update or reload the list as needed.

```swift
try await library.archive(threadID)
try await library.unarchive(threadID)
try await library.delete(threadID)
```

`startConversation(in:instructions:options:configuration:)` starts a new server thread and returns a `CodexConversation` for it:

```swift
let conversation = try await library.startConversation(
    in: workspaceURL,
    instructions: .init(developer: "Keep answers concise.")
)
```

## State Ownership

Keep the long-lived `CodexAppServer` at the app or feature boundary, then create `CodexThreadLibrary` and `CodexConversation` where the UI state is owned. Render from their observable properties and call their methods for user actions.

## Testing

Use `CodexAppServerKitTesting` to test CodexUIKit owners without a real app-server process.

```swift
import CodexAppServerKitTesting
import CodexUIKit
import Testing

@MainActor
@Test func loadsThreads() async throws {
    let runtime = try await CodexAppServerTestRuntime.start()
    try await runtime.transport.enqueueThreadList(.init(threads: [
        .init(id: "thread-1", name: "First")
    ]))

    let library = CodexThreadLibrary(server: runtime.server)
    await library.refresh()

    #expect(library.sections.first?.threads.first?.title == "First")
}
```

For lower-level app-server APIs, see [../CodexAppServerKit/README.md](../CodexAppServerKit/README.md).
