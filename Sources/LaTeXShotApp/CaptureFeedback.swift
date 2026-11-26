import AppKit
import SwiftUI
import WebKit

@MainActor
final class CaptureFeedback {
    private(set) var panel: NSPanel?
    private var renderer: FormulaRenderer?
    private var dismissTask: Task<Void, Never>?

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        renderer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func showCopied(formula: String, on screenFrame: CGRect) {
        show("Copied", icon: "checkmark.circle.fill", on: screenFrame)
        guard let panel else { return }

        renderer = FormulaRenderer(formula: formula) { [weak self, weak panel] webView in
            guard let self, let panel, panel === self.panel else { return }
            let frame = panel.frame
            let height: CGFloat = 86
            panel.setFrame(CGRect(
                x: frame.minX, y: frame.minY - height, width: frame.width, height: frame.height + height
            ), display: true)
            guard let contentView = panel.contentView else { return }
            webView.frame = CGRect(x: 10, y: 8, width: frame.width - 20, height: height - 8)
            webView.isHidden = false
            contentView.addSubview(webView, positioned: .below, relativeTo: contentView.subviews.first)
            self.scheduleDismissal()
        }
    }

    func showProcessing(on screenFrame: CGRect) {
        show("Processing…", icon: nil, on: screenFrame, showsProgress: true, dismissAutomatically: false)
    }

    func showFailure(_ message: String, on screenFrame: CGRect) {
        show(message, icon: "exclamationmark.circle", on: screenFrame)
    }

    private func show(
        _ message: String,
        icon: String?,
        on screenFrame: CGRect,
        showsProgress: Bool = false,
        dismissAutomatically: Bool = true
    ) {
        dismiss()

        let visibleFrame = NSScreen.screens.first(where: { $0.frame == screenFrame })?.visibleFrame ?? screenFrame
        let size = CGSize(width: min(348, visibleFrame.width - 24), height: 48)
        let frame = CGRect(
            x: visibleFrame.maxX - size.width - 12,
            y: visibleFrame.maxY - size.height - 12,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]

        let title = NSHostingView(rootView: CaptureFeedbackTitle(
            message: message, icon: icon, showsProgress: showsProgress
        ))
        title.frame = background.bounds.insetBy(dx: 12, dy: 0)
        title.autoresizingMask = [.width, .minYMargin]
        title.setAccessibilityElement(true)
        title.setAccessibilityLabel(message)
        background.addSubview(title)
        panel.contentView = background
        self.panel = panel

        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
        if dismissAutomatically {
            scheduleDismissal()
        }
    }

    private func scheduleDismissal() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}

private struct CaptureFeedbackTitle: View {
    let message: String
    let icon: String?
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Processing")
            } else if let icon {
                Image(systemName: icon)
            }
            Text(message)
        }
        .font(.system(.body, weight: .semibold))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

@MainActor
final class FormulaRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var preparation: ((Bool) -> Void)?
    private var didLoad = false

    init(size: CGSize = CGSize(width: 328, height: 78)) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        super.init()
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = self
    }

    convenience init(
        formula: String, size: CGSize = CGSize(width: 328, height: 78),
        naturalSize: Bool = false, didFail: @escaping () -> Void = {},
        didRender: @escaping (WKWebView) -> Void
    ) {
        self.init(size: size)
        Task { [weak self] in
            guard let self else { return }
            do {
                if let webView = try await render(formula: formula, naturalSize: naturalSize) {
                    didRender(webView)
                } else {
                    didFail()
                }
            } catch {
                didFail()
            }
        }
    }

    func render(formula: String, naturalSize: Bool) async throws -> WKWebView? {
        if !didLoad {
            guard let html = Bundle.module.url(forResource: "formula", withExtension: "html",
                                               subdirectory: "MathRenderer") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                preparation = { continuation.resume(returning: $0) }
                webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
            }
            guard loaded else { throw CocoaError(.fileReadUnknown) }
        }
        let rendered = try await webView.callAsyncJavaScript(
            """
            document.body.style.transform = '';
            return await renderFormula(formula, naturalSize);
            """,
            arguments: ["formula": formula, "naturalSize": naturalSize], in: nil, contentWorld: .page
        )
        return rendered as? Bool == true ? webView : nil
    }

    private func finishPreparation(loaded: Bool) {
        didLoad = loaded
        let completion = preparation
        preparation = nil
        completion?(loaded)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishPreparation(loaded: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishPreparation(loaded: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishPreparation(loaded: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishPreparation(loaded: false)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(!didLoad && navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}
