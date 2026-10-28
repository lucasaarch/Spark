import SwiftUI
import Highlighter

extension NSAttributedString.Key {
    static let reviewKind = NSAttributedString.Key("SparkReviewKind")
    static let oldLine = NSAttributedString.Key("SparkOldLine")
    static let newLine = NSAttributedString.Key("SparkNewLine")
}

/// Immutable attributed text may safely cross from the rendering actor to AppKit.
struct RenderedReview: @unchecked Sendable {
    let id = UUID()
    let text: NSAttributedString
    let document: ReviewDocument
}

actor ReviewRenderer {
    static let shared = ReviewRenderer()
    private let highlighter: Highlighter? = {
        let value = Highlighter()
        _ = value?.setTheme("tokyo-night-dark", withFont: "Menlo-Regular", ofSize: 12)
        return value
    }()

    func render(patch: String, path: String, old: String?, new: String?) -> RenderedReview {
        let document = ReviewDocument(patch: patch)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let foreground = NSColor(srgbRed: 0.82, green: 0.84, blue: 0.89, alpha: 1)
        let language = Self.language(path)
        func highlightedLines(_ source: String?) -> [NSAttributedString] {
            guard let source, source.utf8.count <= 524_288,
                source.lazy.filter({ $0 == "\n" }).prefix(20_001).count <= 20_000
            else { return [] }
            let highlighted =
                language.flatMap { highlighter?.highlight(source, as: $0) }
                ?? NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: foreground])
            let text = source as NSString
            guard highlighted.string == source else { return [] }
            var result: [NSAttributedString] = []
            var offset = 0
            for line in source.components(separatedBy: "\n") {
                let length = (line as NSString).length
                if offset + length <= text.length {
                    result.append(highlighted.attributedSubstring(from: NSRange(location: offset, length: length)))
                }
                offset += length + 1
            }
            return result
        }
        let oldLines = highlightedLines(old), newLines = highlightedLines(new)
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20; paragraph.maximumLineHeight = 20
        paragraph.defaultTabInterval = 28
        for line in document.lines {
            let value = NSMutableAttributedString(
                string: line.text, attributes: [.font: font, .foregroundColor: foreground])
            let number = line.kind == .removed ? line.oldNumber : line.newNumber
            let source = line.kind == .removed ? oldLines : newLines
            if let number, number > 0, source.indices.contains(number - 1), source[number - 1].string == line.text {
                value.setAttributedString(source[number - 1])
            } else if document.lines.count <= 2_000, line.kind != .separator, let language, line.text.utf8.count < 8192,
                let highlighted = highlighter?.highlight(line.text, as: language), highlighted.string == line.text {
                value.setAttributedString(highlighted)
            }
            if line.kind == .separator {
                value.addAttribute(
                    .foregroundColor, value: NSColor(srgbRed: 0.42, green: 0.46, blue: 0.54, alpha: 1),
                    range: NSRange(location: 0, length: value.length))
            }
            value.append(NSAttributedString(string: "\n"))
            let range = NSRange(location: 0, length: value.length)
            value.removeAttribute(.backgroundColor, range: range)
            value.addAttributes(
                [.font: font, .paragraphStyle: paragraph, .reviewKind: line.kind.rawValue], range: range)
            if let number = line.oldNumber { value.addAttribute(.oldLine, value: number, range: range) }
            if let number = line.newNumber { value.addAttribute(.newLine, value: number, range: range) }
            result.append(value)
        }
        return RenderedReview(text: NSAttributedString(attributedString: result), document: document)
    }

    static func language(_ path: String) -> String? {
        let file = URL(fileURLWithPath: path)
        if file.lastPathComponent == "Dockerfile" { return "dockerfile" }
        if file.lastPathComponent == "Makefile" { return "makefile" }
        return [
            "swift": "swift", "rs": "rust", "js": "javascript", "jsx": "javascript", "mjs": "javascript",
            "ts": "typescript", "tsx": "typescript", "py": "python", "go": "go", "c": "c", "h": "c",
            "cpp": "cpp", "hpp": "cpp", "m": "objectivec", "mm": "objectivec", "java": "java", "kt": "kotlin",
            "rb": "ruby", "php": "php", "sh": "bash", "zsh": "bash", "bash": "bash", "json": "json",
            "yaml": "yaml", "yml": "yaml", "toml": "ini", "ini": "ini", "css": "css", "scss": "scss",
            "html": "xml", "xml": "xml", "svg": "xml", "md": "markdown", "sql": "sql", "lua": "lua",
            "cs": "csharp", "ex": "elixir", "exs": "elixir", "dart": "dart"
        ][file.pathExtension.lowercased()]
    }
}

