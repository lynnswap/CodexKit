import AppKit

public final class TextTransitionAttachment: NSTextAttachment {
    public private(set) var text: NSAttributedString
    public private(set) var contentTransition: TextTransition.Content
    public private(set) var widthReservation: TextTransition.WidthReservation
    public private(set) var motionPolicy: TextTransition.MotionPolicy
    public var reuseIdentifier: String?
    private let activeViews = NSHashTable<TextTransitionView>.weakObjects()
    private var inheritedAttributes: [NSAttributedString.Key: Any] = [:]

    public init(
        text: NSAttributedString,
        contentTransition: TextTransition.Content = .numericText(),
        widthReservation: TextTransition.WidthReservation = .natural,
        motionPolicy: TextTransition.MotionPolicy = .system,
        reuseIdentifier: String? = nil
    ) {
        self.text = text.copy() as? NSAttributedString ?? text
        self.contentTransition = contentTransition
        self.widthReservation = widthReservation
        self.motionPolicy = motionPolicy
        self.reuseIdentifier = reuseIdentifier
        super.init(data: nil, ofType: nil)

        allowsTextAttachmentView = true
        lineLayoutPadding = 0
        updateBounds()
    }

    @MainActor
    public func configure(
        contentTransition: TextTransition.Content? = nil,
        widthReservation: TextTransition.WidthReservation? = nil,
        motionPolicy: TextTransition.MotionPolicy? = nil
    ) {
        var shouldUpdateBounds = false
        if let contentTransition, self.contentTransition != contentTransition {
            self.contentTransition = contentTransition
        }
        if let widthReservation, self.widthReservation != widthReservation {
            self.widthReservation = widthReservation
            shouldUpdateBounds = true
        }
        if let motionPolicy, self.motionPolicy != motionPolicy {
            self.motionPolicy = motionPolicy
        }
        if shouldUpdateBounds {
            updateBounds()
        }
        updateActiveViews(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @MainActor
    public func setText(_ text: NSAttributedString, animated: Bool = true) {
        self.text = text.copy() as? NSAttributedString ?? text
        updateBounds()
        updateActiveViews(animated: animated)
    }

    override public func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        position: CGPoint
    ) -> CGRect {
        bounds(for: attributes)
    }

    override public func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        TextTransitionAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }

    override public func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSImage? {
        Self.transparentImage
    }

    private func updateBounds() {
        bounds = resolvedBounds(for: inheritedAttributes)
    }

    @discardableResult
    fileprivate func updateInheritedAttributes(
        _ attributes: [NSAttributedString.Key: Any]
    ) -> CGRect {
        inheritedAttributes = attributes.textTransitionRenderableAttributes
        updateBounds()
        return bounds
    }

    fileprivate func resolvedTextForView() -> NSAttributedString {
        text.resolvingMissingAttributes(from: inheritedAttributes)
    }

    fileprivate func resolvedWidthReservationForView() -> TextTransition.WidthReservation {
        widthReservation.resolvingMissingAttributes(from: inheritedAttributes)
    }

    fileprivate func bounds(for attributes: [NSAttributedString.Key: Any]) -> CGRect {
        updateInheritedAttributes(attributes)
    }

    private func resolvedBounds(for attributes: [NSAttributedString.Key: Any]) -> CGRect {
        let resolvedText = text.resolvingMissingAttributes(from: attributes)
        let resolvedWidthReservation = widthReservation.resolvingMissingAttributes(from: attributes)
        let size = textTransitionPreferredSize(
            for: resolvedText,
            widthReservation: resolvedWidthReservation
        )
        return CGRect(
            x: bounds.origin.x,
            y: baselineOffset(for: resolvedText, attributes: attributes),
            width: size.width,
            height: size.height
        )
    }

    private func baselineOffset(attributes: [NSAttributedString.Key: Any] = [:]) -> CGFloat {
        baselineOffset(
            for: text.resolvingMissingAttributes(from: attributes),
            attributes: attributes
        )
    }

    private func baselineOffset(
        for resolvedText: NSAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let descender = textTransitionFontDescender(in: resolvedText) ??
            (attributes[.font] as? NSFont)?.descender ??
            0
        return floor(descender)
    }

