import AppKit
import EquationRecognition
import SwiftUI
import Testing
import WebKit
@testable import LaTeXShotApp

private let formula = #"\frac{x_1}{\sqrt{y}}"#
private let pix2TextRoot = #"\sqrt { 2 + \root 3 \of { x _ { 1 } ^ { 2 } + 1 } } = r _ { 1 }"#
private let portablePix2TextRoot = #"\sqrt { 2 + \sqrt[3]{ x _ { 1 } ^ { 2 } + 1 } } = r _ { 1 }"#

private let clipboardCases: [(ClipboardFormat, String)] = [
    (.raw, formula),
    (.inlineMarkdown, "$" + formula + "$"),
    (.displayMarkdown, "$$" + formula + "$$"),
    (.inlineLaTeX, #"\("# + formula + #"\)"#),
    (.displayLaTeX, #"\["# + formula + #"\]"#),
    (.custom, "  before\n" + formula + "\n after  \n")
]

@MainActor
struct ClipboardTests {
    @Test(arguments: clipboardCases)
    func copiesExactText(format: ClipboardFormat, expected: String) async throws {
        let crop = try makeCrop()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let result = try await recognizeAndCopy(
            crop, with: StubRecognizer(result: .success(formula)), format: format,
            prefix: "  before\n", suffix: "\n after  \n", pasteboard: pasteboard
        )
        #expect(result == formula)
        #expect(pasteboard.types?.contains(.string) == true)
        #expect(pasteboard.types?.allSatisfy { $0 == .string || $0.rawValue == "NSStringPboardType" } == true)
        #expect(pasteboard.string(forType: .string) == expected)
    }

    @Test func supportsEmptyCustomFields() {
        #expect(ClipboardFormat.custom.wrap(formula) == formula)
        #expect(ClipboardFormat.custom.wrap(formula, prefix: "\n") == "\n" + formula)
        #expect(ClipboardFormat.custom.wrap(formula, suffix: "\n") == formula + "\n")
    }

    @Test(arguments: [
        (pix2TextRoot, portablePix2TextRoot),
        (
            #"\root 3\of{\root 4 \of {{x} + 1}} + \root 12\of{y}"#,
            #"\sqrt[3]{\sqrt[4]{{x} + 1}} + \sqrt[12]{y}"#
        ),
        (
            #"\sqrt[3]{x} + \root n \of {y} + \root 3 \of x + \roots 3 \of {z} + \root 3 \off {z} + \\root 3 \of {z}"#,
            #"\sqrt[3]{x} + \root n \of {y} + \root 3 \of x + \roots 3 \of {z} + \root 3 \off {z} + \\root 3 \of {z}"#
        )
    ])
    func copiesPortableNumericRootsInInlineMarkdown(prediction: String, expected: String) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let result = try await recognizeAndCopy(
            makeCrop(), with: StubRecognizer(result: .success(prediction)),
            format: .inlineMarkdown, pasteboard: pasteboard
        )
        #expect(result == expected)
        #expect(pasteboard.string(forType: .string) == "$" + expected + "$")
    }

    @Test(arguments: [
        Result<String, StubError>.failure(.noEquation),
        .success("\n  "),
        .success(#"{sqrt{x+1}}+{\sqrt[3]{y}}=1\quad\left"#),
        .success(#"{\sqrt{x+1}}+{\sqrt[3]{y}=1"#),
    ])
    fileprivate func preservesClipboardOnRecognitionFailure(result: Result<String, StubError>) async throws {
        let crop = try makeCrop()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Previous clipboard value", forType: .string)
        let previousChange = pasteboard.changeCount

        await #expect(throws: (any Error).self) {
            try await recognizeAndCopy(crop, with: StubRecognizer(result: result), format: .raw, pasteboard: pasteboard)
        }
        #expect(pasteboard.changeCount == previousChange)
        #expect(pasteboard.string(forType: .string) == "Previous clipboard value")
    }

    @Test func cleansOuterSpacingAndKeepsEscapedBraces() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let expected = #"\left\{\sqrt{x+1}\right\}+\sqrt[3]{y}=1"#
        let result = try await recognizeAndCopy(
            makeCrop(), with: StubRecognizer(result: .success(#"\ "# + expected + #"\, \ "#)),
            format: .raw, pasteboard: pasteboard
        )
        #expect(result == expected)
        #expect(pasteboard.string(forType: .string) == expected)
    }
}

private func makeCrop() throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: 10, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    return try #require(context.makeImage())
}

private enum StubError: Error {
    case noEquation
    case unexpectedImage
}

private struct StubRecognizer: EquationRecognizing {
    let result: Result<String, StubError>

    func recognize(_ crop: CGImage) async throws -> String {
        guard crop.width == 10, crop.height == 8 else { throw StubError.unexpectedImage }
        return try result.get()
    }
}

@MainActor
struct EquationHistoryTests {
    @Test func confirmsCopyOnTheOriginalCardBeforeClosingHistory() async throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let entries = (1...5_000).map { "x_{\($0)}" }
        defaults.setPersistentDomain(
            ["equationHistoryLimit": entries.count, "equationHistory": entries], forName: domain
        )
        let preferences = Preferences(defaults: defaults)
        preferences.clipboardFormat = .custom
        preferences.customPrefix = " \n["
        preferences.customSuffix = "]\n "
        let runtime = AppRuntime(
            recognizer: StubRecognizer(result: .success("unused")), preferences: preferences, pasteboard: pasteboard
        )
        let history = EquationHistoryWindow(previews: HistoryPreviews { _ in nil })
        let panel = history.makePanel(
            in: CGRect(x: 0, y: 0, width: 480, height: 320), preferences: preferences,
            copy: { formula in (try? runtime.copyEquation(formula)) != nil }, dragText: { $0 }
        )
        defer { panel.close() }
        let position = 4_500
        let formula = entries[position]
        let offset = history.previews.layout.offsets[position]
        let selectedAt = ContinuousClock.now
        var closedAt: ContinuousClock.Instant?
        panel.cards.select(formula) {
            closedAt = .now
            panel.close()
        }

        #expect(pasteboard.string(forType: .string) == " \n[" + formula + "]\n ")
        #expect(Preferences(defaults: defaults).equationHistory.first == formula)
        #expect(history.previews.entries.first == formula)
        let confirmation = try #require(panel.cards.confirmation)
        #expect(confirmation.formula == formula)
        #expect(confirmation.entries[position] == formula)
        #expect(confirmation.layout.offsets[position] == offset)
        #expect(closedAt == nil)

        let deadline = ContinuousClock.now + .seconds(2)
        while closedAt == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let dismissedAt = try #require(closedAt)
        #expect(selectedAt.duration(to: dismissedAt) >= .milliseconds(300))
        #expect(panel.cards.confirmation == nil)
    }

    @Test func defaultsToTenAndPersistsImmediateTrimming() throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)

        #expect(preferences.equationHistoryEnabled)
        #expect(preferences.historyLimit == 10)
        #expect(preferences.equationHistory.isEmpty)
        for index in 1...12 {
            preferences.recordCopiedEquation("x_\(index)")
        }
        #expect(Preferences(defaults: defaults).equationHistory == (3...12).reversed().map { "x_\($0)" })

        preferences.setHistoryLimit(3)
        let trimmed = ["x_12", "x_11", "x_10"]
        #expect(preferences.equationHistory == trimmed)
        let recalled = Preferences(defaults: defaults)
        #expect(recalled.equationHistoryEnabled)
        #expect(recalled.historyLimit == 3)
        #expect(recalled.equationHistory == trimmed)
        recalled.setHistoryLimit(50)
        #expect(Preferences(defaults: defaults).equationHistory == trimmed)
        recalled.setHistoryLimit(0)
        #expect(recalled.historyLimit == 1)
        #expect(recalled.equationHistory == ["x_12"])
    }

    @Test func commitsHistoryLimitOnlyAfterValidDraft() throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        for index in 1...10 {
            preferences.recordCopiedEquation("x_\(index)")
        }
        let original = preferences.equationHistory

        let field = SettingsIntegerField(
            title: "Equations to Keep",
            value: Binding(get: { preferences.historyLimit }, set: { preferences.setHistoryLimit($0) }),
            range: Preferences.historyLimits,
            isEnabled: { preferences.equationHistoryEnabled },
            clampsAboveMaximum: true
        )
        let coordinator = field.makeCoordinator()
        let input = NSTextField(string: "10")
        let editor = NSTextView()
        let didEndEditing = Notification(name: NSControl.textDidEndEditingNotification, object: input)

        editor.string = "2"
        #expect(preferences.historyLimit == 10)
        #expect(preferences.equationHistory == original)
        editor.string = "25"
        #expect(coordinator.control(input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(input.stringValue == "25")
        #expect(Preferences(defaults: defaults).historyLimit == 25)
        #expect(preferences.equationHistory == original)

        for invalid in ["", "0", "-3", "+3", "2.5", "abc", String(repeating: "9", count: 100) + "x"] {
            input.stringValue = invalid
            coordinator.controlTextDidEndEditing(didEndEditing)
            #expect(input.stringValue == "25")
            #expect(Preferences(defaults: defaults).historyLimit == 25)
            #expect(preferences.equationHistory == original)
        }

        preferences.equationHistoryEnabled = false
        input.stringValue = "1"
        coordinator.controlTextDidEndEditing(didEndEditing)
        #expect(input.stringValue == "25")
        #expect(preferences.equationHistory == original)
        preferences.equationHistoryEnabled = true

        editor.string = "10000"
        #expect(preferences.historyLimit == 25)
        #expect(coordinator.control(input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(input.stringValue == "5000")
        #expect(Preferences(defaults: defaults).historyLimit == 5_000)
        #expect(preferences.equationHistory == original)

        input.stringValue = "51"
        coordinator.controlTextDidEndEditing(didEndEditing)
        #expect(Preferences(defaults: defaults).historyLimit == 51)
        for overLimit in ["5001", String(repeating: "9", count: 1_000)] {
            input.stringValue = overLimit
            coordinator.controlTextDidEndEditing(didEndEditing)
            #expect(input.stringValue == "5000")
            #expect(Preferences(defaults: defaults).historyLimit == 5_000)
            #expect(preferences.equationHistory == original)
            input.stringValue = String(repeating: "0", count: 1_000) + "51"
            coordinator.controlTextDidEndEditing(didEndEditing)
            #expect(Preferences(defaults: defaults).historyLimit == 51)
        }

        input.stringValue = "3"
        coordinator.controlTextDidEndEditing(didEndEditing)
        #expect(input.stringValue == "3")
        #expect(Preferences(defaults: defaults).equationHistory == Array(original.prefix(3)))
    }

    @Test func preservesLegacyHistoryAndRetainsFiveThousandEquations() throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let entries = (1...5_000).map { "x_{\($0)}" }
        let legacy = Array(entries.prefix(50))
        defaults.setPersistentDomain(
            ["equationHistoryLimit": 50, "equationHistoryEnabled": false, "equationHistory": legacy],
            forName: domain
        )
        let migrated = Preferences(defaults: defaults)
        #expect(migrated.historyLimit == 50)
        #expect(!migrated.equationHistoryEnabled)
        #expect(migrated.equationHistory == legacy)
        migrated.setHistoryLimit(5_000)
        #expect(Preferences(defaults: defaults).equationHistory == legacy)

        defaults.setPersistentDomain(
            ["equationHistoryLimit": 5_000, "equationHistory": entries],
            forName: domain
        )
        let full = Preferences(defaults: defaults)
        #expect(full.equationHistory == entries)

        full.recordCopiedEquation("new")
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.equationHistory == ["new"] + entries.dropLast())
    }

    @Test func pausesHistoryButKeepsSessionRecopyAndResumesWithoutBackfill() throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let preferences = Preferences(defaults: defaults)
        let recognizer = StubRecognizer(result: .success("unused"))
        let runtime = AppRuntime(recognizer: recognizer, preferences: preferences, pasteboard: pasteboard)
        preferences.setHistoryLimit(4)
        try runtime.copyEquation("saved")
        preferences.equationHistoryEnabled = false
        runtime.selectClipboardFormat(.inlineMarkdown)
        #expect(pasteboard.string(forType: .string) == "$saved$")
        try runtime.copyEquation("private")
        runtime.selectClipboardFormat(.displayMarkdown)
        #expect(pasteboard.string(forType: .string) == "$$private$$")

        let recalled = Preferences(defaults: defaults)
        #expect(!recalled.equationHistoryEnabled)
        #expect(recalled.historyLimit == 4)
        #expect(recalled.equationHistory == ["saved"])
        let reopened = AppRuntime(recognizer: recognizer, preferences: recalled, pasteboard: pasteboard)
        let changeCount = pasteboard.changeCount
        reopened.selectClipboardFormat(.raw)
        #expect(pasteboard.changeCount == changeCount)

        preferences.equationHistoryEnabled = true
        runtime.selectClipboardFormat(.inlineLaTeX)
        #expect(pasteboard.string(forType: .string) == #"\(private\)"#)
        let resumed = Preferences(defaults: defaults)
        #expect(resumed.equationHistoryEnabled)
        #expect(resumed.equationHistory == ["saved"])
        try runtime.copyEquation("new")
        #expect(Preferences(defaults: defaults).equationHistory == ["new", "saved"])
    }

    @Test func usesMostRecentlyCopiedBodyWithEveryFormatAfterRelaunch() async throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let preferences = Preferences(defaults: defaults)
        let recognizer = StubRecognizer(result: .success(pix2TextRoot))
        let runtime = AppRuntime(recognizer: recognizer, preferences: preferences, pasteboard: pasteboard)

        runtime.selectClipboardFormat(.inlineMarkdown)
        let captured = try await runtime.recognizeCapture(makeCrop())
        #expect(captured == portablePix2TextRoot)
        #expect(pasteboard.string(forType: .string) == "$" + captured + "$")
        #expect(preferences.equationHistory == [captured])
        try runtime.copyEquation(formula)
        try runtime.copyEquation(captured)
        let copiedOrder = [captured, formula]
        #expect(preferences.equationHistory == copiedOrder)
        #expect(pasteboard.string(forType: .string) == "$" + captured + "$")
        try runtime.copyEquation(captured)
        #expect(preferences.equationHistory == copiedOrder)

        let recalled = Preferences(defaults: defaults)
        let reopened = AppRuntime(recognizer: recognizer, preferences: recalled, pasteboard: pasteboard)
        recalled.customPrefix = "  before\n"
        recalled.customSuffix = "\n after  \n"
        for (format, expected) in clipboardCases {
            reopened.selectClipboardFormat(format)
            #expect(pasteboard.string(forType: .string) == expected.replacingOccurrences(of: formula, with: captured))
            #expect(recalled.equationHistory == copiedOrder)
        }
        try reopened.copyEquation(formula)
        #expect(pasteboard.string(forType: .string) == "  before\n" + formula + "\n after  \n")
        pasteboard.clearContents()
        pasteboard.setString("External text", forType: .string)
        let changeCount = pasteboard.changeCount
        reopened.selectClipboardFormat(.custom)
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == "External text")
    }

    @Test func preservesClipboardAndHistoryOnEmptyHistoryOrFailedRecognition() async throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let preferences = Preferences(defaults: defaults)
        let runtime = AppRuntime(
            recognizer: StubRecognizer(result: .success(#"{\sqrt{x}"#)),
            preferences: preferences, pasteboard: pasteboard
        )
        pasteboard.setString("External text", forType: .string)
        let changeCount = pasteboard.changeCount

        runtime.selectClipboardFormat(.displayLaTeX)
        await #expect(throws: RecognitionCopyError.incompleteFormula) {
            try await runtime.recognizeCapture(makeCrop())
        }
        #expect(preferences.clipboardFormat == .displayLaTeX)
        #expect(preferences.equationHistory.isEmpty)
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == "External text")

        try runtime.copyEquation(formula)
        let copiedChangeCount = pasteboard.changeCount
        await #expect(throws: RecognitionCopyError.incompleteFormula) {
            try await runtime.recognizeCapture(makeCrop())
        }
        #expect(preferences.equationHistory == [formula])
        #expect(pasteboard.changeCount == copiedChangeCount)
    }

    @Test func clearingLocalHistoryPreservesClipboardAndSettings() throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let preferences = Preferences(defaults: defaults)
        preferences.clipboardFormat = .inlineMarkdown
        preferences.setHistoryLimit(8)
        let runtime = AppRuntime(
            recognizer: StubRecognizer(result: .success("x")), preferences: preferences, pasteboard: pasteboard
        )
        try runtime.copyEquation("x")
        let clipboardCount = pasteboard.changeCount

        preferences.clearEquationHistory()

        let reloaded = Preferences(defaults: defaults)
        #expect(preferences.equationHistory.isEmpty)
        #expect(reloaded.equationHistory.isEmpty)
        #expect(reloaded.clipboardFormat == .inlineMarkdown)
        #expect(reloaded.historyLimit == 8)
        #expect(pasteboard.string(forType: .string) == "$x$")
        #expect(pasteboard.changeCount == clipboardCount)
        runtime.selectClipboardFormat(.raw)
        #expect(pasteboard.changeCount == clipboardCount)
    }

    @Test func positionsHistoryUnderTheVisibleTopWithinWidthBounds() throws {
        let secondary = CGRect(x: -1600, y: 400, width: 1600, height: 900)
        let wide = EquationHistoryWindow.frame(in: secondary, preferredSize: CGSize(width: 1200, height: 260))
        #expect(wide.width == 1_100)
        #expect(wide.midX == secondary.midX)
        #expect(wide.maxY == secondary.maxY - 16)

        let small = CGRect(x: 0, y: -120, width: 500, height: 170)
        let narrow = EquationHistoryWindow.frame(in: small, preferredSize: CGSize(width: 1200, height: 260))
        #expect(small.contains(narrow))
        #expect(narrow.width == 400)
        #expect(narrow.midX == small.midX)
        #expect(narrow.maxY == small.maxY - 16)

        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let history = EquationHistoryWindow()
        let preferences = Preferences(defaults: defaults)
        preferences.recordCopiedEquation("x^2")
        let panel = history.makePanel(
            in: secondary, preferences: preferences, copy: { _ in false }, dragText: { $0 }
        )
        defer { panel.close() }
        #expect(panel.frame.width < wide.width)
        #expect(abs(panel.frame.midX - wide.midX) <= 1)
        #expect(panel.frame.maxY == wide.maxY)
        let moved = CGRect(x: -1450, y: 650, width: 340, height: 150)
        let resized = EquationHistoryWindow.frame(
            in: secondary, preferredSize: CGSize(width: 480, height: 260), anchoredTo: moved
        )
        #expect(resized.midX == moved.midX)
        #expect(resized.maxY == moved.maxY)
        #expect(!panel.isVisible)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.isMovable)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.styleMask.contains(.titled))
        #expect(!panel.isOpaque)
        #expect(panel.standardWindowButton(.closeButton) == nil)
    }
}

