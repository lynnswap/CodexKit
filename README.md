# CodexKit

CodexKit packages Swift SDK surfaces for building native Codex integrations.

## Products

- `CodexKit`: core package placeholder for future shared SDK types.
- `CodexAppServerKit`: high-level Swift API for a local `codex app-server`
  process, including threads, responses, review sessions, models, accounts, and
  login flows.
- `CodexAppServerKitTesting`: deterministic in-memory app-server test runtime
  for exercising `CodexAppServerKit` without launching a real process.
- `CodexUIKit`: snapshot-backed server models for thread library, conversations,
  and account owner state used by native UIs.

`CodexAppServerKit` keeps JSON-RPC framing and app-server request DTOs as
package implementation details. Public clients should use `CodexAppServer`,
`CodexThread`, `CodexReviewSession`, and typed domain values instead.

## API Note

`CodexUIKit` follows the same mental model as CoreData / SwiftData / WebKit-style
owners: you create an observable owner object (`CodexThreadLibrary`,
`CodexConversation`, `CodexAccountStatus`) per logical container/query boundary and
read observable state from it.

- `CodexThreadLibrary` owns thread list query state (`sections`, cursors, selected ID)
  and owns refresh / pagination methods.
- `CodexConversation` owns a `CodexThread` snapshot owner and exposes
  `snapshot`, `transcript`, `timelineRows`, and `phase` as the primary
  observable state for UI.
- `CodexAccountStatus` owns account/config/rate-limit state and exposes the same
  phase/error pattern for UI rendering.

`CodexConversation.refresh(includeTurns:)` currently reflects `thread.read(includeTurns:)`
turn summaries (as a first-slice `timelineRows`) and `send` completion transcript in
observable state. Live `thread.events` / `transcriptUpdates` subscriptions are a
next-step feature that will be added with explicit task ownership/cancellation design.
