# CodexKit

CodexKit is a Swift package for building macOS apps and tools that talk to a local `codex app-server`.

## Products

- `CodexAppServerKit`: Swift domain APIs for app-server connections, threads, responses, streaming, reviews, models, accounts, and login flows.
- `CodexUIKit`: `@Observable` model objects for native Codex UIs, built on top of `CodexAppServerKit`.
- `CodexAppServerKitTesting`: An in-memory app-server test runtime for deterministic tests without launching a real process.
- `CodexKit`: A small shared package target for package-level symbols.

## Requirements

- macOS 15.4 or later.
- Swift 6.3 or later.
- A local `codex` executable when using the real app-server process.

## Add The Package

```swift
dependencies: [
    .package(url: "https://github.com/lynnswap/CodexKit.git", branch: "main"),
]
```

Add the products your target needs:

```swift
.product(name: "CodexAppServerKit", package: "CodexKit"),
.product(name: "CodexUIKit", package: "CodexKit"),
```

## CodexAppServerKit

Use `CodexAppServerKit` when you want direct control over the app-server connection and conversation APIs.

```swift
import CodexAppServerKit
import Foundation

let server = try await CodexAppServer()
let thread = try await server.startThread(in: workspaceURL)

let response = try await thread.respond(to: "Review this workspace.")
print(response.finalAnswer ?? "")

await server.close()
```

Use `streamResponse` when your UI or tool needs incremental response snapshots:

```swift
let stream = try await thread.streamResponse(to: "Summarize the changes.")

for try await snapshot in stream {
    render(snapshot.transcript.items)
}

let response = try await stream.collect()
```

For thread management, streaming, review sessions, model/account APIs, login flows, and testing utilities, see [Sources/CodexAppServerKit/README.md](Sources/CodexAppServerKit/README.md).

## CodexUIKit

Use `CodexUIKit` when you want CoreData-style app-server backed models for native UI code.

```swift
import CodexAppServerKit
import CodexUIKit
import Foundation

let container = try await CodexModelContainer()
let context = container.mainContext

let results = context.fetchedResults(for: CodexFetchRequest<CodexChat>.recentChats)
try await results.performFetch()

for chat in results.items {
    print(chat.title)
}

let workspace = try await context.fetch(CodexFetchRequest<CodexWorkspace>.workspaces).first
let chat = try await workspace?.startChat()
try await chat?.send("Summarize this project.")
```

Render from `CodexWorkspaceGroup`, `CodexWorkspace`, and `CodexChat` observable model objects. Use `CodexFetchRequest` / `CodexFetchedResults` for CoreData-like fetches, or `@CodexQuery` for SwiftUI views.

For model containers, fetch requests, sectioning, SwiftUI queries, and ownership guidance, see [Sources/CodexUIKit/README.md](Sources/CodexUIKit/README.md).
