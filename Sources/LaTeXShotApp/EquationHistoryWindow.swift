import Accessibility
import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class EquationHistoryWindow: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var historyChanges: AnyCancellable?
    private weak var observedPreferences: Preferences?
    let previews: HistoryPreviews
    fileprivate static let maximumWidth: CGFloat = 1_100
    private static let screenInset: CGFloat = 16

    init(previews: HistoryPreviews = HistoryPreviews()) {
        self.previews = previews
        super.init()
    }

    static func frame(in visibleFrame: CGRect, preferredSize: CGSize, anchoredTo current: CGRect? = nil) -> CGRect {
        let bounds = visibleFrame.insetBy(
            dx: min(screenInset, visibleFrame.width / 4), dy: min(screenInset, visibleFrame.height / 4)
        )
        let width = min(preferredSize.width, maximumWidth, floor(visibleFrame.width * 0.8), bounds.width)
        let height = min(preferredSize.height, bounds.height)
        return CGRect(
            x: min(max((current?.midX ?? bounds.midX) - width / 2, bounds.minX), bounds.maxX - width),
            y: min(max((current?.maxY ?? bounds.maxY) - height, bounds.minY), bounds.maxY - height),
            width: width, height: height
        )
    }

    func show(preferences: Preferences, copy: @escaping (String) -> Bool, dragText: @escaping (String) -> String) {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let panel = makePanel(in: screen.visibleFrame, preferences: preferences, copy: copy, dragText: dragText)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func makePanel(
        in visibleFrame: CGRect, preferences: Preferences,
        copy: @escaping (String) -> Bool, dragText: @escaping (String) -> String,
        cardEvaluated: ((String) -> Void)? = nil
    ) -> HistoryPanel {
        if observedPreferences !== preferences {
            observedPreferences = preferences
            historyChanges = preferences.$equationHistory.sink { [weak previews] in
                previews?.setEntries($0)
            }
        }

        let cards = HistoryCardActions(previews: previews, copy: copy, dragText: dragText)
        let panel = HistoryPanel(cards: cards)
        panel.title = "Equation History"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.hidesOnDeactivate = false
        panel.tabbingMode = .disallowed
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        let content = NSHostingController(rootView: HistoryCards(
            preferences: preferences,
            previews: previews,
            actions: cards,
            close: { [weak panel] in panel?.close() },
            resize: { [weak panel] size in
                guard let panel else { return }
                let screen = panel.isVisible ? panel.screen?.visibleFrame ?? visibleFrame : visibleFrame
                let frame = Self.frame(in: screen, preferredSize: size, anchoredTo: panel.frame)
                if frame != panel.frame {
                    panel.setFrame(frame, display: panel.isVisible)
                }
            },
            cardEvaluated: cardEvaluated
        ))
        content.sizingOptions = []
        panel.contentViewController = content
        let initialSize = previews.layout.preferredSize
        panel.setFrame(Self.frame(in: visibleFrame, preferredSize: initialSize), display: false)
        return panel
    }

    func dismiss() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === panel else { return }
        panel = nil
    }
}

final class HistoryPanel: NSPanel {
    let cards: HistoryCardActions

