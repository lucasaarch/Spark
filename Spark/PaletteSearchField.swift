import AppKit
import SwiftUI

/// Handle navigation at the field editor's command boundary, after IME processing.
/// SwiftUI's onMoveCommand does not receive arrows consumed by NSTextField.
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusedPaletteField()
        field.delegate = context.coordinator
        field.placeholderString = "Search actions, workspaces, folders…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("commandPaletteSearch")
        field.setAccessibilityLabel("Search commands")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): parent.move(8)
            case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): parent.move(-8)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}

private final class FocusedPaletteField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
}
