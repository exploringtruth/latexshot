import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(
        preferences: Preferences, loginItem: LoginItem, appShortcuts: AppShortcuts,
        selectFormat: @escaping (ClipboardFormat) -> Void, showHistory: @escaping () -> Void
    ) {
        if window == nil {
            let view = SettingsView(
                preferences: preferences, loginItem: loginItem, appShortcuts: appShortcuts,
                selectFormat: selectFormat, showHistory: showHistory
            )
            let newWindow = NSWindow(contentViewController: NSHostingController(rootView: view))
            newWindow.title = "LaTeXShot Settings"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 660, height: 526))
            newWindow.contentMinSize = NSSize(width: 590, height: 490)
            newWindow.isReleasedWhenClosed = false
            newWindow.tabbingMode = .disallowed
            newWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            newWindow.center()
            window = newWindow
        }
        guard let window else { return }
        loginItem.refresh()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var loginItem: LoginItem
    @State private var dimmingResetCount = 0
    let appShortcuts: AppShortcuts
    let selectFormat: (ClipboardFormat) -> Void
    let showHistory: () -> Void

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding<SettingsSection?>(
                get: { preferences.section },
                set: { if let section = $0 { preferences.section = section } }
            )) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 156, max: 180)
        } detail: {
            switch preferences.section {
            case .general: general
            case .shortcuts: shortcuts
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var general: some View {
        Form {
            Section("Capture") {
                Toggle("Dim Screen During Capture", isOn: $preferences.captureDimmingEnabled)
                    .toggleStyle(.switch)
                LabeledContent("Dimming Amount") {
                    HStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { Double(preferences.captureDimmingPercent) },
                                set: { preferences.setCaptureDimmingPercent(Int($0.rounded())) }
                            ),
                            in: Double(Preferences.captureDimmingRange.lowerBound)
                                ... Double(Preferences.captureDimmingRange.upperBound),
                            step: 1
                        ) {
                            Text("Dimming Amount")
                        }
                        .labelsHidden()
                        .accessibilityValue(Text("\(preferences.captureDimmingPercent)%"))
                        .disabled(!preferences.captureDimmingEnabled)
                        SettingsIntegerField(
                            title: "Dimming Percentage",
                            value: Binding(
                                get: { preferences.captureDimmingPercent },
                                set: { preferences.setCaptureDimmingPercent($0) }
                            ),
                            range: Preferences.captureDimmingRange,
                            isEnabled: { preferences.captureDimmingEnabled },
                            resetCount: dimmingResetCount
                        )
                        .frame(width: 40)
                        Text("%")
                            .foregroundStyle(preferences.captureDimmingEnabled ? .primary : .secondary)
                            .accessibilityHidden(true)
                    }
                }
                Button("Reset Capture Appearance") {
                    preferences.resetCaptureAppearance()
                    dimmingResetCount += 1
                }
            }
            Section("Clipboard") {
                Picker("Format", selection: Binding(
                    get: { preferences.clipboardFormat }, set: { selectFormat($0) }
                )) {
                    ForEach(ClipboardFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                if preferences.clipboardFormat == .custom {
                    wrapperEditor("Prefix", text: $preferences.customPrefix)
                    wrapperEditor("Suffix", text: $preferences.customSuffix)
                }
                LabeledContent("Preview") {
                    ScrollView([.vertical, .horizontal]) {
                        Text(preferences.clipboardFormat.wrap(
                            #"\frac{a}{b}"#, prefix: preferences.customPrefix, suffix: preferences.customSuffix
                        ))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 24, maxHeight: 68)
                }
            }
            Section("Equation History") {
                Toggle("Enable Equation History", isOn: $preferences.equationHistoryEnabled)
                    .toggleStyle(.switch)
                LabeledContent("Equations to Keep") {
                    HStack(spacing: 6) {
                        Text("Max \(Preferences.historyLimits.upperBound.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                        SettingsIntegerField(
                            title: "Equations to Keep",
                            value: Binding(
                                get: { preferences.historyLimit },
                                set: { preferences.setHistoryLimit($0) }
                            ),
                            range: Preferences.historyLimits,
                            isEnabled: { preferences.equationHistoryEnabled },
                            clampsAboveMaximum: true
                        )
                        .frame(width: 60)
                        Stepper("Adjust Equations to Keep", value: Binding(
                            get: { preferences.historyLimit },
                            set: {
                                guard preferences.equationHistoryEnabled, $0 != preferences.historyLimit else { return }
                                preferences.setHistoryLimit($0)
                            }
                        ), in: Preferences.historyLimits)
                        .labelsHidden()
                    }
                }
                .disabled(!preferences.equationHistoryEnabled)
                Button("Show Equation History", action: showHistory)
                    .disabled(!preferences.equationHistoryEnabled)
            }
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginItem.isSelected },
                    set: { loginItem.setEnabled($0) }
                ))
                .disabled(!loginItem.isPackaged)
                if !loginItem.isPackaged {
                    Text("Available in the packaged app.")
                        .foregroundStyle(.secondary)
                } else if loginItem.status == .requiresApproval {
                    Button("Open Login Items Settings…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if let error = loginItem.error {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func wrapperEditor(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 50)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel(title)
        }
    }

    private var shortcuts: some View {
        Form {
            Section("Global Shortcuts") {
                shortcutRecorder("Capture Equation", name: .captureEquation)
                shortcutRecorder("Open Settings", name: .openSettings)
                shortcutRecorder("Show Equation History", name: .showEquationHistory)
            }
            Section("Clipboard Format") {
                ForEach(ClipboardFormat.allCases) { format in
                    shortcutRecorder(format.rawValue, name: format.shortcutName)
                }
            }
            Section {
                Button("Reset Shortcuts") {
                    appShortcuts.resetToDefaults()
                }
                .help("Restores the Capture Equation default and clears all other shortcuts.")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRecorder(_ title: String, name: KeyboardShortcuts.Name) -> some View {
        KeyboardShortcuts.Recorder(title, name: name) { _ in
            appShortcuts.assignmentsDidChange()
        }
        .shortcutValidation { shortcut in
            if let conflict = appShortcuts.conflict(for: shortcut, excluding: name) {
                return .disallow(reason: conflict)
            }
            return .allow
        }
    }
}

@MainActor
final class LoginItem: ObservableObject {
    let isPackaged = Bundle.main.bundleURL.pathExtension == "app"
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?
    private let preferences: Preferences
    private let service = SMAppService.mainApp

    var isSelected: Bool { status == .enabled || status == .requiresApproval }

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func configureDefault() {
        guard isPackaged else { return }
        refresh()
        guard !preferences.configuredLoginItem else { return }
        preferences.configuredLoginItem = true
        if !isSelected {
            updateRegistration(enabled: true, requestApproval: false)
        }
    }

    func refresh() {
        if isPackaged { status = service.status }
    }

    func setEnabled(_ enabled: Bool) {
        guard isPackaged else { return }
        preferences.configuredLoginItem = true
        updateRegistration(enabled: enabled, requestApproval: enabled)
    }

    private func updateRegistration(enabled: Bool, requestApproval: Bool) {
        error = nil
        refresh()
        defer { refresh() }
        do {
            if enabled && !isSelected {
                try service.register()
            } else if !enabled && isSelected {
                try service.unregister()
            }
            if requestApproval && service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            self.error = "Couldn’t change Launch at Login. \(error.localizedDescription)"
        }
    }
}
