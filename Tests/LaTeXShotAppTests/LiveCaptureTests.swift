import AppKit
import EquationRecognition
import ImageIO
import ScreenCaptureKit
import Testing
@testable import LaTeXShotApp

@MainActor
struct LiveCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATEXSHOT_LIVE_CAPTURE_FIXTURE"] != nil))
    func copiesTheSameFormulaFromPinnedPNGAndWindowCapture() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LATEXSHOT_LIVE_CAPTURE_FIXTURE"])
        try #require(CGPreflightScreenCaptureAccess())
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let pinned = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let screen = try #require(NSScreen.main)
        let window = NSPanel(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100,
                width: CGFloat(pinned.width), height: CGFloat(pinned.height)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        // Keep the test fixture behind the desktop and capture only its window.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.hasShadow = false
        let view = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        view.wantsLayer = true
        view.layer?.contents = pinned
        view.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = view
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let fixture = try #require(content.windows.first { $0.windowID == window.windowNumber })
        let displayID = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let display = try #require(content.displays.first { $0.displayID == displayID.uint32Value })
        let filter = SCContentFilter(display: display, including: [fixture])
        let selection = CaptureSelection(
            displayID: display.displayID, displayBounds: CGRect(origin: .zero, size: screen.frame.size),
            rect: window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), screenFrame: screen.frame
        )
        let recognizer = RecognitionStartup(recognizer: OfflineEquationRecognizer())
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let expected = try await recognizeAndCopy(pinned, with: recognizer, format: .raw, pasteboard: clipboard)

        let started = ContinuousClock.now
        let captured = try await selection.screenshot(contentFilter: filter)
        let capturedAt = ContinuousClock.now
        let actual = try await recognizeAndCopy(captured, with: recognizer, format: .raw, pasteboard: clipboard)
        let copied = ContinuousClock.now
        #expect(captured.width == Int(window.frame.width * screen.backingScaleFactor))
        #expect(captured.height == Int(window.frame.height * screen.backingScaleFactor))
        #expect(actual == clipboard.string(forType: .string))
        #expect(actual == expected)

        let originalPixels = try grayscalePixels(of: pinned, width: pinned.width, height: pinned.height)
        let capturedPixels = try grayscalePixels(of: captured, width: pinned.width, height: pinned.height)
        let averageDifference = Double(zip(originalPixels, capturedPixels).reduce(0) {
            $0 + abs(Int($1.0) - Int($1.1))
        }) / Double(originalPixels.count * 255)
        #expect(averageDifference < 0.05)
        print("""
            Controlled window capture \(captured.width)x\(captured.height), normalized pixel difference \(averageDifference).
            Screenshot \(started.duration(to: capturedAt)), screenshot start to private clipboard \(started.duration(to: copied)).
            """)
    }

    private func grayscalePixels(of image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(rect)
            context.interpolationQuality = .high
            context.draw(image, in: rect)
        }
        return pixels
    }
}
