# CodexKit

CodexKit is a Swift package for building macOS apps and tools that talk to a local `codex app-server`.

## Products

- `CodexAppServerKit`: Swift domain APIs for app-server connections, threads, responses, streaming, reviews, models, accounts, ChatGPT login, and API-key login.
- `CodexDataKit`: SwiftData-style `@Observable` app-server backed model objects and fetch APIs, built on top of `CodexAppServerKit`.
- `CodexAppServerKitTesting`: An in-memory app-server test runtime for deterministic tests without launching a real process.

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
.product(name: "CodexDataKit", package: "CodexKit"),
.product(name: "CodexAppServerKitTesting", package: "CodexKit"),
```

## CodexAppServerKit

Use `CodexAppServerKit` when you want direct control over the app-server connection and conversation APIs.

```swift
import CodexAppServerKit
import Foundation

let server = try await CodexAppServer()
let thread = try await server.startThread(in: workspaceURL)

let outcome = try await thread.respond(to: "Review this workspace.")
if case .completed(let response) = outcome {
    print(response.transcript.finalAnswer ?? "")
}

await server.close()
```

For thread management, typed terminal outcomes, review sessions, model/account
APIs, login flows, and testing utilities, see
[Sources/CodexAppServerKit/README.md](Sources/CodexAppServerKit/README.md). Native
UI code that needs live model updates uses CodexDataKit's context-owned
observation APIs.

## CodexAppServerKitTesting

Use `CodexAppServerKitTesting` from an external test target when production
behavior must run through an in-memory app-server connection. Queue opaque typed
fixtures on the transport, exercise the normal `CodexAppServer` API, and close
the runtime explicitly.

```swift
import CodexAppServerKit
import CodexAppServerKitTesting

let clock = CodexAppServerTestDeadlineClock()
let runtime = try await CodexAppServerTestRuntime.start(deadlineClock: clock)
let layer = try CodexAppServerTestConfigurationLayerMetadata(
    source: .sessionFlags,
    version: "test-config-v1"
)
let fixture = try CodexAppServerTestConfigurationReadResult(
    configuration: .init(model: "gpt-5-codex"),
    origins: ["model": layer],
    layers: [try .init(
        metadata: layer,
        configuration: .object(["model": .string("gpt-5-codex")])
    )]
)

try await runtime.transport.enqueueConfiguration(fixture)
let configuration = try await runtime.server.configuration()
precondition(configuration == fixture.configuration)
await runtime.close()
```

The public testing surface accepts domain-typed fixtures and closed operations;
raw JSON and method-string seams remain package-internal malformed-protocol test
tools. `CodexAppServerTestDeadlineClock` lets deadline tests wait for sleeper
registration and advance time without wall-clock sleeps. The standalone
[`CodexKitProductConsumer`](Fixtures/CodexKitProductConsumer) fixture compiles and
runs all three products without `@testable import`.

## CodexDataKit

Use `CodexDataKit` when you want SwiftData/CoreData-style app-server backed models for native UI code.

```swift
import CodexAppServerKit
import CodexDataKit
import Foundation

let appServer = try await CodexAppServer()
let container = CodexModelContainer(appServer: appServer)
let context = container.mainContext

let results = context.fetchedResults(
    for: CodexFetchDescriptor<CodexChat>(
        sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
    )
)
try await results.performFetch()

for chat in results.items {
    let revision = [chat.gitInfo?.branch, chat.gitInfo?.sha]
        .compactMap { $0 }
        .joined(separator: " @ ")
    print(revision.isEmpty ? chat.title : revision)
}

let workspace = try await context.fetch(CodexFetchDescriptor<CodexWorkspace>.workspaces).first
let chat = try await workspace?.startChat()
try await chat?.send("Summarize this project.")
await appServer.close()
```

Render from `CodexWorkspaceGroup`, `CodexWorkspace`, and `CodexChat` observable model objects. Use the value-typed `CodexFetchDescriptor` for explicit fetches or `@CodexQuery` for SwiftUI views.

For model containers, fetch requests, sectioning, SwiftUI queries, and ownership guidance, see [Sources/CodexDataKit/README.md](Sources/CodexDataKit/README.md).
