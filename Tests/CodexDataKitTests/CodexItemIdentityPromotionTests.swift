import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Foundation
import Testing

@MainActor
struct CodexItemIdentityPromotionTests {
    @Test("fallback message delta promotes to authoritative item identity")
    func fallbackMessageDeltaPromotesToAuthoritativeItemIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-identity"))
        let turnID = CodexTurnID(rawValue: "turn-identity")

        _ = chat.apply(CodexThreadEvent.turnStarted(turnID))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "Final answer"),
            turnID: turnID
        ))
        let fallbackItem = try #require(chat.items.first)
        #expect(fallbackItem.itemID == "agent-message-delta:turn-identity")

        let rawPayload = Data(#"{"id":"item-real","type":"agent_message"}"#.utf8)
        let authoritativeItem = agentMessageItem(
            id: "item-real",
            text: "Final answer",
            phase: .finalAnswer,
            rawPayload: rawPayload
        )

        _ = chat.apply(CodexResponse(
            turnID: turnID,
            status: .completed,
            transcript: .init(items: [authoritativeItem])
        ))

        let promotedItem = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(promotedItem === fallbackItem)
        #expect(promotedItem.id == fallbackItem.id)
        #expect(promotedItem.itemID == "item-real")
        #expect(promotedItem.rawPayload == rawPayload)
        #expect(promotedItem.message?.phase == .finalAnswer)
    }

    @Test("itemID-present message delta uses authoritative item identity")
    func itemIDPresentMessageDeltaUsesAuthoritativeItemIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-real-delta"))
        let turnID = CodexTurnID(rawValue: "turn-real-delta")

        _ = chat.apply(CodexThreadEvent.turnStarted(turnID))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "Hello", itemID: "item-real-delta"),
            turnID: turnID
        ))

        let item = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(item.itemID == "item-real-delta")
        #expect(item.id.rawValue.contains("agent-message-delta") == false)
    }

    @Test("live merge preserves distinct repeated agent messages")
    func liveMergePreservesDistinctRepeatedAgentMessages() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-repeated-agent-messages"))
        let turnID = CodexTurnID(rawValue: "turn-repeated-agent-messages")

        _ = chat.apply(CodexThreadEvent.turnStarted(turnID))
        _ = chat.apply(CodexThreadEvent.itemCompleted(
            agentMessageItem(id: "message-a", text: "OK"),
            turnID: turnID
        ))
        _ = chat.apply(CodexThreadEvent.itemCompleted(
            agentMessageItem(id: "message-b", text: "OK"),
            turnID: turnID
        ))

        #expect(chat.items.map(\.itemID) == ["message-a", "message-b"])
        #expect(chat.items.map(\.text) == ["OK", "OK"])
    }

    @Test("message delta promotes fallback when item ID appears")
    func messageDeltaPromotesFallbackWhenItemIDAppears() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-delta-promotion"))
        let turnID = CodexTurnID(rawValue: "turn-delta-promotion")

        _ = chat.apply(CodexThreadEvent.turnStarted(turnID))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "Hello"),
            turnID: turnID
        ))
        let fallbackItem = try #require(chat.items.first)

        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: " world", itemID: "item-delta-real"),
            turnID: turnID
        ))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "!", itemID: "item-delta-real"),
            turnID: turnID
        ))

        let promotedItem = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(promotedItem === fallbackItem)
        #expect(promotedItem.id == fallbackItem.id)
        #expect(promotedItem.itemID == "item-delta-real")
        #expect(promotedItem.message?.text == "Hello world!")
    }

    @Test("message delta continues promoted fallback after item ID disappears")
    func messageDeltaContinuesPromotedFallbackAfterItemIDDisappears() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-delta-promotion-replay"))
        let turnID = CodexTurnID(rawValue: "turn-delta-promotion-replay")

        _ = chat.apply(CodexThreadEvent.turnStarted(turnID))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "Hello"),
            turnID: turnID
        ))
        let fallbackItem = try #require(chat.items.first)

        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: " world", itemID: "item-delta-real"),
            turnID: turnID
        ))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "!"),
            turnID: turnID
        ))

        let promotedItem = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(promotedItem === fallbackItem)
        #expect(promotedItem.itemID == "item-delta-real")
        #expect(promotedItem.message?.text == "Hello world!")
    }

    @Test("live completed item promotes fallback message delta")
    func liveCompletedItemPromotesFallbackMessageDelta() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-live-promotion"))
        let turnID = CodexTurnID(rawValue: "turn-live-promotion")

        _ = chat.apply(CodexThreadEvent.turnStarted(turnID))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "Live answer"),
            turnID: turnID
        ))
        let fallbackItem = try #require(chat.items.first)

        _ = chat.apply(CodexThreadEvent.itemCompleted(
            agentMessageItem(
                id: "item-live-real",
                text: "Live answer",
                phase: .finalAnswer
            ),
            turnID: turnID
        ))

        let promotedItem = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(promotedItem === fallbackItem)
        #expect(promotedItem.itemID == "item-live-real")
        #expect(promotedItem.message?.phase == .finalAnswer)
    }

    @Test("snapshot refresh promotes fallback item over provisional identity")
    func snapshotRefreshPromotesFallbackItemOverProvisionalIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-snapshot-promotion"))
        let turnID = CodexTurnID(rawValue: "turn-snapshot-promotion")

        _ = chat.apply(CodexThreadEvent.turnStarted(turnID))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "Snapshot answer"),
            turnID: turnID
        ))
        let fallbackItem = try #require(chat.items.first)

        let rawPayload = Data(#"{"id":"item-snapshot-real","type":"agent_message"}"#.utf8)
        chat.apply(
            CodexThreadSnapshot(
                id: chat.id,
                turns: [
                    .init(
                        id: turnID,
                        status: .completed,
                        itemsLoadState: .full,
                        items: [
                            agentMessageItem(
                                id: "agent-message-delta:turn-snapshot-promotion",
                                text: "Snapshot answer"
                            ),
                            agentMessageItem(
                                id: "item-snapshot-real",
                                text: "Snapshot answer",
                                phase: .finalAnswer,
                                rawPayload: rawPayload
                            ),
                        ]
                    ),
                ]
            ),
            workspace: Optional<CodexWorkspace>.none
        )

        let promotedItem = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(promotedItem === fallbackItem)
        #expect(promotedItem.itemID == "item-snapshot-real")
        #expect(promotedItem.rawPayload == rawPayload)
        #expect(promotedItem.message?.phase == .finalAnswer)
    }

    @Test("review markers with the same raw ID keep distinct item identities")
    func reviewMarkersWithSameRawIDKeepDistinctItemIdentities() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-review-marker-identity"))
        let turnID = CodexTurnID(rawValue: "turn-review-marker-identity")

        chat.apply(
            CodexThreadSnapshot(
                id: chat.id,
                turns: [
                    .init(
                        id: turnID,
                        status: .completed,
                        itemsLoadState: .full,
                        items: [
                            reviewMarkerItem(
                                id: "review-marker",
                                kind: .enteredReviewMode,
                                text: "entered"
                            ),
                            reviewMarkerItem(
                                id: "review-marker",
                                kind: .exitedReviewMode,
                                text: "exited"
                            ),
                        ]
                    ),
                ]
            ),
            workspace: Optional<CodexWorkspace>.none
        )

        #expect(chat.items.count == 2)
        #expect(chat.items.map(\.kind) == [.enteredReviewMode, .exitedReviewMode])
        #expect(Set(chat.items.map(\.id)).count == 2)
        #expect(chat.items.map(\.itemID) == ["review-marker", "review-marker"])
    }

    private func agentMessageItem(
        id: String,
        text: String,
        phase: CodexMessagePhase? = nil,
        rawPayload: Data? = nil
    ) -> CodexThreadItem {
        CodexThreadItem(
            id: id,
            kind: .agentMessage,
            content: .message(.init(
                id: id,
                role: .assistant,
                phase: phase,
                text: text
            )),
            rawPayload: rawPayload
        )
    }

    private func reviewMarkerItem(
        id: String,
        kind: CodexThreadItem.Kind,
        text: String
    ) -> CodexThreadItem {
        CodexThreadItem(
            id: id,
            kind: kind,
            content: .log(text)
        )
    }
}
