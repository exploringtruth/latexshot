import AppKit
import Testing
import WebKit
@testable import LaTeXShotApp

@MainActor
@Suite(.serialized)
struct HistoryPreviewTests {
    nonisolated private static let differential = "y''(t) + 3 y'(t) + 2y(t)=0"
    nonisolated private static let long = Array(repeating: "x^2 + y^2 + z^2", count: 36).joined(separator: " + ")

    @Test(arguments: [
        (differential, CGSize(width: 174, height: 15), false),
        (#"\frac{\frac{1}{x}}{\frac{y}{\frac{z}{w}}}"#, CGSize(width: 10, height: 50), false),
        (#"\sqrt{\sqrt{\begin{pmatrix} a & b \\ c & d \\ e & f \end{pmatrix}}}"#,
            CGSize(width: 40, height: 55), false),
        (#"\root 3 \of {x}"#, CGSize(width: 10, height: 10), true),
        (long, CGSize(width: 2000, height: 15), false)
    ])
    func exportsTransparentNaturalSizePreview(input: String, minimum: CGSize, expectsMathJax: Bool) async throws {
        let (views, continuation) = AsyncStream<WKWebView>.makeStream()
        let renderer = FormulaRenderer(formula: input, size: CGSize(width: 90, height: 32), naturalSize: true,
                                      didFail: { continuation.finish() }) { webView in
            continuation.yield(webView)
            continuation.finish()
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = views.makeAsyncIterator()
        let webView = try #require(await iterator.next())
        defer { withExtendedLifetime(renderer) {} }

        let correctEngine = try await webView.evaluateJavaScript(
            expectsMathJax ? "!!document.querySelector('mjx-container svg')" : "!!document.querySelector('.katex')"
        )
        #expect(correctEngine as? Bool == true)
        let naturalGeometry = try await webView.evaluateJavaScript("""
            (() => {
                const box = document.getElementById('formula').getBoundingClientRect();
                const body = document.body.getBoundingClientRect();
                return box.left >= 4 && box.top >= 4 &&
                    box.right <= body.right - 4 && box.bottom <= body.bottom - 4 &&
                    getComputedStyle(document.getElementById('formula')).transform === 'none';
            })()
            """)
        #expect(naturalGeometry as? Bool == true)
        let image = try #require(await HistoryFormulaPreview.makeImage(from: webView))
        #expect(image.size.width > minimum.width)
        #expect(image.size.height > minimum.height)

        let rep = try #require(image.representations.first as? NSPDFImageRep)
        let provider = try #require(CGDataProvider(data: rep.pdfRepresentation as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        let page = try #require(pdf.page(at: 1))
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let pageBounds = page.getBoxRect(.mediaBox)
        context.scaleBy(x: image.size.width / pageBounds.width, y: image.size.height / pageBounds.height)
        context.drawPDFPage(page)
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            pixels[y * context.bytesPerRow + 4 * x + 3]
        }
        func hasInk(in columns: Range<Int>) -> Bool {
            columns.contains { x in (0..<height).contains { alpha(x, $0) > 64 } }
        }
        #expect((0..<width).allSatisfy { alpha($0, 0) == 0 && alpha($0, height - 1) == 0 })
        #expect((0..<height).allSatisfy { alpha(0, $0) == 0 && alpha(width - 1, $0) == 0 })
        #expect(hasInk(in: 0..<min(32, width)))
        #expect(hasInk(in: max(0, width - 32)..<width))

        if input == Self.long {
            let available = CGRect(x: 0, y: 0, width: 480, height: 180)
            let window = EquationHistoryWindow.frame(in: available, preferredSize: image.size)
            #expect(window.width == 384)
            #expect(image.size.width > 4 * window.width)
        }
    }

    @Test func offscreenHistoryScrollsPastScreenWidth() async throws {
        let domain = "LaTeXShot.HistoryPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        preferences.recordCopiedEquation(Self.long)
        let history = EquationHistoryWindow()
        let panel = history.makePanel(
            in: CGRect(x: 0, y: 0, width: 480, height: 180),
            preferences: preferences, copy: { _ in false }, dragText: { $0 }
        )
        defer { panel.close() }
        let content = try #require(panel.contentView)

        content.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollView(in: content))
        let document = try #require(scroll.documentView)
        #expect(!panel.isVisible)
        #expect(panel.frame.width < 384)
        try await waitUntil { document.frame.width > 2000 && panel.frame.width == 384 }
        #expect(document.frame.width > 2000)
        let clip = scroll.contentView
        let trailing = document.frame.width - clip.bounds.width
        try #require(trailing > 0)
        clip.scroll(to: CGPoint(x: trailing, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
        #expect(abs(clip.bounds.maxX - document.frame.maxX) < 3)
    }

    @Test func rendersOffscreenEntriesAndRetainsPreviewsAcrossScrollingAndReopening() async throws {
        let domain = "LaTeXShot.HistoryPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let entries = (1...24).map { "x_{\($0)}" } + ["\\undefinedHistoryMacro"]
        defaults.setPersistentDomain(
            ["equationHistoryLimit": entries.count, "equationHistory": entries],
            forName: domain
        )
        let preferences = Preferences(defaults: defaults)
        let history = EquationHistoryWindow()
        #expect(history.previews.completed.isEmpty)
        var evaluated: Set<String> = []
        func makePanel() -> NSPanel {
            history.makePanel(
                in: CGRect(x: 0, y: 0, width: 480, height: 320),
                preferences: preferences, copy: { _ in false }, dragText: { $0 },
                cardEvaluated: { evaluated.insert($0) }
            )
        }
        let panel = makePanel()
        defer { panel.close() }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollView(in: content))
        let document = try #require(scroll.documentView)

        try await waitUntil { history.previews.completed.count == entries.count }
        let first = try #require(history.previews.completed[entries[0]])
        let offscreen = try #require(history.previews.completed[entries[20]])
        let failed = try #require(history.previews.completed[entries[24]])
        guard case .image(let firstImage) = first, case .image = offscreen, case .failed = failed else {
            Issue.record("Expected typeset results and a failed result for the invalid formula")
            return
        }
        #expect(!evaluated.contains(entries[20]))

        let clip = scroll.contentView
        scrollTo(CGPoint(x: document.frame.width - clip.bounds.width, y: 0), in: scroll)
        try await waitUntil { evaluated.contains(entries[20]) }
        evaluated.removeAll()
        scrollTo(.zero, in: scroll)
        try await waitUntil { evaluated.contains(entries[0]) }
        panel.close()
        let reopened = makePanel()
        defer { reopened.close() }
        guard case .image(let reopenedImage) = history.previews.completed[entries[0]] else {
            Issue.record("Expected a retained preview when browsing the panel again")
            return
        }
        #expect(reopenedImage === firstImage)
        preferences.setHistoryLimit(1)
        #expect(history.previews.completed.count == 1)
        reopened.close()
        preferences.clearEquationHistory()
        #expect(history.previews.completed.isEmpty)
    }

    @Test func rendersAtMostOneFormulaAndPrioritizesVisibleCards() async throws {
        var rendered: [String] = []
        var active = 0
        let previews = HistoryPreviews { formula in
            active += 1
            #expect(active == 1)
            await Task.yield()
            rendered.append(formula)
            active -= 1
            return NSImage(size: CGSize(width: 24, height: 32))
        }
        let entries = (0..<100).map(String.init)
        previews.setEntries(entries)
        previews.prioritize(entries[75..<77])
        try await waitUntil { previews.completed.count == entries.count }
        #expect(rendered.prefix(3) == [entries[75], entries[76], entries[0]])
        #expect(Set(rendered) == Set(entries))
        #expect(rendered.count == entries.count)
    }

    @Test func fullHistoryMountsOnlyNearbyCardsAndEndsAtTheOldestEquation() async throws {
        let domain = "LaTeXShot.HistoryPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let entries = (1...5_000).map { "x_{\($0)}" }
        let oldest = try #require(entries.last)
        defaults.setPersistentDomain(
            ["equationHistoryLimit": entries.count, "equationHistory": entries],
            forName: domain
        )
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.equationHistory.count == 5_000)
        let previews = HistoryPreviews { formula in
            NSImage(size: formula == oldest ? CGSize(width: 300, height: 360) : CGSize(width: 24, height: 32))
        }
        let history = EquationHistoryWindow(previews: previews)
        var evaluated: Set<String> = []
        let panel = history.makePanel(
            in: CGRect(x: 0, y: 0, width: 480, height: 320),
            preferences: preferences, copy: { _ in false }, dragText: { $0 },
            cardEvaluated: { evaluated.insert($0) }
        )
        defer { panel.close() }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollView(in: content))
        let document = try #require(scroll.documentView)
        let clip = scroll.contentView
        #expect(!panel.isVisible)
        #expect(panel.frame.width == 384)
        let expectedWidth: CGFloat = 24 + 4_999 * 48 + 300 + 16
        try await waitUntil { abs(document.frame.width - expectedWidth) < 1 }
        #expect(evaluated.contains(entries[0]))
        #expect(evaluated.count < 30)

        scrollTo(CGPoint(x: document.frame.width - clip.bounds.width, y: 0), in: scroll)
        try await waitUntil { evaluated.contains(oldest) }
        #expect(evaluated.count < 60)
        #expect(abs(clip.bounds.maxX - document.frame.maxX) < 1)
        let bottom = document.frame.height - clip.bounds.height
        try #require(bottom > 0)
        scrollTo(CGPoint(x: clip.bounds.minX, y: bottom), in: scroll)
        #expect(abs(clip.bounds.maxY - document.frame.maxY) < 1)
    }

