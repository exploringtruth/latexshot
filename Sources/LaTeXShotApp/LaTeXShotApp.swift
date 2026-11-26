import AppKit
import Combine
import EquationRecognition
import KeyboardShortcuts
import OSLog
import Sparkle
import SwiftUI

@main
struct LaTeXShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Button("Capture Equation") {
                delegate.runtime.captureEquation()
            }
            .globalKeyboardShortcut(.captureEquation)

            EquationHistoryMenuItem(
                preferences: delegate.runtime.preferences, show: delegate.runtime.showEquationHistory
            )

            Divider()
            Button("Settings…") {
                delegate.runtime.showSettings()
            }
            .globalKeyboardShortcut(.openSettings)
            ClipboardFormatMenuItems(
                preferences: delegate.runtime.preferences, shortcuts: delegate.runtime.shortcuts,
                select: delegate.runtime.selectClipboardFormat
            )
            Button("Check for Updates…") {
                delegate.runtime.updates.check()
            }
            Button("Send Feedback…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/exploringtruth/latexshot/issues")!)
            }

            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Group {
                if let image = MenuBarArtwork.image {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "viewfinder")
                }
            }
            .accessibilityLabel("LaTeXShot")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct EquationHistoryMenuItem: View {
    @ObservedObject var preferences: Preferences
    let show: () -> Void

    var body: some View {
        if preferences.equationHistoryEnabled {
            Button("Equation History", action: show)
                .globalKeyboardShortcut(.showEquationHistory)
        }
    }
}

struct ClipboardFormatMenuItems: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var shortcuts: AppShortcuts
    let select: (ClipboardFormat) -> Void

    var body: some View {
        ForEach(shortcuts.assignedFormats) { format in
            Button {
                select(format)
            } label: {
                Text(menuTitle(for: format))
            }
            .accessibilityLabel(format.rawValue)
            .globalKeyboardShortcut(format.shortcutName)
        }
    }

    private func menuTitle(for format: ClipboardFormat) -> AttributedString {
        var title = AttributedString(" \(format.rawValue)")
        if preferences.clipboardFormat == format {
            title.swiftUI.font = .system(size: NSFont.menuFont(ofSize: 0).pointSize, weight: .bold)
        }
        return title
    }
}

@MainActor
private enum MenuBarArtwork {
    static let image: NSImage? = {
        let packaged = Bundle.main.url(forResource: "LaTeXShotMenuBar", withExtension: "pdf")
        #if DEBUG
        let repositoryArtwork = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Assets/Icon/LaTeXShotMenuBar.pdf")
        let url = packaged ?? repositoryArtwork
        #else
        guard let url = packaged else { return nil }
        #endif
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = AppRuntime(recognizer: OfflineEquationRecognizer())

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = NSApp.setActivationPolicy(.accessory)
        runtime.start()
    }
}

@MainActor
final class AppRuntime {
    private static let captureLog = Logger(subsystem: "io.github.exploringtruth.LaTeXShot", category: "Capture")
    let preferences: Preferences
    private let pasteboard: NSPasteboard
    private lazy var loginItem = LoginItem(preferences: preferences)
    private let settings = SettingsWindow()
    private let history = EquationHistoryWindow()
    private let overlay = CaptureOverlay()
    private let feedback = CaptureFeedback()
    private let recognizer: RecognitionStartup
    private var captureTask: Task<Void, Never>?
    private var historyAvailability: AnyCancellable?
    let updates = UpdateController()
    let shortcuts = AppShortcuts()

    init(
        recognizer: any EquationRecognizing, preferences: Preferences = Preferences(),
        pasteboard: NSPasteboard = .general
    ) {
        self.recognizer = RecognitionStartup(recognizer: recognizer)
        self.preferences = preferences
        self.pasteboard = pasteboard
    }

