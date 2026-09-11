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
    var onAction: (SearchKeyAction) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
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
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let editor = field.currentEditor() as? NSTextView
        if field.stringValue != text && editor?.hasMarkedText() != true { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
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
