import AppKit
import SwiftUI

/// A native search control in the toolbar's centered principal item.
struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find a machine"
        field.setAccessibilityLabel("Find a machine")
        field.sendsSearchStringImmediately = true
        field.maximumRecents = 0
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest = 0
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private struct FindMachineKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var findMachine: (() -> Void)? {
        get { self[FindMachineKey.self] }
        set { self[FindMachineKey.self] = newValue }
    }
}