    init(cards: HistoryCardActions) {
        self.cards = cards
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        cards.reset()
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

@MainActor
final class HistoryCardActions: ObservableObject {
    struct Confirmation {
        let formula: String
        let entries: [String]
        let layout: HistoryCardLayout
        let previews: [String: HistoryPreviews.Preview]
    }

    enum DragFeedback: Equatable {
        case accepted(String)
        case highlighted(String)
    }

    static let confirmationDuration: Duration = .milliseconds(350)
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var dragFeedback: DragFeedback?
    @Published private(set) var copyFailed = false
    private let previews: HistoryPreviews
    private let copy: (String) -> Bool
    private let dragText: (String) -> String
    private var feedbackTask: Task<Void, Never>?
    private var draggingFormula: String?

    init(previews: HistoryPreviews, copy: @escaping (String) -> Bool, dragText: @escaping (String) -> String) {
        self.previews = previews
        self.copy = copy
        self.dragText = dragText
    }

    func select(_ formula: String, close: @escaping () -> Void) {
        // The copy promotes the formula in history. Keep the visible card strip in place until dismissal.
        let selection = Confirmation(
            formula: formula,
            entries: confirmation?.entries ?? previews.entries,
            layout: confirmation?.layout ?? previews.layout,
            previews: confirmation?.previews ?? previews.completed
        )
        feedbackTask?.cancel()
        feedbackTask = nil
        draggingFormula = nil
        if dragFeedback != nil { dragFeedback = nil }
        guard copy(formula) else {
            confirmation = nil
            copyFailed = true
            return
        }
        if copyFailed { copyFailed = false }
        confirmation = selection
        AccessibilityNotification.Announcement("Copied").post()
        feedbackTask = Task {
            try? await Task.sleep(for: Self.confirmationDuration)
            guard !Task.isCancelled else { return }
            close()
        }
    }

    func beginDrag(for formula: String) -> NSPasteboardItem {
        reset()
        draggingFormula = formula
        let item = NSPasteboardItem()
        item.setString(dragText(formula), forType: .string)
        return item
    }

    func endDrag(for formula: String, operation: NSDragOperation) {
        guard draggingFormula == formula else { return }
        draggingFormula = nil
        guard !operation.isEmpty else { return }
        dragFeedback = .accepted(formula)
        AccessibilityNotification.Announcement("Dropped").post()
        feedbackTask = Task {
            try? await Task.sleep(for: Self.confirmationDuration)
            guard !Task.isCancelled else { return }
            dragFeedback = .highlighted(formula)
        }
    }

    func moveFocus(to formula: String) {
        if case .highlighted(let previous) = dragFeedback, previous != formula {
            dragFeedback = nil
        }
    }

    func reset() {
        feedbackTask?.cancel()
        feedbackTask = nil
        draggingFormula = nil
        if confirmation != nil { confirmation = nil }
        if dragFeedback != nil { dragFeedback = nil }
        if copyFailed { copyFailed = false }
    }
}

@MainActor
final class HistoryPreviews: ObservableObject {
    enum Preview {
        case image(NSImage)
        case failed(CGSize)

        var size: CGSize {
            switch self {
            case .image(let image): image.size
            case .failed(let size): size
            }
        }
    }

    private let render: (String) async throws -> NSImage?
    private var queue: Task<Void, Never>?
    private var queuedIndex = 0
    private var visible: [String] = []
    private var stored: Set<String> = []
    // Publish offscreen results in batches so the strip's sizes and offsets update together.
    private var pendingUpdates: [String: Preview] = [:]
    private(set) var entries: [String] = []
    private(set) var completed: [String: Preview] = [:]
    private(set) var layout = HistoryCardLayout(entries: [], completed: [:])

    init() {
        // Create the WebKit instance only after the first history panel schedules work.
        var renderer: FormulaRenderer?
        render = { formula in
            if renderer == nil { renderer = FormulaRenderer() }
            guard let view = try await renderer?.render(formula: formula, naturalSize: true) else { return nil }
            return try await HistoryFormulaPreview.makeImage(from: view)
        }
    }

    init(render: @escaping (String) async throws -> NSImage?) {
        self.render = render
    }

    deinit { queue?.cancel() }

    func setEntries(_ entries: [String]) {
        objectWillChange.send()
        self.entries = entries
        stored = Set(entries)
        completed = completed.filter { stored.contains($0.key) }
        pendingUpdates = pendingUpdates.filter { stored.contains($0.key) }
        queuedIndex = 0
        updateLayout()
        startQueue()
    }

    func prioritize(_ entries: ArraySlice<String>) {
        visible = Array(entries)
    }

    private func startQueue() {
        guard queue == nil, !entries.isEmpty else { return }
        queue = Task { [weak self] in
            var nextUpdate = ContinuousClock.now
            while !Task.isCancelled, let formula = self?.nextFormula(), let render = self?.render {
                let image = try? await render(formula)
                guard let self, !Task.isCancelled else { return }
                guard stored.contains(formula) else { continue }
                pendingUpdates[formula] = image.map(Preview.image) ?? .failed(HistoryCard.fallbackSize(for: formula))
                let now = ContinuousClock.now
                if visible.contains(formula) || now >= nextUpdate {
                    publishUpdates()
                    nextUpdate = now + .milliseconds(32)
                }
            }
            self?.queue = nil
            self?.publishUpdates()
        }
    }

    private func publishUpdates() {
        guard !pendingUpdates.isEmpty else { return }
        objectWillChange.send()
        updateLayout()
    }

    private func updateLayout() {
        completed.merge(pendingUpdates) { _, latest in latest }
        pendingUpdates.removeAll(keepingCapacity: true)
        layout = HistoryCardLayout(entries: entries, completed: completed)
    }

    private func needsPreview(_ formula: String) -> Bool {
        completed[formula] == nil && pendingUpdates[formula] == nil
    }

    private func nextFormula() -> String? {
        if let formula = visible.first(where: { stored.contains($0) && needsPreview($0) }) {
            return formula
        }
        while queuedIndex < entries.count {
            let formula = entries[queuedIndex]
            queuedIndex += 1
            if needsPreview(formula) { return formula }
        }
        return nil
    }
}

@MainActor
struct HistoryCardLayout {
    static let inset: CGFloat = 12
    static let spacing: CGFloat = 8
    static let pendingSize = CGSize(width: 64, height: 32)
    static let footer = "Click to copy, or drag to another app."
    private static let minimumWidth = max(
        240, (footer as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 2 * inset
    )

    let offsets: [CGFloat]
    let width: CGFloat
    let height: CGFloat
    let preferredSize: CGSize

    init(entries: [String], completed: [String: HistoryPreviews.Preview]) {
        var offsets = [Self.inset]
        offsets.reserveCapacity(entries.count + 1)
        var tallest = Self.pendingSize.height
        var leadingHeight = tallest
        for (index, formula) in entries.enumerated() {
            let size = completed[formula]?.size ?? Self.pendingSize
            offsets.append(offsets[index] + size.width + 2 * HistoryCard.padding + Self.spacing)
            tallest = max(tallest, size.height)
            if offsets[index] < EquationHistoryWindow.maximumWidth {
                leadingHeight = max(leadingHeight, size.height)
            }
        }
        self.offsets = offsets
        width = (offsets.last ?? Self.inset) - Self.spacing + Self.inset
        height = tallest + 2 * (Self.inset + HistoryCard.padding)
        preferredSize = entries.isEmpty ? CGSize(width: 340, height: 166)
            : CGSize(width: ceil(max(width, Self.minimumWidth)), height: leadingHeight + 106)
    }

    func indices(overlapping viewport: CGRect) -> Range<Int> {
        let count = offsets.count - 1
        let start = max(0, lowerBound(viewport.minX) - 1)
        return min(start, count)..<min(max(start, lowerBound(viewport.maxX)), count)
    }

    private func lowerBound(_ x: CGFloat) -> Int {
        var lower = 0
        var upper = offsets.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if offsets[middle] < x {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

private struct HistoryCards: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var previews: HistoryPreviews
    @ObservedObject var actions: HistoryCardActions
    let close: () -> Void
    let resize: (CGSize) -> Void
    let cardEvaluated: ((String) -> Void)?
    @State private var confirmingClear = false
    @State private var viewport = CGRect(x: 0, y: 0, width: EquationHistoryWindow.maximumWidth, height: 0)

    var body: some View {
        let confirmation = actions.confirmation
        let entries = confirmation?.entries ?? previews.entries
        let layout = confirmation?.layout ?? previews.layout
        let completed = confirmation?.previews ?? previews.completed
        VStack(alignment: .leading, spacing: 0) {
            header
            if entries.isEmpty {
                ContentUnavailableView(
                    "No copied equations", systemImage: "function",
                    description: Text("Equations you capture and copy will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let visible = layout.indices(overlapping: viewport)
                let overscan = viewport.insetBy(dx: -80, dy: 0)
                let mounted = layout.indices(overlapping: overscan)
                ScrollView([.horizontal, .vertical]) {
                    // Mount only nearby cards inside a document with explicit offsets and dimensions.
                    HStack(alignment: .top, spacing: HistoryCardLayout.spacing) {
                        ForEach(mounted, id: \.self) { index in
                            let formula = entries[index]
                            HistoryCard(
                                formula: formula, preview: completed[formula],
                                confirmed: confirmation?.formula == formula || actions.dragFeedback == .accepted(formula),
                                selected: actions.dragFeedback == .highlighted(formula),
                                select: { actions.select(formula, close: close) },
                                focus: { actions.moveFocus(to: formula) },
                                beginDrag: { actions.beginDrag(for: formula) },
                                endDrag: { actions.endDrag(for: formula, operation: $0) },
                                evaluated: cardEvaluated
                            )
                            .id(formula)
                        }
                    }
                    .offset(x: layout.offsets[mounted.lowerBound], y: HistoryCardLayout.inset)
                    .frame(width: layout.width, height: layout.height, alignment: .topLeading)
                    .onGeometryChange(for: CGRect?.self) { $0.bounds(of: .scrollView) } action: { bounds in
                        if let bounds { viewport = bounds }
                    }
                }
                .onChange(of: Array(entries[visible]), initial: true) {
                    previews.prioritize(entries[visible])
                }
                .onDisappear { previews.prioritize([]) }
                Divider()
                Text(footer(confirmation: confirmation))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, HistoryCardLayout.inset)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { HistoryMaterial().allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: layout.preferredSize, initial: true) { _, size in
            resize(size)
        }
    }

    private func footer(confirmation: HistoryCardActions.Confirmation?) -> String {
        if confirmation != nil { return "Copied" }
        if case .accepted = actions.dragFeedback { return "Dropped" }
        if actions.copyFailed { return "Couldn’t copy to the clipboard. Try again." }
        return HistoryCardLayout.footer
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close Equation History")
            .help("Close Equation History")

            ZStack(alignment: .leading) {
                HistoryDragRegion()
                Text("Equation History")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, minHeight: 26)

            Button {
                confirmingClear = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(preferences.equationHistory.isEmpty)
            .accessibilityLabel("Clear Equation History")
            .help("Clear Equation History")
            .popover(isPresented: $confirmingClear) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Clear Equation History?").font(.headline)
                    Text("This removes all locally saved equations.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { confirmingClear = false }
                            .keyboardShortcut(.cancelAction)
                        Button("Clear History", role: .destructive) {
                            confirmingClear = false
                            actions.reset()
                            preferences.clearEquationHistory()
                        }
                    }
                }
                .padding(16)
                .frame(width: 272)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}

private struct HistoryMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct HistoryDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct HistoryCard: View {
    static let padding: CGFloat = 8
    private static let fallbackFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    let formula: String
    let preview: HistoryPreviews.Preview?
    let confirmed: Bool
    let selected: Bool
    let select: () -> Void
    let focus: () -> Void
    let beginDrag: () -> NSPasteboardItem
    let endDrag: (NSDragOperation) -> Void
    let evaluated: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    @FocusState private var focused: Bool

    static func fallbackSize(for formula: String) -> CGSize {
        let lineWidths = formula.components(separatedBy: .newlines).map {
            ($0 as NSString).size(withAttributes: [.font: fallbackFont]).width
        }
        return CGSize(width: max(24, ceil(lineWidths.max() ?? 0) + 8), height: max(32, CGFloat(lineWidths.count) * 16))
    }

    var body: some View {
        let _ = evaluated?(formula)
        let tint: Color = confirmed ? .green : .accentColor
        let highlighted = confirmed || selected || hovered || focused
        previewContent
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(confirmed ? 0.24 : (highlighted ? 0.09 : 0)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        tint.opacity(confirmed ? 0.9 : (focused ? 0.8 : (highlighted ? 0.4 : 0))),
                        lineWidth: focused && !confirmed ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                HistoryCardPointer(
                    press: { focused = true }, hover: { hovered = $0 }, select: select,
                    beginDrag: beginDrag, dragImage: dragImage, endDrag: endDrag
                )
                .accessibilityHidden(true)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of: focused) {
                if focused { focus() }
            }
            .onKeyPress(keys: [.return, .space]) { _ in
                select()
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(formula))
            .accessibilityHint("Copies equation and closes history")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, select)
            .fixedSize()
    }

    private func dragImage(scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: previewContent
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .environment(\.colorScheme, colorScheme))
        renderer.scale = scale
        return renderer.nsImage
    }

    private var previewContent: some View {
        let size = preview?.size ?? HistoryCardLayout.pendingSize
        return Group {
            switch preview {
            case .image(let image):
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
            case .failed:
                Text(formula)
                    .font(.system(size: 13, design: .monospaced))
                    .fixedSize()
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: size.width, height: size.height)
        .padding(Self.padding)
    }
}

private struct HistoryCardPointer: NSViewRepresentable {
    let press: () -> Void
    let hover: (Bool) -> Void
    let select: () -> Void
    let beginDrag: () -> NSPasteboardItem
    let dragImage: (CGFloat) -> NSImage?
    let endDrag: (NSDragOperation) -> Void

    func makeNSView(context: Context) -> PointerView { PointerView() }

    func updateNSView(_ view: PointerView, context: Context) {
        view.actions = self
    }

    final class PointerView: NSView, NSDraggingSource {
        var actions: HistoryCardPointer?
        private var hoverArea: NSTrackingArea?
        private var mouseDownEvent: NSEvent?
        private var completeDrag: ((NSDragOperation) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) { actions?.hover(true) }
        override func mouseExited(with event: NSEvent) { actions?.hover(false) }

        override func scrollWheel(with event: NSEvent) {
            if let scrollView = enclosingScrollView {
                scrollView.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            actions?.press()
        }

        override func mouseUp(with event: NSEvent) {
            guard mouseDownEvent != nil else { return }
            mouseDownEvent = nil
            if bounds.contains(convert(event.locationInWindow, from: nil)) {
                actions?.select()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let actions, let mouseDownEvent else { return }
            let start = mouseDownEvent.locationInWindow
            let point = event.locationInWindow
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
            self.mouseDownEvent = nil
            completeDrag = actions.endDrag
            let item = NSDraggingItem(pasteboardWriter: actions.beginDrag())
            item.setDraggingFrame(bounds, contents: actions.dragImage(window?.backingScaleFactor ?? 1))
            beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            let completion = completeDrag
            completeDrag = nil
            completion?(operation)
        }
    }
}

@MainActor
enum HistoryFormulaPreview {
    static func makeImage(from webView: WKWebView) async throws -> NSImage? {
        let dimensions = try await webView.evaluateJavaScript("""
            (() => {
                const bounds = document.body.getBoundingClientRect();
                return [Math.ceil(bounds.width), Math.ceil(bounds.height)];
            })()
            """) as? [CGFloat]
        guard let dimensions, dimensions.count == 2,
              dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        // Keep WebKit offscreen and tint the exported transparent vector image in the native card.
        let size = CGSize(width: dimensions[0], height: dimensions[1])
        // Bound the WebKit capture surface. The PDF remains vector and the card keeps its natural size.
        let scale = min(1, 2048 / max(size.width, size.height))
        let bounds = CGRect(x: 0, y: 0, width: ceil(size.width * scale), height: ceil(size.height * scale))
        webView.frame = bounds
        _ = try await webView.callAsyncJavaScript(
            """
            document.body.style.transformOrigin = 'top left';
            document.body.style.transform = 'scale(' + scale + ')';
            return document.body.getBoundingClientRect().width;
            """,
            arguments: ["scale": scale], in: nil, contentWorld: .page
        )
        let configuration = WKPDFConfiguration()
        configuration.allowTransparentBackground = true
        configuration.rect = bounds
        let data = try await webView.pdf(configuration: configuration)
        let image = NSImage(data: data)
        image?.size = size
        return image
    }
}
