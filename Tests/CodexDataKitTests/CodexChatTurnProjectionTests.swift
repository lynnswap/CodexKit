import CodexAppServerKit
import CodexDataKit
import Testing

struct CodexChatTurnProjectionTests {
    @Test("chat turn projection snapshots latest and explicit turns")
    func snapshotsLatestAndExplicitTurns() {
        var latestProjection = CodexChatTurnProjection()
        let latestUpdate = latestProjection.apply(.snapshot(chatSnapshot(
            turns: [
                turn("turn-1", status: .completed),
                turn("turn-2", status: .running),
            ],
            items: [
                messageItem("message-1", turnID: "turn-1", text: "First"),
                messageItem("message-2", turnID: "turn-2", text: "Second"),
            ]
        )))

        #expect(latestUpdate.affectsSelectedTurn)
        #expect(latestProjection.selectedTurnID == turnID("turn-2"))
        #expect(latestProjection.snapshot?.items.map(\.text) == ["Second"])

        var explicitProjection = CodexChatTurnProjection(selection: .turn(turnID("turn-1")))
        explicitProjection.apply(.snapshot(chatSnapshot(
            turns: [
                turn("turn-1", status: .completed),
                turn("turn-2", status: .running),
            ],
            items: [
                messageItem("message-1", turnID: "turn-1", text: "First"),
                messageItem("message-2", turnID: "turn-2", text: "Second"),
            ]
        )))

        #expect(explicitProjection.selectedTurnID == turnID("turn-1"))
        #expect(explicitProjection.snapshot?.items.map(\.text) == ["First"])
        #expect(explicitProjection.snapshot?.transcript.finalAnswer == "First")
    }

    @Test("chat turn projection updates selected items from text append changes")
    func updatesSelectedItemsFromTextAppendChanges() {
        var projection = CodexChatTurnProjection(selection: .turn(turnID("turn-1")))
        projection.apply(.snapshot(chatSnapshot(
            turns: [turn("turn-1", status: .running)],
            items: [messageItem("message-1", turnID: "turn-1", text: "Hel")]
        )))

        let updatedItem = messageItem("message-1", turnID: "turn-1", text: "Hello")
        let update = projection.apply(.itemTextAppended(
            id: "message-1",
            turnID: turnID("turn-1"),
            delta: "lo",
            item: updatedItem
        ))

        #expect(update.affectsSelectedTurn)
        #expect(update.kind == .itemTextAppended(id: "message-1", turnID: turnID("turn-1"), delta: "lo", item: updatedItem))
        #expect(update.snapshot?.items.map(\.text) == ["Hello"])
    }

    @Test("chat turn projection leaves explicit selection stable when other turns change")
    func leavesExplicitSelectionStableWhenOtherTurnsChange() {
        var projection = CodexChatTurnProjection(selection: .turn(turnID("turn-1")))
        projection.apply(.snapshot(chatSnapshot(
            turns: [
                turn("turn-1", status: .running),
                turn("turn-2", status: .running),
            ],
            items: [
                messageItem("message-1", turnID: "turn-1", text: "Selected"),
                messageItem("message-2", turnID: "turn-2", text: "Other"),
            ]
        )))

        let update = projection.apply(.itemUpdated(messageItem("message-2", turnID: "turn-2", text: "Other updated")))

        #expect(update.affectsSelectedTurn == false)
        #expect(update.snapshot?.items.map(\.text) == ["Selected"])
    }

    @Test("chat turn projection removes selected turn items")
    func removesSelectedTurnItems() {
        var projection = CodexChatTurnProjection(selection: .turn(turnID("turn-1")))
        projection.apply(.snapshot(chatSnapshot(
            turns: [turn("turn-1", status: .running)],
            items: [
                messageItem("message-1", turnID: "turn-1", text: "First"),
                messageItem("message-2", turnID: "turn-1", text: "Second"),
            ]
        )))

        let update = projection.apply(.itemRemoved(id: "message-1", turnID: turnID("turn-1")))

        #expect(update.affectsSelectedTurn)
        #expect(update.snapshot?.items.map(\.id) == ["message-2"])
    }
}

private func chatSnapshot(
    turns: [CodexChatTurnStateSnapshot],
    items: [CodexChatItemSnapshot]
) -> CodexChatSnapshot {
    CodexChatSnapshot(
        chatID: CodexThreadID(rawValue: "thread-1"),
        phase: .loaded,
        turns: turns,
        items: items
    )
}

private func turn(
    _ rawValue: String,
    status: CodexTurnStatus?
) -> CodexChatTurnStateSnapshot {
    CodexChatTurnStateSnapshot(id: turnID(rawValue), status: status)
}

private func messageItem(
    _ id: String,
    turnID rawTurnID: String,
    text: String
) -> CodexChatItemSnapshot {
    CodexChatItemSnapshot(
        id: id,
        turnID: turnID(rawTurnID),
        kind: .agentMessage,
        content: .message(.init(
            id: id,
            role: .assistant,
            phase: .finalAnswer,
            text: text
        ))
    )
}

private func turnID(_ rawValue: String) -> CodexTurnID {
    CodexTurnID(rawValue: rawValue)
}