    @Test func dragExportsExactPlainTextAndConfirmsOnlyAnAcceptedDrop() async throws {
        let domain = "LaTeXShot.HistoryPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        preferences.clipboardFormat = .custom
        preferences.customPrefix = " \n["
        preferences.customSuffix = "]\n "
        let formula = #"\frac{1}{x}"#
        preferences.recordCopiedEquation(formula)
        preferences.recordCopiedEquation("newer")
        let history = EquationHistoryWindow(previews: HistoryPreviews { _ in nil })
        var copies = 0
        let panel = history.makePanel(
            in: CGRect(x: 0, y: 0, width: 480, height: 320), preferences: preferences,
            copy: { _ in
                copies += 1
                return true
            },
            dragText: { preferences.clipboardFormat.wrap(
                $0, prefix: preferences.customPrefix, suffix: preferences.customSuffix
            ) }
        )
        defer { panel.close() }
        let item = panel.cards.beginDrag(for: formula)
        #expect(item.types == [.string])
        #expect(item.string(forType: .string) == " \n[" + formula + "]\n ")
        #expect(copies == 0)
        #expect(preferences.equationHistory == ["newer", formula])
        #expect(panel.cards.confirmation == nil)
        #expect(panel.cards.dragFeedback == nil)
        panel.cards.endDrag(for: formula, operation: [])
        #expect(panel.cards.dragFeedback == nil)

        var closed = false
        panel.cards.select(formula) {
            closed = true
            panel.close()
        }
        try #require(panel.cards.confirmation != nil)
        _ = panel.cards.beginDrag(for: formula)
        #expect(panel.cards.confirmation == nil)
        panel.cards.endDrag(for: formula, operation: .copy)
        #expect(panel.cards.dragFeedback == .accepted(formula))
        try await waitUntil { panel.cards.dragFeedback == .highlighted(formula) }
        #expect(copies == 1)
        #expect(panel.cards.confirmation == nil)
        #expect(!closed)
        #expect(preferences.equationHistory == ["newer", formula])
        panel.cards.moveFocus(to: formula)
        #expect(panel.cards.dragFeedback == .highlighted(formula))
        panel.cards.moveFocus(to: "newer")
        #expect(panel.cards.dragFeedback == nil)

        _ = panel.cards.beginDrag(for: formula)
        panel.close()
        panel.cards.endDrag(for: formula, operation: .copy)
        #expect(panel.cards.dragFeedback == nil)
    }

