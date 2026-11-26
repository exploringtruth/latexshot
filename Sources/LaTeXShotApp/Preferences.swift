import Foundation
import SwiftUI

enum ClipboardFormat: String, CaseIterable, Identifiable {
    case raw = "Raw LaTeX"
    case inlineMarkdown = "Inline Markdown"
    case displayMarkdown = "Display Markdown"
    case inlineLaTeX = "Inline LaTeX"
    case displayLaTeX = "Display LaTeX"
    case custom = "Custom"

    var id: Self { self }

    func wrap(_ body: String, prefix: String = "", suffix: String = "") -> String {
        switch self {
        case .raw: body
        case .inlineMarkdown: "$" + body + "$"
        case .displayMarkdown: "$$" + body + "$$"
        case .inlineLaTeX: #"\("# + body + #"\)"#
        case .displayLaTeX: #"\["# + body + #"\]"#
        case .custom: prefix + body + suffix
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"

    var id: Self { self }
    var symbol: String { self == .general ? "gearshape" : "keyboard" }
}

@MainActor
final class Preferences: ObservableObject {
    static let historyLimits = 1...5_000
    static let defaultHistoryLimit = 10
    static let captureDimmingRange = 1...90
    static let defaultCaptureDimmingPercent = 26
    private let defaults: UserDefaults
    private var mostRecentlyCopiedEquation: String?

    @Published var equationHistoryEnabled: Bool {
        didSet { defaults.set(equationHistoryEnabled, forKey: "equationHistoryEnabled") }
    }
    @Published private(set) var historyLimit: Int
    @Published private(set) var equationHistory: [String]

    var equationToRecopy: String? {
        mostRecentlyCopiedEquation ?? (equationHistoryEnabled ? equationHistory.first : nil)
    }

    @Published var captureDimmingEnabled: Bool {
        didSet { defaults.set(captureDimmingEnabled, forKey: "captureDimmingEnabled") }
    }
    @Published private(set) var captureDimmingPercent: Int

    var captureDimmingOpacity: CGFloat {
        captureDimmingEnabled ? CGFloat(captureDimmingPercent) / 100 : 0
    }

    @Published var clipboardFormat: ClipboardFormat {
        didSet { defaults.set(clipboardFormat.rawValue, forKey: "clipboardFormat") }
    }
    @Published var customPrefix: String {
        didSet { defaults.set(customPrefix, forKey: "customPrefix") }
    }
    @Published var customSuffix: String {
        didSet { defaults.set(customSuffix, forKey: "customSuffix") }
    }
    @Published var section: SettingsSection {
        didSet { defaults.set(section.rawValue, forKey: "settingsSection") }
    }

    var attemptedScreenAccess: Bool {
        get { defaults.bool(forKey: "attemptedScreenAccess") }
        set { defaults.set(newValue, forKey: "attemptedScreenAccess") }
    }
    var dismissedFirstRunHint: Bool {
        get { defaults.bool(forKey: "dismissedFirstRunHint") }
        set { defaults.set(newValue, forKey: "dismissedFirstRunHint") }
    }
    var configuredLoginItem: Bool {
        get { defaults.bool(forKey: "configuredLoginItem") }
        set { defaults.set(newValue, forKey: "configuredLoginItem") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        captureDimmingEnabled = defaults.object(forKey: "captureDimmingEnabled") as? Bool ?? true
        let dimmingPercent = defaults.object(forKey: "captureDimmingPercent") as? Int
            ?? Self.defaultCaptureDimmingPercent
        captureDimmingPercent = dimmingPercent.clamped(to: Self.captureDimmingRange)
        equationHistoryEnabled = defaults.object(forKey: "equationHistoryEnabled") as? Bool ?? true
        let limit = defaults.object(forKey: "equationHistoryLimit") as? Int ?? Self.defaultHistoryLimit
        let bounded = limit.clamped(to: Self.historyLimits)
        historyLimit = bounded
        equationHistory = Array((defaults.stringArray(forKey: "equationHistory") ?? []).prefix(bounded))
        clipboardFormat = defaults.string(forKey: "clipboardFormat")
            .flatMap(ClipboardFormat.init(rawValue:)) ?? .raw
        customPrefix = defaults.string(forKey: "customPrefix") ?? ""
        customSuffix = defaults.string(forKey: "customSuffix") ?? ""
        section = defaults.string(forKey: "settingsSection").flatMap(SettingsSection.init(rawValue:)) ?? .general
    }

    func setCaptureDimmingPercent(_ percent: Int) {
        captureDimmingPercent = percent.clamped(to: Self.captureDimmingRange)
        defaults.set(captureDimmingPercent, forKey: "captureDimmingPercent")
    }

    func resetCaptureAppearance() {
        captureDimmingEnabled = true
        setCaptureDimmingPercent(Self.defaultCaptureDimmingPercent)
    }

    func setHistoryLimit(_ limit: Int) {
        let bounded = limit.clamped(to: Self.historyLimits)
        historyLimit = bounded
        defaults.set(bounded, forKey: "equationHistoryLimit")
        if equationHistory.count > bounded {
            saveHistory(Array(equationHistory.prefix(bounded)))
        }
    }

    func recordCopiedEquation(_ body: String) {
        mostRecentlyCopiedEquation = body
        guard equationHistoryEnabled, equationHistory.first != body else { return }
        let older = equationHistory.filter { $0 != body }
        saveHistory([body] + older.prefix(historyLimit - 1))
    }

    func clearEquationHistory() {
        mostRecentlyCopiedEquation = nil
        saveHistory([])
    }

    private func saveHistory(_ bodies: [String]) {
        equationHistory = bodies
        defaults.set(bodies, forKey: "equationHistory")
    }
}

private extension Int {
    func clamped(to limits: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, limits.lowerBound), limits.upperBound)
    }
}