    func start() {
        Task { await recognizer.start() }
        KeyboardShortcuts.onKeyDown(for: .captureEquation) { [weak self] in
            self?.captureEquation()
        }
        KeyboardShortcuts.onKeyDown(for: .openSettings) { [weak self] in
            self?.showSettings()
        }
        historyAvailability = preferences.$equationHistoryEnabled.removeDuplicates().sink { [weak self] enabled in
            if enabled {
                KeyboardShortcuts.enable(.showEquationHistory)
            } else {
                KeyboardShortcuts.disable(.showEquationHistory)
                self?.history.dismiss()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .showEquationHistory) { [weak self] in
            self?.showEquationHistory()
        }
        for format in ClipboardFormat.allCases {
            KeyboardShortcuts.onKeyDown(for: format.shortcutName) { [weak self] in
                self?.selectClipboardFormat(format)
            }
        }
        loginItem.configureDefault()
        updates.start()
        Task { @MainActor [weak self] in self?.showFirstRunHint() }
    }

    func showSettings() {
        Task { @MainActor [self] in
            history.dismiss()
            settings.show(
                preferences: preferences, loginItem: loginItem, appShortcuts: shortcuts,
                selectFormat: { [weak self] in self?.selectClipboardFormat($0) },
                showHistory: { [weak self] in self?.showEquationHistory() }
            )
        }
    }

    func showEquationHistory() {
        // Let the menu finish tracking before the panel takes keyboard focus.
        Task { @MainActor [self] in
            guard preferences.equationHistoryEnabled else { return }
            history.show(
                preferences: preferences,
                copy: { [weak self] body in
                    guard let self else { return false }
                    do {
                        try self.copyEquation(body)
                        return true
                    } catch {
                        return false
                    }
                },
                dragText: { [weak self] body in self?.formattedEquation(body) ?? body }
            )
        }
    }

    func selectClipboardFormat(_ format: ClipboardFormat) {
        guard format != preferences.clipboardFormat else { return }
        preferences.clipboardFormat = format
        guard let latest = preferences.equationToRecopy else { return }
        do {
            try writeEquationText(formattedEquation(latest), to: pasteboard)
        } catch {
            Self.captureLog.error("Could not update the clipboard after changing format.")
        }
    }

    func copyEquation(_ body: String) throws {
        try writeEquationText(formattedEquation(body), to: pasteboard)
        preferences.recordCopiedEquation(body)
    }

    func recognizeCapture(_ crop: CGImage) async throws -> String {
        let body = try prepareRecognizedFormula(await recognizer.recognize(crop))
        try copyEquation(body)
        return body
    }

    private func formattedEquation(_ body: String) -> String {
        preferences.clipboardFormat.wrap(
            body, prefix: preferences.customPrefix, suffix: preferences.customSuffix
        )
    }

    func captureEquation() {
        guard captureTask == nil else { return }
        // The menu must finish tracking before the overlay can receive mouse and key events.
        captureTask = Task { @MainActor in
            defer { captureTask = nil }
            guard requestScreenAccess() else { return }
            feedback.dismiss()
            history.dismiss()

            guard let selection = await overlay.select(dimmingOpacity: preferences.captureDimmingOpacity) else { return }
            feedback.showProcessing(on: selection.screenFrame)

            let crop: CGImage
            do {
                crop = try await selection.screenshot()
            } catch {
                let captureError = error as NSError
                Self.captureLog.error("Screenshot failed (\(captureError.domain, privacy: .public), code \(captureError.code)).")
                feedback.showFailure("Couldn’t capture the selection. Try again.", on: selection.screenFrame)
                return
            }

            do {
                let body = try await recognizeCapture(crop)
                feedback.showCopied(formula: body, on: selection.screenFrame)
            } catch RecognitionCopyError.incompleteFormula {
                Self.captureLog.error("Recognition returned incomplete LaTeX.")
                feedback.showFailure("The equation looks incomplete. Try a tighter selection.", on: selection.screenFrame)
            } catch RecognitionCopyError.pasteboardUnavailable {
                Self.captureLog.error("Could not write to the clipboard.")
                feedback.showFailure("Couldn’t copy to the clipboard. Try again.", on: selection.screenFrame)
            } catch {
                Self.captureLog.error("Recognition failed before producing a formula.")
                feedback.showFailure("Couldn’t read the equation. Try again.", on: selection.screenFrame)
            }
        }
    }

    private func requestScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !preferences.attemptedScreenAccess {
            preferences.attemptedScreenAccess = true
            return CGRequestScreenCaptureAccess()
        }

        let alert = NSAlert()
        alert.messageText = "Allow screen recording to capture equations"
        alert.informativeText = "Enable LaTeXShot in Privacy & Security, then try again. macOS may ask you to relaunch LaTeXShot."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func showFirstRunHint() {
        guard !preferences.dismissedFirstRunHint else { return }
        let alert = NSAlert()
        alert.messageText = "Welcome to LaTeXShot"
        let capture = KeyboardShortcuts.Name.captureEquation.shortcut.map { "Press \($0)" }
            ?? "Choose Capture Equation from the menu"
        alert.informativeText = "Look for LaTeXShot in the menu bar. \(capture) to select an equation. You can change the shortcut in Settings → Shortcuts."
        alert.addButton(withTitle: "Got It")
        NSApp.activate()
        alert.runModal()
        preferences.dismissedFirstRunHint = true
    }
}

enum RecognitionCopyError: Error {
    case incompleteFormula
    case pasteboardUnavailable
}

@MainActor
func recognizeAndCopy(
    _ crop: CGImage,
    with recognizer: any EquationRecognizing,
    format: ClipboardFormat,
    prefix: String = "",
    suffix: String = "",
    pasteboard: NSPasteboard = .general
) async throws -> String {
    let body = try prepareRecognizedFormula(await recognizer.recognize(crop))
    try writeEquationText(format.wrap(body, prefix: prefix, suffix: suffix), to: pasteboard)
    return body
}

@MainActor
private func writeEquationText(_ text: String, to pasteboard: NSPasteboard) throws {
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string) else {
        throw RecognitionCopyError.pasteboardUnavailable
    }
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { throw RecognitionCopyError.pasteboardUnavailable }
}

