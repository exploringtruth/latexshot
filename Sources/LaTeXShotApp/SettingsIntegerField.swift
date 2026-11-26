import AppKit
import SwiftUI

struct SettingsIntegerField: NSViewRepresentable {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let isEnabled: () -> Bool
    var resetCount = 0
    var clampsAboveMaximum = false

    func makeCoordinator() -> Coordinator {
        Coordinator(field: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: String(value))
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.setAccessibilityLabel(title)
        field.formatter = SettingsDigitsFormatter()
        field.delegate = context.coordinator
        field.isEnabled = isEnabled()
        field.textColor = field.isEnabled ? .labelColor : .secondaryLabelColor
        return field
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        context.coordinator.synchronize(view, with: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var field: SettingsIntegerField
        private var displayedValue: Int

        init(field: SettingsIntegerField) {
            self.field = field
            self.displayedValue = field.value
        }

        func synchronize(_ view: NSTextField, with updatedField: SettingsIntegerField) {
            let enabled = updatedField.isEnabled()
            let refresh = displayedValue != updatedField.value
                || view.isEnabled != enabled
                || field.resetCount != updatedField.resetCount
            field = updatedField
            if refresh { showSavedValue(in: view) }
            if view.isEnabled != enabled {
                view.isEnabled = enabled
                view.textColor = enabled ? .labelColor : .secondaryLabelColor
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            commit(view.stringValue, in: view)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let view = control as? NSTextField else { return false }
            commit(textView.string, in: view)
            return true
        }

        private func commit(_ draft: String, in view: NSTextField) {
            if field.isEnabled(), displayedValue == field.value,
               !draft.isEmpty, SettingsDigitsFormatter.accepts(draft),
               let number = committedNumber(from: draft),
               field.range.contains(number), number != field.value {
                field.value = number
            }
            showSavedValue(in: view)
        }

        private func committedNumber(from draft: String) -> Int? {
            guard field.clampsAboveMaximum else { return Int(draft) }
            // Strip leading zeroes before treating an unrepresentable value as overflow.
            let digits = draft.drop(while: { $0 == "0" })
            guard !digits.isEmpty else { return 0 }
            return min(Int(digits) ?? field.range.upperBound, field.range.upperBound)
        }

        private func showSavedValue(in view: NSTextField) {
            displayedValue = field.value
            let text = String(displayedValue)
            if let editor = view.currentEditor(), editor.string != text {
                editor.string = text
                editor.selectedRange = NSRange(location: text.utf16.count, length: 0)
            }
            view.stringValue = text
        }
    }
}

final class SettingsDigitsFormatter: Formatter {
    static func accepts(_ draft: String) -> Bool {
        draft.utf8.allSatisfy { (48...57).contains($0) }
    }

    override func string(for obj: Any?) -> String? {
        obj as? String
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        // The field must be able to end editing even when the draft is empty or out of range.
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        Self.accepts(partialStringPtr.pointee as String)
    }
}
