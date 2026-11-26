import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let captureEquation = Self("captureEquation", initial: .init(.l, modifiers: [.command, .shift]))
    static let openSettings = Self("openSettings")
    static let showEquationHistory = Self("showEquationHistory")
}

extension ClipboardFormat {
    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .raw: Self.rawShortcut
        case .inlineMarkdown: Self.inlineMarkdownShortcut
        case .displayMarkdown: Self.displayMarkdownShortcut
        case .inlineLaTeX: Self.inlineLaTeXShortcut
        case .displayLaTeX: Self.displayLaTeXShortcut
        case .custom: Self.customShortcut
        }
    }

    private static let rawShortcut = KeyboardShortcuts.Name("clipboardFormatRaw")
    private static let inlineMarkdownShortcut = KeyboardShortcuts.Name("clipboardFormatInlineMarkdown")
    private static let displayMarkdownShortcut = KeyboardShortcuts.Name("clipboardFormatDisplayMarkdown")
    private static let inlineLaTeXShortcut = KeyboardShortcuts.Name("clipboardFormatInlineLaTeX")
    private static let displayLaTeXShortcut = KeyboardShortcuts.Name("clipboardFormatDisplayLaTeX")
    private static let customShortcut = KeyboardShortcuts.Name("clipboardFormatCustom")
}

@MainActor
final class AppShortcuts: ObservableObject {
    @Published private(set) var assignedFormats: [ClipboardFormat] = []

    init() {
        assignmentsDidChange()
    }

    func assignmentsDidChange() {
        assignedFormats = ClipboardFormat.allCases.filter { $0.shortcutName.shortcut != nil }
    }

    func resetToDefaults() {
        let optionalNames = [.openSettings, .showEquationHistory] + ClipboardFormat.allCases.map(\.shortcutName)
        KeyboardShortcuts.reset(optionalNames)
        KeyboardShortcuts.reset(.captureEquation)
        assignmentsDidChange()
    }

    func conflict(for shortcut: KeyboardShortcuts.Shortcut, excluding name: KeyboardShortcuts.Name) -> String? {
        let actions: [(name: KeyboardShortcuts.Name, title: String)] = [
            (.captureEquation, "Capture Equation"),
            (.openSettings, "Open Settings"),
            (.showEquationHistory, "Show Equation History")
        ] + ClipboardFormat.allCases.map { ($0.shortcutName, $0.rawValue) }

        guard let action = actions.first(where: { $0.name != name && $0.name.shortcut == shortcut }) else {
            return nil
        }
        return "This shortcut is already used by “\(action.title)”."
    }
}