struct CaptureGeometryTests {
    @Test func flipsLocalCoordinatesAndScalesToDisplayPixels() {
        let pick = CaptureSelection(
            displayID: 2, displayBounds: CGRect(x: 0, y: 0, width: 300, height: 200),
            rect: CGRect(x: 7, y: 30, width: 80, height: 50),
            screenFrame: CGRect(x: -300, y: 500, width: 300, height: 200)
        )
        #expect(pick.pixelRect(scale: 1, imageSize: CGSize(width: 300, height: 200)) ==
            CGRect(x: 7, y: 120, width: 80, height: 50))
        #expect(pick.pixelRect(scale: 2, imageSize: CGSize(width: 600, height: 400)) ==
            CGRect(x: 14, y: 240, width: 160, height: 100))
    }

    @Test func roundsOutAtPixelBoundariesAndClipsToImage() {
        let pick = CaptureSelection(
            displayID: 1, displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            rect: CGRect(x: 94.25, y: 0.1, width: 5.75, height: 14.7),
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(pick.pixelRect(scale: 2, imageSize: CGSize(width: 199, height: 199)) ==
            CGRect(x: 188, y: 170, width: 11, height: 29))
    }
}

@MainActor
struct PreferencesTests {
    @Test func settingsIntegerInputAcceptsOnlyWholeDigitEdits() {
        let formatter = SettingsDigitsFormatter()
        for draft in ["", "2", "25", "090"] {
            var proposed = draft as NSString
            #expect(formatter.isPartialStringValid(
                &proposed, proposedSelectedRange: nil,
                originalString: "26", originalSelectedRange: NSRange(location: 0, length: 2),
                errorDescription: nil
            ))
        }
        for draft in ["2.5", "+2", " 2", "2\n", "2a5", "２５", "%"] {
            var proposed = draft as NSString
            #expect(!formatter.isPartialStringValid(
                &proposed, proposedSelectedRange: nil,
                originalString: "26", originalSelectedRange: NSRange(location: 0, length: 2),
                errorDescription: nil
            ))
            #expect(proposed as String == draft)
        }
    }

    @Test func dimmingFieldRestoresSavedValueAcrossToggleSliderAndReset() throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        preferences.setCaptureDimmingPercent(44)
        var field = SettingsIntegerField(
            title: "Dimming Percentage",
            value: Binding(
                get: { preferences.captureDimmingPercent },
                set: { preferences.setCaptureDimmingPercent($0) }
            ),
            range: Preferences.captureDimmingRange,
            isEnabled: { preferences.captureDimmingEnabled }
        )
        let coordinator = field.makeCoordinator()
        let input = NSTextField(string: "44")
        let didEndEditing = Notification(name: NSControl.textDidEndEditingNotification, object: input)

        input.stringValue = ""
        preferences.captureDimmingEnabled = false
        coordinator.synchronize(input, with: field)
        #expect(!input.isEnabled)
        #expect(input.stringValue == "44")
        preferences.captureDimmingEnabled = true
        coordinator.synchronize(input, with: field)
        #expect(input.isEnabled)
        #expect(input.stringValue == "44")

        input.stringValue = "91"
        coordinator.controlTextDidEndEditing(didEndEditing)
        #expect(input.stringValue == "44")
        input.stringValue = "90"
        coordinator.controlTextDidEndEditing(didEndEditing)
        #expect(preferences.captureDimmingPercent == 90)
        preferences.setCaptureDimmingPercent(63)
        coordinator.synchronize(input, with: field)
        #expect(input.stringValue == "63")
        preferences.resetCaptureAppearance()
        field.resetCount += 1
        coordinator.synchronize(input, with: field)
        #expect(input.stringValue == "26")
        input.stringValue = "9"
        preferences.resetCaptureAppearance()
        field.resetCount += 1
        coordinator.synchronize(input, with: field)
        #expect(input.stringValue == "26")
    }

    @Test func persistsCaptureDimmingAndResetsOnlyCaptureAppearance() throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.captureDimmingEnabled)
        #expect(preferences.captureDimmingPercent == 26)
        #expect(preferences.captureDimmingOpacity == 0.26)

        preferences.setCaptureDimmingPercent(0)
        #expect(preferences.captureDimmingPercent == 1)
        preferences.setCaptureDimmingPercent(100)
        #expect(preferences.captureDimmingPercent == 90)
        #expect(preferences.captureDimmingOpacity == 0.90)
        preferences.captureDimmingEnabled = false
        preferences.recordCopiedEquation("saved")
        preferences.setHistoryLimit(5)
        preferences.equationHistoryEnabled = false
        preferences.clipboardFormat = .displayMarkdown

        let recalled = Preferences(defaults: defaults)
        #expect(!recalled.captureDimmingEnabled)
        #expect(recalled.captureDimmingPercent == 90)
        #expect(recalled.captureDimmingOpacity == 0)
        recalled.resetCaptureAppearance()

        let reset = Preferences(defaults: defaults)
        #expect(reset.captureDimmingEnabled)
        #expect(reset.captureDimmingPercent == 26)
        #expect(reset.captureDimmingOpacity == 0.26)
        #expect(!reset.equationHistoryEnabled)
        #expect(reset.historyLimit == 5)
        #expect(reset.equationHistory == ["saved"])
        #expect(reset.clipboardFormat == .displayMarkdown)
    }

    @Test(arguments: [(0.0, 1.0 / 255), (0.26, 0.26), (0.90, 0.90)])
    func drawsCaptureShadeOffscreen(opacity: CGFloat, expected: CGFloat) throws {
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let view = SelectionView(frame: bounds, dimmingOpacity: opacity)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previousContext }

        view.draw(bounds)

        let color = try #require(bitmap.colorAt(x: 4, y: 4))
        #expect(color.alphaComponent > 0)
        #expect(abs(color.alphaComponent - expected) < 1.0 / 255)
        #expect(view.acceptsFirstResponder)
        #expect(view.acceptsFirstMouse(for: nil))
    }

    @Test func remembersPresetCustomFieldsAndSelectedSection() throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let initial = Preferences(defaults: defaults)
        #expect(initial.clipboardFormat == .raw)
        #expect(initial.section == .general)
        initial.clipboardFormat = .custom
        initial.customPrefix = " \npre "
        initial.customSuffix = "\npost\n"
        initial.clipboardFormat = .displayMarkdown
        initial.section = .shortcuts

        let recalled = Preferences(defaults: defaults)
        #expect(recalled.clipboardFormat == .displayMarkdown)
        #expect(recalled.section == .shortcuts)
        recalled.clipboardFormat = .custom
        #expect(recalled.clipboardFormat.wrap(formula, prefix: recalled.customPrefix, suffix: recalled.customSuffix) ==
            " \npre " + formula + "\npost\n")
    }
}