    @MainActor
    fileprivate func registerActiveView(_ transitionView: TextTransitionView) {
        activeViews.add(transitionView)
    }

    @MainActor
    private func updateActiveViews(animated: Bool) {
        for transitionView in activeViews.allObjects {
            transitionView.configure(
                text: resolvedTextForView(),
                contentTransition: contentTransition,
                widthReservation: resolvedWidthReservationForView(),
                motionPolicy: motionPolicy,
                animated: animated
            )
        }
    }

    private static let transparentImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }()
}

private extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    var textTransitionRenderableAttributes: [NSAttributedString.Key: Any] {
        filter { key, _ in key != .attachment }
    }
}

private extension NSAttributedString {
    func resolvingMissingAttributes(from attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let inheritedAttributes = attributes.textTransitionRenderableAttributes
        guard inheritedAttributes.isEmpty == false, length > 0 else {
            return self
        }

        let resolvedText = NSMutableAttributedString(attributedString: self)
        let fullRange = NSRange(location: 0, length: length)
        for (key, value) in inheritedAttributes {
            resolvedText.enumerateAttribute(key, in: fullRange) { existingValue, range, _ in
                if existingValue == nil {
                    resolvedText.addAttribute(key, value: value, range: range)
                }
            }
        }
        return resolvedText
    }
}

private extension TextTransition.WidthReservation {
    func resolvingMissingAttributes(
        from attributes: [NSAttributedString.Key: Any]
    ) -> TextTransition.WidthReservation {
        switch self {
        case .natural, .fixed:
            return self
        case .sample(let sample):
            return .sample(sample.resolvingMissingAttributes(from: attributes))
        }
    }
}

@MainActor
public final class TextTransitionAttachmentViewProvider: NSTextAttachmentViewProvider {
    private var transitionView: TextTransitionView?

    override public init(
        textAttachment: NSTextAttachment,
        parentView: NSView?,
        textLayoutManager: NSTextLayoutManager?,
        location: any NSTextLocation
    ) {
        super.init(
            textAttachment: textAttachment,
            parentView: parentView,
            textLayoutManager: textLayoutManager,
            location: location
        )
        tracksTextAttachmentViewBounds = true
    }

    override public func loadView() {
        nonisolated(unsafe) let provider = self
        let loadedView = MainActor.assumeIsolated {
            provider.configureView(animated: false) ?? NSView(frame: .zero)
        }
        view = loadedView
    }

    public func configureView(animated: Bool = false) -> TextTransitionView? {
        guard let attachment = textAttachment as? TextTransitionAttachment else {
            return nil
        }
        let renderingAttributes = renderingAttributes()
        if renderingAttributes.textTransitionRenderableAttributes.isEmpty == false {
            attachment.updateInheritedAttributes(renderingAttributes)
        }

        if let transitionView {
            attachment.registerActiveView(transitionView)
            transitionView.configure(
                text: attachment.resolvedTextForView(),
                contentTransition: attachment.contentTransition,
                widthReservation: attachment.resolvedWidthReservationForView(),
                motionPolicy: attachment.motionPolicy,
                animated: animated
            )
            return transitionView
        }

        let transitionView = TextTransitionView(
            text: attachment.resolvedTextForView(),
            contentTransition: attachment.contentTransition,
            widthReservation: attachment.resolvedWidthReservationForView(),
            motionPolicy: attachment.motionPolicy
        )
        self.transitionView = transitionView
        attachment.registerActiveView(transitionView)
        return transitionView
    }

    override public func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let attachment = textAttachment as? TextTransitionAttachment else {
            return super.attachmentBounds(
                for: attributes,
                location: location,
                textContainer: textContainer,
                proposedLineFragment: lineFrag,
                position: position
            )
        }
        return attachment.bounds(for: attributes)
    }

    private func renderingAttributes() -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any]?
        textLayoutManager?.enumerateRenderingAttributes(
            from: location,
            reverse: false
        ) { _, attributes, _ in
            result = attributes
            return false
        }
        return result ?? [:]
    }
}