    @Test func failedCopyAndManualCloseDoNotScheduleAStaleDismissal() async throws {
        let domain = "LaTeXShot.HistoryPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        preferences.recordCopiedEquation("x")
        let history = EquationHistoryWindow(previews: HistoryPreviews { _ in nil })
        var canCopy = false
        func makePanel() -> HistoryPanel {
            history.makePanel(
                in: CGRect(x: 0, y: 0, width: 480, height: 320), preferences: preferences,
                copy: { _ in canCopy }, dragText: { $0 }
            )
        }
        let panel = makePanel()
        defer { panel.close() }
        var delayedCloses = 0
        panel.cards.select("x") { delayedCloses += 1 }
        #expect(panel.cards.copyFailed)
        #expect(panel.cards.confirmation == nil)
        try await Task.sleep(for: HistoryCardActions.confirmationDuration + .milliseconds(50))
        #expect(delayedCloses == 0)

        canCopy = true
        panel.cards.select("x") { delayedCloses += 1 }
        try #require(panel.cards.confirmation != nil)
        #expect(!panel.cards.copyFailed)
        panel.close()
        #expect(panel.cards.confirmation == nil)

        let reopened = makePanel()
        defer { reopened.close() }
        try await Task.sleep(for: HistoryCardActions.confirmationDuration + .milliseconds(50))
        #expect(delayedCloses == 0)
        #expect(reopened.cards.confirmation == nil)
        #expect(!reopened.cards.copyFailed)
    }

    private func waitUntil(_ reached: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !reached() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(reached())
    }

    private func scrollTo(_ point: CGPoint, in scroll: NSScrollView) {
        scroll.contentView.scroll(to: point)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

}