private func prepareRecognizedFormula(_ prediction: String) throws -> String {
    let body = prediction.replacingOccurrences(
        of: #"^(?:\s|\\[ ,:;!])+|(?:\s|(?<!\\)\\[ ,:;!])+$"#,
        with: "", options: .regularExpression
    )
    guard !body.isEmpty else { throw RecognitionCopyError.incompleteFormula }

    // Skip escaped braces and check only clear structural failures. A valid formula
    // may still use a command the preview renderer does not support.
    var groups = 0
    var delimiterPairs = 0
    for match in body.matches(of: #/\\(?:[A-Za-z]+|[\s\S])?|[{}]/#) {
        switch match.output {
        case "{": groups += 1
        case "}": groups -= 1
        case #"\left"#: delimiterPairs += 1
        case #"\right"#: delimiterPairs -= 1
        case #"\"#: throw RecognitionCopyError.incompleteFormula
        default: break
        }
        guard groups >= 0, delimiterPairs >= 0 else { throw RecognitionCopyError.incompleteFormula }
    }
    guard groups == 0, delimiterPairs == 0, !body.hasSuffix(#"\right"#) else {
        throw RecognitionCopyError.incompleteFormula
    }

    // Skip escaped backslashes and leave each radicand available for nested roots.
    return body.replacing(#/\\root\s*([0-9]+)\s*\\of\s*(?=\{)|\\\\/#) { match in
        guard let index = match.1 else { return String(match.0) }
        return #"\sqrt["# + index + "]"
    }
}

@MainActor
final class UpdateController: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private lazy var controller: SPUStandardUpdaterController? = {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }()

    func start() { _ = controller }

    func check() {
        guard let controller else {
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "In-app updates are unavailable in this build"
                alert.addButton(withTitle: "OK")
                NSApp.activate()
                alert.runModal()
            }
            return
        }
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, let controller else { return }
        let visibleWindows = Set(NSApp.windows.filter(\.isVisible))
        controller.userDriver.showUpdateInFocus()
        NSApp.windows.first { $0.isVisible && !visibleWindows.contains($0) }?.orderFrontRegardless()
    }
}
