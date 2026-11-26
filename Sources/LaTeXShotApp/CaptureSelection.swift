import AppKit
import ScreenCaptureKit

struct CaptureSelection {
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let rect: CGRect
    let screenFrame: CGRect

    /// AppKit selection points are local to the display and increase upward.
    func pixelRect(scale: CGFloat, imageSize: CGSize) -> CGRect {
        CGRect(
            x: (rect.minX - displayBounds.minX) * scale,
            y: (displayBounds.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(CGRect(origin: .zero, size: imageSize))
    }

    @MainActor
    func screenshot() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let selfApplications = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: selfApplications, exceptingWindows: [])
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        return try await screenshot(contentFilter: filter)
    }

    @MainActor
    func screenshot(contentFilter filter: SCContentFilter) async throws -> CGImage {
        let scale = CGFloat(filter.pointPixelScale)
        let displayPixelSize = CGSize(
            width: (filter.contentRect.width * scale).rounded(),
            height: (filter.contentRect.height * scale).rounded()
        )
        let crop = pixelRect(scale: scale, imageSize: displayPixelSize)
        guard !crop.isEmpty else { throw CaptureError.emptyCrop }

        let configuration = SCStreamConfiguration()
        // ScreenCaptureKit takes the source rectangle in points and output dimensions in pixels.
        configuration.sourceRect = crop.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        configuration.width = Int(crop.width)
        configuration.height = Int(crop.height)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    enum CaptureError: Error {
        case displayUnavailable
        case emptyCrop
    }
}

@MainActor
final class CaptureOverlay {
    private var panels: [CapturePanel] = []
    private var continuation: CheckedContinuation<CaptureSelection?, Never>?
    private var previousApp: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?

    func select(
        dimmingOpacity: CGFloat = CGFloat(Preferences.defaultCaptureDimmingPercent) / 100
    ) async -> CaptureSelection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            previousApp = NSWorkspace.shared.frontmostApplication
            previousKeyWindow = NSApp.keyWindow
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    continue
                }
                let screenFrame = screen.frame
                let displayBounds = CGRect(origin: .zero, size: screenFrame.size)
                let view = SelectionView(frame: displayBounds, dimmingOpacity: dimmingOpacity)
                view.onComplete = { [weak self] rect in
                    self?.complete(rect.map {
                        CaptureSelection(
                            displayID: number.uint32Value,
                            displayBounds: displayBounds,
                            rect: $0,
                            screenFrame: screenFrame
                        )
                    })
                }
                let panel = CapturePanel(
                    contentRect: screenFrame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false,
                    screen: screen
                )
                panel.contentView = view
                panel.isOpaque = false
                panel.hasShadow = false
                panel.backgroundColor = .clear
                panel.ignoresMouseEvents = false
                panel.level = .screenSaver
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.orderFrontRegardless()
                panels.append(panel)
            }
            guard let keyPanel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first else {
                complete(nil)
                return
            }
            keyPanel.makeKey()
            keyPanel.makeFirstResponder(keyPanel.contentView)
        }
    }

    private func complete(_ selection: CaptureSelection?) {
        guard let continuation else { return }
        self.continuation = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousKeyWindow?.makeKey()
        } else if let previousApp, !previousApp.isActive, NSApp.isActive {
            previousApp.activate()
        }
        previousApp = nil
        previousKeyWindow = nil
        continuation.resume(returning: selection)
    }
}


final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    let dimmingOpacity: CGFloat
    private var origin: CGPoint?
    private var selection: CGRect = .zero

    init(frame: CGRect, dimmingOpacity: CGFloat) {
        self.dimmingOpacity = dimmingOpacity
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: CGRect) {
        if dimmingOpacity > 0 {
            let shade = NSBezierPath(rect: bounds)
            shade.windingRule = .evenOdd
            if !selection.isEmpty {
                shade.appendRect(selection)
            }
            NSColor.black.withAlphaComponent(dimmingOpacity).setFill()
            shade.fill()
        } else {
            // Fully transparent window pixels can pass clicks through to the window below.
            NSColor.black.withAlphaComponent(1.0 / 255).setFill()
            dirtyRect.fill(using: .copy)
        }
        if !selection.isEmpty {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        origin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelection(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        updateSelection(to: convert(event.locationInWindow, from: nil))
        onComplete?(selection.width >= 2 && selection.height >= 2 ? selection : nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onComplete?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private func updateSelection(to point: CGPoint) {
        guard let origin else { return }
        selection = CGRect(
            x: min(origin.x, point.x),
            y: min(origin.y, point.y),
            width: abs(origin.x - point.x),
            height: abs(origin.y - point.y)
        ).intersection(bounds)
        needsDisplay = true
    }
}