@MainActor
struct PopupTests {
    @Test func processingPopupShowsAccessibleProgressWithoutActivating() async throws {
        let feedback = CaptureFeedback()
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        feedback.showProcessing(on: frame)
        defer { feedback.dismiss() }

        let panel = try #require(feedback.panel)
        #expect(panel.isVisible)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.ignoresMouseEvents)
        let title = try #require(panel.contentView?.subviews.first)
        #expect(title.accessibilityLabel() == "Processing…")
        try await Task.sleep(for: .seconds(3.2))
        #expect(panel.isVisible)

        feedback.showFailure("Couldn’t read the equation. Try again.", on: frame)
        #expect(feedback.panel !== panel)
        #expect(feedback.panel?.isVisible == true)
    }

    @Test(arguments: [
        (
            formula,
            "document.querySelector('.katex math mfrac') !== null"
        ),
        (
            pix2TextRoot,
            "document.querySelector('.katex math mroot > :nth-child(2)')?.textContent === '3'"
        )
    ])
    func bundledRendererTypesetsFormulaInWebKit(prediction: String, mathCheck: String) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let body = try await recognizeAndCopy(
            makeCrop(), with: StubRecognizer(result: .success(prediction)),
            format: .raw, pasteboard: pasteboard
        )
        let (webViews, continuation) = AsyncStream<WKWebView>.makeStream()
        let renderer = FormulaRenderer(formula: body) { webView in
            continuation.yield(webView)
            continuation.finish()
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            continuation.finish()
        }
        var iterator = webViews.makeAsyncIterator()
        let webView = try #require(await iterator.next())
        timeout.cancel()
        withExtendedLifetime(renderer) {}

