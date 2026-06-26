# CodexAppServerKit

CodexAppServerKit is a Swift library for working with a local
`codex app-server` process from macOS apps and tools.

The package hides JSON-RPC framing and app-server DTOs behind Swift domain
types. Callers work with an app-server container, sessions, prompts,
responses, response streams, transcript items, log entries, models, accounts,
and login handles.

## Container

Create one `CodexAppServer` for the lifetime of the app-server connection:

```swift
import CodexAppServerKit

let appServer = try await CodexAppServer()
let thread = try await appServer.startThread(in: workspaceURL)

let response = try await thread.respond(to: "Review this workspace.")
print(response.finalAnswer ?? "")

await appServer.close()
```

`CodexAppServer()` uses the local `codex` executable over stdio. It performs
`initialize` / `initialized`, manages the process transport, routes
notifications, retries app-server overload responses, and preserves schema-new
notifications as unknown domain events.

## Configuration

`CodexAppServer.Configuration` owns the container identity and local-process
runtime settings. The default local process resolves Codex home from
`CODEX_HOME`, then `HOME/.codex` on macOS command-line runs, then Application
Support for container-style environments. Pass `localProcess.codexHomeURL` when
an app wants an isolated runtime directory.

```swift
let configuration = CodexAppServer.Configuration(
    localProcess: .init(
        codexHomeURL: appSupportURL.appendingPathComponent("Codex", isDirectory: true)
    )
)
let appServer = try await CodexAppServer(configuration: configuration)
```

## Threads

`CodexThread` is the long-lived session handle for a Codex conversation in a workspace. Use `respond` for a single final response, or `streamResponse` when the UI needs partial snapshots.

```swift
let thread = try await appServer.startThread(
    in: workspaceURL,
    instructions: .init(developer: "Keep responses concise."),
    options: .init(model: "gpt-5", approvalMode: .autoReview)
)

let response = try await thread.respond {
    "Run the checks."
    "Focus on failing tests."
}
```

Thread management is exposed without requiring raw request DTOs:

```swift
let snapshot = try await thread.read(includeTurns: true)
try await thread.rename(to: "Release review")
try await thread.compact()
try await thread.archive()
let restored = try await thread.unarchive()
try await thread.rollback(turnCount: 1)
try await thread.delete()
```

## Streaming

Use `streamResponse` when callers need partial response state before the final `CodexResponse`. The stream yields snapshots of the accumulated response state and can be collected into the final result.

```swift
let stream = try await thread.streamResponse(to: "Summarize the changes.")

for try await snapshot in stream {
    render(snapshot.transcript.items)
}

let response = try await stream.collect()
```

Codex also supports explicit cancellation for an in-flight response. App-server
has real `turn/steer` and `turn/interrupt` control paths, so
`CodexResponseStream` exposes them directly:

```swift
let stream = try await thread.streamResponse(to: "Run the slow checks.")
try await stream.steer(with: "Prefer the smallest fix.")
try await stream.cancel()
```

If the task awaiting `stream.collect()` is cancelled, the stream also sends the
same cancellation request to app-server.

When a UI needs to accept another prompt while a response is in flight, submit
it with an explicit follow-up mode:

```swift
let next = try await stream.submit(
    "Now update the tests.",
    mode: .queueAfterCurrentResponse
)

let urgent = try await stream.submit(
    "Stop and try the shorter path.",
    mode: .cancelCurrentResponse
)
```

Use `steer(with:)` when the new input should modify the current turn.
`.queueAfterCurrentResponse` waits for the current response to finish before
starting the next turn. `.cancelCurrentResponse` sends `turn/interrupt`,
waits for app-server's terminal event, and then starts the next turn in the
same thread.

`CodexGenerationOptions` includes `transcriptErrorHandlingPolicy` for controlling transcript handling after failed turns:

```swift
let stream = try await thread.streamResponse(
    to: "Try the risky change.",
    options: .init(transcriptErrorHandlingPolicy: .revertTranscript)
)
```

It also exposes reasoning controls with domain values instead of raw strings:

```swift
let response = try await thread.respond(
    to: "Find the risky part of this change.",
    options: .init(
        effort: .high,
        summary: .detailed,
        personality: .pragmatic
    )
)

print(response.usage?.reasoningOutputTokens ?? 0)
```

Structured final answers can be constrained with a JSON schema:

```swift
let response = try await thread.respond(
    to: "Summarize the change as JSON.",
    options: .init(outputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "summary": .object(["type": .string("string")]),
            "risk": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("summary"), .string("risk")]),
    ]))
)
```

Threads also expose async sequences for chat, transcript updates, and log-style
consumers. This is the API surface intended for higher-level products that need
to render Codex output continuously outside a single response stream.

```swift
for try await message in thread.messages {
    print(message.text)
}
```

```swift
for try await transcript in thread.transcriptUpdates {
    render(transcript.items)
}
```

