import AppKit
import CoreGraphics
import EquationRecognition
import Foundation
import KeyboardShortcuts
import SwiftUI
import Testing
@testable import LaTeXShotApp

@MainActor
@Suite(.serialized)
struct AppShortcutTests {
    @Test func recordsChangesClearsAndRejectsConflicts() throws {
        let capture = KeyboardShortcuts.Name.captureEquation
        let settings = KeyboardShortcuts.Name.openSettings
        let history = KeyboardShortcuts.Name.showEquationHistory
        let raw = ClipboardFormat.raw.shortcutName
        let custom = ClipboardFormat.custom.shortcutName
        let optionalNames = [settings, history] + ClipboardFormat.allCases.map(\.shortcutName)
        let saved = ([capture] + optionalNames).map { ($0, $0.shortcut) }
        defer {
            for (name, shortcut) in saved {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
            }
        }

        #expect(Set(optionalNames).count == 8)
        #expect(optionalNames.allSatisfy { $0.initialShortcut == nil })
        let captureDefault = try #require(capture.initialShortcut)
        #expect(captureDefault == .init(.l, modifiers: [.command, .shift]))
        KeyboardShortcuts.reset(optionalNames)
        KeyboardShortcuts.reset(capture)

        let shortcuts = AppShortcuts()
        let first = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option, .command])
        let second = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option, .command])
        #expect(shortcuts.assignedFormats.isEmpty)
        #expect(shortcuts.conflict(for: captureDefault, excluding: raw)?.contains("Capture Equation") == true)

        KeyboardShortcuts.setShortcut(first, for: raw)
        shortcuts.assignmentsDidChange()
        #expect(shortcuts.assignedFormats == [.raw])
        #expect(shortcuts.conflict(for: first, excluding: raw) == nil)
        #expect(shortcuts.conflict(for: first, excluding: settings)?.contains("Raw LaTeX") == true)

        KeyboardShortcuts.setShortcut(second, for: raw)
        KeyboardShortcuts.setShortcut(first, for: settings)
        shortcuts.assignmentsDidChange()
        #expect(shortcuts.assignedFormats == [.raw])
        #expect(raw.shortcut == second)
        #expect(shortcuts.conflict(for: first, excluding: custom)?.contains("Open Settings") == true)
        #expect(shortcuts.conflict(for: second, excluding: capture)?.contains("Raw LaTeX") == true)

        KeyboardShortcuts.setShortcut(nil, for: raw)
        shortcuts.assignmentsDidChange()
        #expect(shortcuts.assignedFormats.isEmpty)

        #expect(shortcuts.conflict(for: first, excluding: history)?.contains("Open Settings") == true)
        KeyboardShortcuts.setShortcut(second, for: history)
        #expect(shortcuts.conflict(for: second, excluding: history) == nil)
        #expect(shortcuts.conflict(for: second, excluding: raw)?.contains("Show Equation History") == true)
        KeyboardShortcuts.setShortcut(nil, for: history)
        #expect(shortcuts.conflict(for: second, excluding: raw) == nil)
    }

    @Test func resetsAllShortcutsWhenAFormatOccupiesTheCaptureDefault() throws {
        let capture = KeyboardShortcuts.Name.captureEquation
        let peers = [.openSettings, .showEquationHistory] + ClipboardFormat.allCases.map(\.shortcutName)
        let saved = ([capture] + peers).map { ($0, $0.shortcut) }
        defer {
            for (name, shortcut) in saved {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
            }
        }

        let defaultCapture = try #require(capture.initialShortcut)
        KeyboardShortcuts.setShortcut(.init(.k, modifiers: [.control, .option, .command]), for: capture)
        for (name, key) in zip(peers, [KeyboardShortcuts.Key.a, .b, .c, .d, .e, .f, .g]) {
            KeyboardShortcuts.setShortcut(.init(key, modifiers: [.control, .option, .command]), for: name)
        }
        KeyboardShortcuts.setShortcut(defaultCapture, for: ClipboardFormat.custom.shortcutName)
        let shortcuts = AppShortcuts()
        #expect(shortcuts.assignedFormats == ClipboardFormat.allCases)
        #expect(shortcuts.conflict(for: defaultCapture, excluding: capture)?.contains("Custom") == true)

        shortcuts.resetToDefaults()

        #expect(capture.shortcut == .init(.l, modifiers: [.command, .shift]))
        #expect(peers.allSatisfy { $0.shortcut == nil })
        #expect(shortcuts.assignedFormats.isEmpty)
    }

    @available(macOS 26.0, *)
    @Test func nativeFormatMenuKeepsIndentShortcutsAndUpdatesBoldTitle() async throws {
        _ = NSApplication.shared
        let names = ClipboardFormat.allCases.map(\.shortcutName)
        let saved = names.map { ($0, $0.shortcut) }
        defer {
            for (name, shortcut) in saved {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
            }
        }
        KeyboardShortcuts.reset(names)
        KeyboardShortcuts.setShortcut(.init(.r, modifiers: [.control, .option]), for: ClipboardFormat.raw.shortcutName)
        KeyboardShortcuts.setShortcut(.init(.m, modifiers: [.control, .option]), for: ClipboardFormat.inlineMarkdown.shortcutName)
        let suiteName = "LaTeXShot.MenuTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)
        let shortcuts = AppShortcuts()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let runtime = AppRuntime(recognizer: UnusedRecognizer(), preferences: preferences, pasteboard: pasteboard)
        let menu = NSHostingMenu(rootView: ClipboardFormatMenuItems(
            preferences: preferences, shortcuts: shortcuts, select: runtime.selectClipboardFormat
        ))

        func titles() -> [String] {
            menu.items.map { $0.attributedTitle?.string ?? $0.title }
        }
        func isBold(_ item: NSMenuItem) -> Bool {
            guard let title = item.attributedTitle, title.length > 0,
                  let font = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return false }
            return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }

        menu.update()
        #expect(titles() == [" Raw LaTeX", " Inline Markdown"])
        try #require(menu.items.count == 2)
        #expect(menu.items.map(\.keyEquivalent) == ["r", "m"])
        #expect(menu.items.map(\.keyEquivalentModifierMask) == [[.control, .option], [.control, .option]])
        #expect(isBold(menu.items[0]))
        #expect(!isBold(menu.items[1]))

        menu.performActionForItem(at: 1)
        #expect(preferences.clipboardFormat == .inlineMarkdown)
        try await Task.sleep(for: .milliseconds(50))
        menu.update()
        #expect(isBold(menu.items[1]))
        #expect(!isBold(menu.items[0]))

        runtime.selectClipboardFormat(.raw)
        try await Task.sleep(for: .milliseconds(50))
        menu.update()
        #expect(isBold(menu.items[0]))
        #expect(!isBold(menu.items[1]))

        preferences.clipboardFormat = .displayLaTeX
        try await Task.sleep(for: .milliseconds(50))
        menu.update()
        #expect(!isBold(menu.items[0]))
        #expect(!isBold(menu.items[1]))

        try runtime.copyEquation("x")
        let changeCount = pasteboard.changeCount
        shortcuts.resetToDefaults()
        try await Task.sleep(for: .milliseconds(50))
        menu.update()
        #expect(menu.items.isEmpty)
        #expect(preferences.clipboardFormat == .displayLaTeX)
        #expect(preferences.equationHistory == ["x"])
        #expect(pasteboard.changeCount == changeCount)
    }

    @Test func sharedMenuAndHotkeyActionUpdatesPersistedFormat() throws {
        let suiteName = "LaTeXShot.AppShortcutTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let runtime = AppRuntime(recognizer: UnusedRecognizer(), preferences: preferences, pasteboard: pasteboard)

        for format in ClipboardFormat.allCases.reversed() {
            runtime.selectClipboardFormat(format)
            #expect(preferences.clipboardFormat == format)
            #expect(Preferences(defaults: defaults).clipboardFormat == format)
        }
    }
}

private struct UnusedRecognizer: EquationRecognizing {
    func recognize(_ crop: CGImage) async throws -> String {
        throw EquationRecognitionError.unavailable
    }
}
