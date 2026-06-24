# CodexKit

CodexKit packages Swift SDK surfaces for building native Codex integrations.

## Products

- `CodexKit`: core package placeholder for future shared SDK types.
- `CodexAppServerKit`: high-level Swift API for a local `codex app-server`
  process, including threads, responses, review sessions, models, accounts, and
  login flows.
- `CodexAppServerKitTesting`: deterministic in-memory app-server test runtime
  for exercising `CodexAppServerKit` without launching a real process.
- `CodexUIKit`: server-backed observable owner models for native Codex UIs.

`CodexAppServerKit` keeps JSON-RPC framing and app-server request DTOs as
package implementation details. Public clients should use `CodexAppServer`,
`CodexThread`, `CodexReviewSession`, and typed domain values instead.

## CodexUIKit

`CodexUIKit` follows the same container/query/owner shape as SwiftData,
CoreData, and WebKit for SwiftUI:

- `CodexAppServer` owns the app-server connection lifetime.
- `CodexThreadQuery` describes the thread collection to fetch.
- `CodexThreadLibrary` is a query-bound observable owner.
- `CodexConversation` is a thread-bound observable owner.

UI code creates the owners with a server handle and sends intents to those
owners. The owners fetch from app-server internally and mutate their observable
semantic state in place.

```swift
let server = try await CodexAppServer(configuration: .init())
let library = CodexThreadLibrary(
    server: server,
    configuration: .init(query: .init(workspace: workspaceURL, limit: 50))
)

await library.refresh()

if let selectedThreadID = library.selectedThreadID {
    let conversation = try await library.conversation(for: selectedThreadID)
    try await conversation.send("Review this workspace")
}
```

SwiftUI views can hold these owners in `@State` or pass them through the
environment, then render directly from properties such as `library.sections`,
`conversation.turns`, `conversation.items`, and `conversation.phase`.