struct CodeReviewView: NSViewRepresentable {
    let rendered: RenderedReview
    var fileID = ""
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var renderedID: UUID?
        var fileID: String?
    }

    func makeNSView(context: Context) -> ReviewCodeContainer { ReviewCodeContainer() }

    func updateNSView(_ view: ReviewCodeContainer, context: Context) {
        guard context.coordinator.renderedID != rendered.id || context.coordinator.fileID != fileID else { return }
        let text = view.textView
        let sameFile = context.coordinator.fileID == fileID
        let position = sameFile ? view.scroll.contentView.bounds.origin : .zero
        let selection = sameFile ? text.selectedRange() : NSRange(location: 0, length: 0)
        context.coordinator.renderedID = rendered.id
        context.coordinator.fileID = fileID
        text.textStorage?.setAttributedString(rendered.text)
        let length = text.textStorage?.length ?? 0
        text.setSelectedRange(
            NSRange(
                location: min(selection.location, length),
                length: min(selection.length, max(0, length - selection.location))))
        view.pendingPosition = position
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.gutter.needsDisplay = true
    }
}

/// The gutter is a sibling of the scroll view, never an overlay on the code.
/// This keeps AppKit's automatic ruler insets out of file switching and resizing.
final class ReviewCodeContainer: NSView {
    let scroll = NSScrollView()
    let textView: NSTextView
    let gutter: NSView
    var pendingPosition: NSPoint?
    private var scrollObservation: NSObjectProtocol?

    override init(frame: NSRect) {
        let storage = NSTextStorage(), layout = ReviewLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        gutter = ReviewLineGutter(textView: textView)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(srgbRed: 0.055, green: 0.063, blue: 0.078, alpha: 1)
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.isRichText = false; textView.usesFindPanel = true
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = true; textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Code diff")
        scroll.documentView = textView
        addSubview(scroll)
        addSubview(gutter)
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main
        ) { [weak gutter] _ in gutter?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = min(60, bounds.width)
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        scroll.tile()
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            let size = layout.usedRect(for: container).size
            textView.setFrameSize(
                NSSize(
                    width: max(scroll.contentSize.width, ceil(size.width)),
                    height: max(scroll.contentSize.height, ceil(size.height))))
        }
        if let pendingPosition {
            scroll.contentView.scroll(to: pendingPosition)
            self.pendingPosition = nil
        }
        scroll.reflectScrolledClipView(scroll.contentView)
        gutter.needsDisplay = true
    }

    deinit {
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
    }
}

/// Draw backgrounds for visible line fragments only; gutters are not copied.
private final class ReviewLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, container, glyphRange, _ in
            let index = self.characterIndexForGlyph(at: glyphRange.location)
            guard index < storage.length,
                let kind = storage.attribute(.reviewKind, at: index, effectiveRange: nil) as? Int
            else { return }
            let color: NSColor?
            switch kind {
            case ReviewLine.Kind.added.rawValue: color = NSColor(srgbRed: 0.23, green: 0.72, blue: 0.43, alpha: 0.12)
            case ReviewLine.Kind.removed.rawValue: color = NSColor(srgbRed: 0.94, green: 0.32, blue: 0.36, alpha: 0.12)
            case ReviewLine.Kind.separator.rawValue: color = NSColor.white.withAlphaComponent(0.025)
            default: color = nil
            }
            if let color {
                color.setFill()
                NSRect(
                    x: 0, y: rect.minY + origin.y, width: container.textView?.bounds.width ?? rect.width,
                    height: rect.height
                ).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

private final class ReviewLineGutter: NSView {
    weak var textView: NSTextView?
    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ rect: NSRect) {
        NSColor(srgbRed: 0.065, green: 0.075, blue: 0.09, alpha: 1).setFill(); bounds.fill()
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer,
            let storage = text.textStorage
        else { return }
        let visible = NSRect(x: 0, y: text.visibleRect.minY, width: text.bounds.width, height: text.visibleRect.height)
        let range = layout.glyphRange(forBoundingRect: visible, in: container)
        let style = NSMutableParagraphStyle(); style.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.43, green: 0.47, blue: 0.55, alpha: 1), .paragraphStyle: style
        ]
        layout.enumerateLineFragments(forGlyphRange: range) { line, _, _, glyphs, _ in
            let index = layout.characterIndexForGlyph(at: glyphs.location)
            guard index < storage.length else { return }
            let y = self.convert(NSPoint(x: 0, y: line.minY + text.textContainerOrigin.y), from: text).y + 3
            for (key, x) in [(NSAttributedString.Key.oldLine, CGFloat(2)), (.newLine, CGFloat(30))] {
                if let number = storage.attribute(key, at: index, effectiveRange: nil) as? Int {
                    (String(number) as NSString).draw(
                        in: NSRect(x: x, y: y, width: 26, height: 18), withAttributes: attributes)
                }
            }
        }
    }
}