        let hasMath = try await webView.evaluateJavaScript(mathCheck)
        #expect(hasMath as? Bool == true)
        let loadedFonts = try await webView.evaluateJavaScript(
            "Array.from(document.fonts).filter(font => font.status === 'loaded').length"
        )
        #expect((loadedFonts as? Int ?? 0) > 0)
        let mathJaxUnloaded = try await webView.evaluateJavaScript("typeof MathJax === 'undefined'")
        #expect(mathJaxUnloaded as? Bool == true)
    }

    @Test
    func bundledRendererUsesLocalMathJaxForRawTeXRoot() async throws {
        // Pass the original TeX directly so clipboard normalization cannot make KaTeX accept it.
        let (webViews, continuation) = AsyncStream<WKWebView>.makeStream()
        let renderer = FormulaRenderer(formula: pix2TextRoot) { webView in
            continuation.yield(webView)
            continuation.finish()
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = webViews.makeAsyncIterator()
        let webView = try #require(await iterator.next())
        withExtendedLifetime(renderer) {}

        let fallbackRendered = try await webView.evaluateJavaScript(
            """
            MathJax.version === '3.2.2' &&
            !document.querySelector('.katex') &&
            !!document.querySelector('#formula mjx-container svg [data-mml-node="mroot"]') &&
            Array.from(document.scripts).filter(script => script.src.includes('/mathjax-3.2.2/'))
                .map(script => new URL(script.src).protocol).join(',') === 'file:,file:'
            """
        )
        #expect(fallbackRendered as? Bool == true)

        let chemistryRendered = try await webView.callAsyncJavaScript(
            "return await renderFormula(input) && !!document.querySelector('#formula mjx-container svg');",
            arguments: ["input": #"\ce{2 H2 + O2 -> 2 H2O}"#], in: nil, contentWorld: .page
        )
        #expect(chemistryRendered as? Bool == true)

        for input in [
            #"\root 3 \of{x}+\latexShotUnknownCommand"#,
            #"\root 3 \of{x}+\require{html}"#,
            #"\root 3 \of{x}+\href{https://example.com}{x}"#,
            #"\root 3 \of{x}+\class{external}{x}"#,
            #"\root 3 \of{x}+\style{color:red}{x}"#
        ] {
            let rejected = try await webView.callAsyncJavaScript(
                "return !(await renderFormula(input)) && !document.getElementById('formula').hasChildNodes();",
                arguments: ["input": input], in: nil, contentWorld: .page
            )
            #expect(rejected as? Bool == true, "Unexpected preview for \(input)")
        }
    }

    @Test
    func unsupportedPreviewKeepsCopiedPanel() async throws {
        let feedback = CaptureFeedback()
        defer { feedback.dismiss() }
        let frame = try #require(NSScreen.main?.frame)
        feedback.showCopied(formula: #"\root 3 \of{x}+\latexShotUnknownCommand"#, on: frame)
        let panel = try #require(feedback.panel)
        try await Task.sleep(for: .seconds(1))

        #expect(panel.isVisible)
        #expect(panel.contentView?.subviews.first?.accessibilityLabel() == "Copied")
        #expect(panel.contentView?.subviews.contains { $0 is WKWebView } == false)
    }
}
