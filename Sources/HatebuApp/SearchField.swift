import SwiftUI
import AppKit

enum SearchKeyAction: Equatable {
    case previous, next, open
    static func resolve(_ command: String, hasMarkedText: Bool) -> Self? {
        guard !hasMarkedText else { return nil }
        switch command {
        case "moveUp:": return .previous
        case "moveDown:": return .next
        case "insertNewline:": return .open
        default: return nil
        }
    }
}

/// Let the field editor handle IME composition before routing result navigation.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var allowsFocus = true
    var onAction: (SearchKeyAction) -> Void

    func makeNSView(context: Context) -> OpeningSearchTextField {
        let field = OpeningSearchTextField()
        field.allowsFocus = allowsFocus
        field.placeholderString = "覚えている言葉から検索"
        field.font = .systemFont(ofSize: 20, weight: .medium)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.isEditable = true; field.isSelectable = true
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("ブックマークを検索")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: OpeningSearchTextField, context: Context) {
        context.coordinator.parent = self
        field.allowsFocus = allowsFocus
        let editor = field.currentEditor() as? NSTextView
        if field.stringValue != text && editor?.hasMarkedText() != true { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.requestSearchFocus()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var focusRequest: Int
        init(_ parent: SearchField) { self.parent = parent; self.focusRequest = parent.focusRequest }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let action = SearchKeyAction.resolve(NSStringFromSelector(selector), hasMarkedText: textView.hasMarkedText()) else { return false }
            parent.onAction(action)
            return true
        }
    }
}

/// Focus only after the field belongs to the active window. An onAppear request
/// alone can run before AppKit has attached the field to its window.
final class OpeningSearchTextField: NSTextField {
    var allowsFocus = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        guard let window else { return }
        window.initialFirstResponder = self
        center.addObserver(self, selector: #selector(requestSearchFocus), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(requestSearchFocus), name: NSApplication.didBecomeActiveNotification, object: nil)
        requestSearchFocus()
    }

    @objc func requestSearchFocus() {
        // AppKit first restores the old responder when a window becomes key.
        // Apply our choice after that, and recheck sheets and the active window.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.allowsFocus, NSApp.isActive, let window = self.window,
                  window.isKeyWindow, window.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return }
            // Preserve the insertion point and any ongoing IME composition.
            if self.currentEditor() == nil { window.makeFirstResponder(self) }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
