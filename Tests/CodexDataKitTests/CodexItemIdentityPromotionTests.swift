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

        _ = chat.apply(.completed(CodexResponse(
            turnID: turnID,
            transcript: .init(items: [authoritativeItem])
        )))

        let promotedItem = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(promotedItem === fallbackItem)
        #expect(promotedItem.id == fallbackItem.id)
        #expect(promotedItem.itemID == "item-real")
        #expect(promotedItem.rawPayload == rawPayload)
        #expect(promotedItem.message?.phase == .finalAnswer)
    }

    @Test("ID-less deltas continue snapshot-promoted fallback messages")
    func idlessDeltasContinueSnapshotPromotedFallbackMessages() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-snapshot-promotion"))
        let turnID = CodexTurnID(rawValue: "turn-snapshot-promotion")

        _ = chat.apply(CodexThreadEvent.turnStarted(turnID))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "Hello"),
            turnID: turnID
        ))
        _ = chat.apply(.completed(CodexResponse(
            turnID: turnID,
            transcript: .init(items: [
                agentMessageItem(id: "item-snapshot-real", text: "Hello"),
            ])
        )))
        let promotedItem = try #require(chat.items.first)
        #expect(promotedItem.itemID == "item-snapshot-real")

        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: " world"),
            turnID: turnID
        ))

        #expect(chat.items.count == 1)
        let continuedItem = try #require(chat.items.first)
        #expect(continuedItem === promotedItem)
        #expect(continuedItem.itemID == "item-snapshot-real")
        #expect(continuedItem.message?.text == "Hello world")
    }

    @Test("promotion rekeys the context item registration")
    func promotionRekeysContextItemRegistration() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-context-rekey"))
        let turnID = CodexTurnID(rawValue: "turn-context-rekey")

        _ = chat.apply(CodexThreadEvent.turnStarted(turnID))
        _ = chat.apply(CodexThreadEvent.messageDelta(
            CodexMessageDelta(text: "Hello"),
            turnID: turnID
        ))
        let fallbackItem = try #require(chat.items.first)
        let fallbackThreadItem = agentMessageItem(
            id: try #require(fallbackItem.itemID),
            text: "Hello"
        )

        _ = chat.apply(.completed(CodexResponse(
            turnID: turnID,
            transcript: .init(items: [
                agentMessageItem(id: "item-context-real", text: "Hello"),
            ])
        )))
        let promotedItem = try #require(chat.items.first)
        #expect(promotedItem.itemID == "item-context-real")

        let staleLookup = context.item(
            threadItem: fallbackThreadItem,
            turnID: turnID,
            in: chat,
            itemsLoadState: .full
        )
        #expect(staleLookup !== promotedItem)
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
                        state: .completed,
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

    @Test("review marker identity retains raw ID and kind")
    func reviewMarkerIdentityRetainsRawIDAndKind() async throws {
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
                        state: .completed,
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
                            reviewMarkerItem(
                                id: "8f80d976-f70d-4d37-af93-f8ba57fb802f",
                                kind: .enteredReviewMode,
                                text: "entered again"
                            ),
                        ]
                    ),
                ]
            ),
            workspace: Optional<CodexWorkspace>.none
        )

        #expect(chat.items.count == 3)
        #expect(chat.items.map(\.kind) == [
            .enteredReviewMode,
            .exitedReviewMode,
            .enteredReviewMode,
        ])
        #expect(Set(chat.items.map(\.id)).count == 3)
        #expect(chat.items.map(\.itemID) == [
            "review-marker",
            "review-marker",
            "8f80d976-f70d-4d37-af93-f8ba57fb802f",
        ])
        #expect(chat.items.map(\.id.rawValue) == [
            "turn-review-marker-identity:enteredReviewMode:review-marker",
            "turn-review-marker-identity:exitedReviewMode:review-marker",
            "turn-review-marker-identity:enteredReviewMode:8f80d976-f70d-4d37-af93-f8ba57fb802f",
        ])
        let locators = chat.items.map {
            CodexChatItemLocator(
                id: $0.itemID,
                kind: $0.kind,
                turnID: turnID
            )
        }
        #expect(Set(locators).count == 3)
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
