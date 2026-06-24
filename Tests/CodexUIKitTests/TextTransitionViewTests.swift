import AppKit
import Testing
@testable import CodexUIKit

@MainActor
struct TextTransitionViewTests {
    @Test func numericTextAnimatesOnlyChangedNumericGlyphsInMixedText() {
        let view = TextTransitionView(
            text: attributed("files: 8 ok"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )

        view.setText(attributed("files: 9 ok"))

        #expect(view.activeTransitionCountForTesting == 1)
        #expect(view.activeTransitionDirectionsForTesting == [.countingUp])
    }

    @Test func numericTextKeepsOldDigitLayerHiddenAtCompletionValue() {
        let view = TextTransitionView(
            text: attributed("8"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )

        view.setText(attributed("9"))

        #expect(view.activeTransitionOldLayerOpacitiesForTesting == [0])
    }

    @Test func unchangedTextUpdatePreservesActiveTransitions() {
        let view = TextTransitionView(
            text: attributed("8"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        view.setText(attributed("9"))
        #expect(view.activeTransitionCountForTesting == 1)

        view.setText(attributed("9"), animated: false)

        #expect(view.activeTransitionCountForTesting == 1)
    }

    @Test func numericTextCountsDownReversesDirection() {
        let view = TextTransitionView(
            text: attributed("2"),
            contentTransition: .numericText(countsDown: false),
            motionPolicy: .enabled
        )

        view.setText(attributed("3"))
        #expect(view.activeTransitionDirectionsForTesting == [.countingUp])
        view.completeTransitionsForTesting()

        view.contentTransition = .numericText(countsDown: true)
        view.setText(attributed("2"))

        #expect(view.activeTransitionDirectionsForTesting == [.countingDown])
    }

    @Test func numericTextValueDeterminesDirectionFromValueDelta() {
        let view = TextTransitionView(
            text: attributed("10"),
            contentTransition: .numericText(value: 10),
            motionPolicy: .enabled
        )

        view.contentTransition = .numericText(value: 11)
        view.setText(attributed("11"))
        #expect(view.activeTransitionDirectionsForTesting == [.countingUp])
        view.completeTransitionsForTesting()

        view.contentTransition = .numericText(value: 8)
        view.setText(attributed("8"))

        #expect(view.activeTransitionDirectionsForTesting == [.countingDown])
    }

    @Test func sampleWidthReservationStabilizesGrowingNumericText() {
        let sample = attributed("00")
        let view = TextTransitionView(
            text: attributed("9"),
            contentTransition: .numericText(),
            widthReservation: .sample(sample),
            motionPolicy: .enabled
        )
        let initialWidth = view.intrinsicContentSize.width

        view.setText(attributed("10"))

        #expect(view.intrinsicContentSize.width == initialWidth)
        #expect(view.renderedTextWidthForTesting <= view.intrinsicContentSize.width)
    }

    @Test func numericRunGrowthDoesNotReuseOldDigitForInsertedGlyph() {
        let view = TextTransitionView(
            text: attributed("9"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )

        view.setText(attributed("10"))

        #expect(view.activeTransitionCountForTesting == 1)
        #expect(view.activeFadeTransitionCountForTesting == 1)
    }

    @Test func fixedWidthReservationConstrainsFormattedNumericText() {
        let fixedSize = NSSize(width: 96, height: 18)
        let view = TextTransitionView(
            text: attributed("59s"),
            contentTransition: .numericText(),
            widthReservation: .fixed(fixedSize),
            motionPolicy: .enabled
        )

        view.setText(attributed("1m 0s"))

        #expect(view.intrinsicContentSize == fixedSize)
        #expect(view.renderedTextWidthForTesting <= fixedSize.width)
        #expect(view.activeTransitionCountForTesting > 0)
    }

    @Test func numericRunInsertedBeforeExistingRunDoesNotReuseOldDigits() {
        let view = TextTransitionView(
            text: attributed("59s"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )

        view.setText(attributed("1m 0s"))

        #expect(view.activeTransitionGlyphPairsForTesting == ["9->0"])
    }

    @Test func disabledMotionPolicySuppressesNumericTransitions() {
        let view = TextTransitionView(
            text: attributed("1"),
            contentTransition: .numericText(),
            motionPolicy: .disabled
        )

        view.setText(attributed("2"))

        #expect(view.activeTransitionCountForTesting == 0)
    }

    @Test func completeTransitionsStopsOpacityFadeAnimations() {
        let view = TextTransitionView(
            text: attributed("old"),
            contentTransition: .opacity,
            motionPolicy: .enabled
        )

        view.setText(attributed("new"))
        #expect(view.activeFadeTransitionCountForTesting > 0)

        view.completeTransitionsForTesting()

        #expect(view.activeFadeTransitionCountForTesting == 0)
    }

    @Test func attachmentViewProviderLoadsTransitionView() {
        let attachment = TextTransitionAttachment(
            text: attributed("1"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        let provider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(0)
        )

        provider.loadView()

        let view = provider.view as? TextTransitionView
        #expect(view?.text.string == "1")
    }

    @Test func attachmentViewProviderTracksAttachmentBounds() {
        let attachment = TextTransitionAttachment(
            text: attributed("1"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        let provider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(0)
        )

        #expect(provider.tracksTextAttachmentViewBounds)
    }

    @Test func attachmentBoundsPreserveTextFontDescender() {
        let font = NSFont.systemFont(ofSize: 17)
        let attachment = TextTransitionAttachment(
            text: attributed("1", font: font),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )

        let rect = attachment.attachmentBounds(
            for: [:],
            location: TestTextLocation(0),
            textContainer: nil,
            proposedLineFragment: .zero,
            position: .zero
        )

        #expect(attachment.bounds.origin.y == floor(font.descender))
        #expect(rect.origin.y == floor(font.descender))
    }

    @Test func attachmentBoundsUseContextFontWhenTextHasNoFont() {
        let font = NSFont.systemFont(ofSize: 30)
        let attachment = TextTransitionAttachment(
            text: NSAttributedString(string: "99"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )

        let rect = attachment.attachmentBounds(
            for: [.font: font],
            location: TestTextLocation(0),
            textContainer: nil,
            proposedLineFragment: .zero,
            position: .zero
        )
        let expectedText = NSAttributedString(
            string: "99",
            attributes: [.font: font]
        )
        let expectedSize = textTransitionPreferredSize(
            for: expectedText,
            widthReservation: .natural
        )

        #expect(rect.origin.y == floor(font.descender))
        #expect(rect.size == expectedSize)
    }

    @Test func attachmentViewProviderUsesContextFontResolvedByBounds() {
        let font = NSFont.systemFont(ofSize: 30)
        let attachment = TextTransitionAttachment(
            text: NSAttributedString(string: "99"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        let provider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(0)
        )
        let bounds = provider.attachmentBounds(
            for: [.font: font],
            location: TestTextLocation(0),
            textContainer: nil,
            proposedLineFragment: .zero,
            position: .zero
        )

        provider.loadView()

        let view = provider.view as? TextTransitionView
        let resolvedFont = view?.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(resolvedFont == font)
        #expect(view?.intrinsicContentSize == bounds.size)
    }

    @Test func attachmentUpdatesActiveViewsWithTheirOwnContextFonts() {
        let smallFont = NSFont.systemFont(ofSize: 13)
        let largeFont = NSFont.systemFont(ofSize: 30)
        let attachment = TextTransitionAttachment(
            text: NSAttributedString(string: "1"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        let smallProvider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(0)
        )
        _ = smallProvider.attachmentBounds(
            for: [.font: smallFont],
            location: TestTextLocation(0),
            textContainer: nil,
            proposedLineFragment: .zero,
            position: .zero
        )
        smallProvider.loadView()
        let smallView = smallProvider.view as? TextTransitionView

        let largeProvider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(1)
        )
        _ = largeProvider.attachmentBounds(
            for: [.font: largeFont],
            location: TestTextLocation(1),
            textContainer: nil,
            proposedLineFragment: .zero,
            position: .zero
        )
        largeProvider.loadView()
        let largeView = largeProvider.view as? TextTransitionView

        attachment.setText(NSAttributedString(string: "2"), animated: false)

        let resolvedSmallFont = smallView?.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let resolvedLargeFont = largeView?.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(resolvedSmallFont == smallFont)
        #expect(resolvedLargeFont == largeFont)
    }

    @Test func attachmentSetTextUpdatesLoadedTransitionView() {
        let attachment = TextTransitionAttachment(
            text: attributed("1"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        let provider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(0)
        )
        provider.loadView()
        let view = provider.view as? TextTransitionView

        attachment.setText(attributed("2"), animated: true)

        #expect(view?.text.string == "2")
        #expect(view?.activeTransitionCountForTesting == 1)
    }

    @Test func attachmentConfigureUpdatesBoundsAndLoadedTransitionView() {
        let attachment = TextTransitionAttachment(
            text: attributed("1"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        let provider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(0)
        )
        provider.loadView()
        let view = provider.view as? TextTransitionView
        attachment.setText(attributed("2"), animated: true)
        #expect(view?.activeTransitionCountForTesting == 1)
        let fixedSize = NSSize(width: 80, height: 20)

        attachment.configure(
            widthReservation: .fixed(fixedSize),
            motionPolicy: .disabled
        )

        #expect(attachment.bounds.size == fixedSize)
        #expect(view?.intrinsicContentSize == fixedSize)
        #expect(view?.activeTransitionCountForTesting == 0)
    }

    private func attributed(
        _ string: String,
        font: NSFont = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }
}

private final class TestTextLocation: NSObject, NSTextLocation {
    private let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }

    func compare(_ location: any NSTextLocation) -> ComparisonResult {
        guard let other = location as? TestTextLocation else {
            return .orderedSame
        }
        if offset < other.offset {
            return .orderedAscending
        }
        if offset > other.offset {
            return .orderedDescending
        }
        return .orderedSame
    }
}