```swift
for try await entry in thread.logEntries {
    switch entry {
    case .reasoningDelta(let delta, _):
        renderReasoningDelta(delta)
    case .itemStarted(let item, _), .itemUpdated(let item, _), .itemCompleted(let item, _):
        switch item.content {
        case .message(let message):
            renderMessage(message)
        case .reasoning(let reasoning):
            renderReasoning(summary: reasoning.summary, content: reasoning.content)
        case .command(let command):
            renderCommand(command.command, output: command.output)
        case .toolCall(let tool):
            renderToolCall(tool.name, result: tool.result, error: tool.error)
        case .fileChange(let fileChange):
            renderFileChange(fileChange.path, output: fileChange.output)
        default:
            break
        }
    case .messageDelta(let delta, _, _):
        renderMessageDelta(delta.text)
    default:
        break
    }
}
```

`CodexThread.events` is the full thread event stream. It includes turn
lifecycle, item lifecycle, message deltas, token usage, thread status, and
unknown notifications:

```swift
for try await event in thread.events {
    switch event {
    case .reasoningDelta(let delta, _):
        renderReasoningDelta(delta)
    case .tokenUsageUpdated(let usage, _):
        updateUsage(usage.totalTokens)
    case .unknown(let raw):
        logUnknownNotification(raw.method)
    default:
        break
    }
}
```

This lets review clients build logs from
CodexAppServerKit domain events instead of parsing JSON-RPC notifications or
string logs directly.

Known `CodexThreadItem` values keep their high-level `content` projection and
the original `rawPayload`. Use the raw payload when a product needs
full-fidelity rendering for app-server fields that the current Kit version does
not yet model directly.

## Reviews

`review/start` is part of the app-server surface, so CodexAppServerKit exposes
it as a high-level `CodexAppServer` operation and as a lower-level thread
operation for callers that already own a thread. A review session provides the
review turn response and review-domain streams. If app-server detaches the
review into a separate thread, `events`, `logEntries`, `progress`, and
`transcriptUpdates` are bound to that review thread automatically. Detached
review notification routing is owned by CodexAppServerKit, so callers do not
need to parse JSON-RPC notifications or track app-server thread event details.

```swift
let review = try await appServer.startReview(
    in: workspaceURL,
    target: .baseBranch("main"),
    options: .init(model: "gpt-5")
)

for try await entry in review.logEntries {
    switch entry {
    case .itemCompleted(let item, _):
        renderReviewLog(item)
    case .reasoningDelta(let delta, _):
        renderReasoningDelta(delta)
    default:
        break
    }
}

for try await progress in review.progress {
    renderReviewTranscript(progress.transcript)
    if progress.phase == .completed {
        break
    }
}

let response = try await review.collect()
print(response.finalAnswer ?? "")
```

Use `CodexThread.startReview` when a thread owner is already explicit:

```swift
let thread = try await appServer.startThread(in: workspaceURL)
let review = try await thread.startReview(target: .uncommittedChanges)
```

Review targets are Swift domain values:

```swift
try await appServer.startReview(in: workspaceURL, target: .uncommittedChanges)
try await appServer.startReview(in: workspaceURL, target: .commit(sha: sha, title: title))
try await appServer.startReview(in: workspaceURL, target: .custom(instructions: instructions))
```

`CodexReviewSession.events` yields `CodexReviewEvent`, preserving unknown
schema-new notifications as `CodexRawNotification`. `logEntries` yields
`CodexReviewLogEntry` values for command, reasoning, tool, file-change, message,
and delta output. `progress` yields `CodexReviewProgress` snapshots until the
review turn completes or fails. `transcriptUpdates` remains the transcript
sequence for the review thread itself, which is useful when a UI wants
thread-bound transcript snapshots rather than review progress phases.

`CodexReviewSession` also owns the app-server lifecycle identity for a review.
Use `sourceThreadID`, `activeTurnThreadID`, `associatedThreadIDs`, and
`cleanupThreadIDs` when a host app needs to track source, detached review, and
cleanup ownership without keeping its own app-server dictionaries.

```swift
let identity = review.identity
persist(identity)

let restored = try await appServer.resumeReview(identity)
try await restored.cancel { cancellation in
    noteActiveTurnThread(cancellation.threadID)
}
```

`CodexReviewIdentity` is a `Codable` Swift value containing only CodexKit
identity: source thread, review turn, optional detached review thread, and
active review thread model when known. It is intended for persisted app-server
review runs and does not depend on any higher-level review domain model.

`CodexAppServer` also owns app-server review restart and cleanup lifecycle
state. A host that needs to interrupt and restart a review can prepare a
transient token, restart from it, then perform best-effort cleanup without
tracking detached review thread IDs itself:

```swift
let token = try await appServer.prepareReviewRestart(identity)
let restarted = try await appServer.restartPreparedReview(
    token,
    target: .baseBranch("main"),
    delivery: .detached
)
await appServer.cleanupReview(restarted.identity)
```

## Responses

`CodexResponse` is the final result from `respond` or `ResponseStream.collect()`.
It carries the final answer, transcript, status, token usage, and `turnID`.

Final answers are derived from assistant messages whose phase is
`.finalAnswer`. If no final-answer phase is present, the last normal assistant
message is used as a fallback.

## Prompts

`CodexPrompt` accepts text and structured parts:

```swift
let prompt: CodexPrompt = .init(parts: [
    .text("Explain this screenshot."),
    .localImage(screenshotURL),
    .mention(name: "repo", path: workspaceURL),
])
```

String literals are supported for simple prompts:

```swift
try await thread.respond(to: "What changed?")
```

For dynamic prompts, use the result-builder initializer or the builder overloads
on `respond` and `streamResponse`:

```swift
let response = try await thread.respond {
    "Explain this screenshot."
    CodexPrompt.Part.localImage(screenshotURL)
    if includeRepository {
        CodexPrompt.Part.mention(name: "repo", path: workspaceURL)
    }
}
```

## Models, Account, And Login

```swift
let models = try await appServer.models()
let account = try await appServer.account(refreshToken: true)
let configuration = try await appServer.configuration()
let rateLimits = try await appServer.rateLimits()
```

Update configuration through a patch so `nil` can mean "clear this setting"
without making every field optional update state visible in call sites:

```swift
var patch = CodexConfigurationPatch()
patch.setReviewModel("gpt-5-codex-review")
patch.setReasoningEffort(.high)
patch.setServiceTier(nil)
try await appServer.updateConfiguration(patch)
```

Login flows return typed handles:

```swift
let accountEvents = await appServer.accountEvents()
let handle = try await appServer.loginChatGPT()

for try await event in accountEvents {
    if case .loginCompleted(let completion) = event, completion.loginID == handle.id {
        break
    }
}
```

API key and device-code login are also available:

```swift
try await appServer.loginAPIKey(apiKey)
let deviceCode = try await appServer.loginChatGPTDeviceCode()
```

## Testing

Use `CodexAppServerKitTesting` to exercise `CodexAppServer` without launching a
real `codex app-server` process. The test runtime uses an in-memory transport,
enqueues the startup `initialize` response, records requests, and lets tests
emit server notifications explicitly.

```swift
import CodexAppServerKit
import CodexAppServerKitTesting
import Testing

@Test func startsThread() async throws {
    let runtime = try await CodexAppServerTestRuntime.start()
    try await runtime.transport.enqueueThreadStart(
        threadID: "thread-test",
        model: "gpt-5"
    )

    let thread = try await runtime.server.startThread(
        in: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
        options: .init(model: "gpt-5")
    )

    #expect(thread.id.rawValue == "thread-test")
    #expect(await runtime.transport.recordedRequests().map(\.method) == [
        "initialize",
        "thread/start",
    ])
}
```

For concurrency-sensitive tests, hold a request with
`CodexAppServerTestGate` and release it explicitly. This avoids depending on
sleep duration or repeated `Task.yield()` calls.

```swift
try await runtime.transport.enqueueTurnStart(turnID: "turn-1")
try await runtime.transport.enqueueEmpty(for: "turn/interrupt")

let stream = try await thread.streamResponse(to: "Run checks.")
let gate = CodexAppServerTestGate()
await runtime.transport.holdNext(method: "turn/interrupt", gate: gate)

let cancelTask = Task {
    try await stream.cancel()
}

await runtime.transport.waitForRequest(method: "turn/interrupt")
await gate.open()
try await cancelTask.value
```

## Boundary

Public users should not need to import or call JSON-RPC or `AppServerAPI`
request DTOs. Those remain package-level implementation details.

The public boundary is:

- `CodexAppServer`
- `CodexThreadID`
- `CodexTurnID`
- `CodexThread`
- `CodexReviewTarget`
- `CodexReviewSession`
- `CodexReviewIdentity`
- `CodexReviewRestartToken`
- `CodexReviewResumeOptions`
- `CodexReviewEvent`
- `CodexReviewLogEntry`
- `CodexReviewProgress`
- `CodexReviewEventSequence`
- `CodexReviewLogSequence`
- `CodexReviewProgressSequence`
- `CodexResponse`
- `CodexResponseStream`
- `CodexGenerationOptions`
- `CodexTranscriptErrorHandlingPolicy`
- `CodexPrompt`
- `CodexTranscript`
- `CodexThreadItem`
- `CodexThreadEvent`
- `CodexModel`
- `CodexAccount`
- `CodexAccountEvent`
- `CodexLoginCompletion`
- `CodexLoginHandle`

Unknown notifications and unknown item kinds are preserved so clients can keep
running when app-server adds new schema.
