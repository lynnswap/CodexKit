# CodexKit

CodexKit packages Swift SDK surfaces for building native Codex integrations.

## Products

- `CodexKit`: core package placeholder for future shared SDK types.
- `CodexAppServerKit`: high-level Swift API for a local `codex app-server`
  process, including threads, responses, review sessions, models, accounts, and
  login flows.
- `CodexAppServerKitTesting`: deterministic in-memory app-server test runtime
  for exercising `CodexAppServerKit` without launching a real process.

`CodexAppServerKit` keeps JSON-RPC framing and app-server request DTOs as
package implementation details. Public clients should use `CodexAppServer`,
`CodexThread`, `CodexReviewSession`, and typed domain values instead.
