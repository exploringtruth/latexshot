import AppKit
import EquationRecognition
import Foundation
import Testing
@testable import LaTeXShotApp

@MainActor
struct LatencyBenchmark {
    @Test func mouseUpToPrivateClipboard() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment["LATEXSHOT_LATENCY_FIXTURE"])
        let fixtures = try #require(environment["LATEXSHOT_LATENCY_IMAGE"])
        let output = try #require(environment["LATEXSHOT_LATENCY_JSON"])
        let samples = Int(environment["LATEXSHOT_LATENCY_SAMPLES"] ?? "") ?? 60
        try #require(samples > 0)
        try #require(CGPreflightScreenCaptureAccess(), "Screen Recording must already be granted.")
        let app = NSApplication.shared

        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: fixturePath)
        fixture.arguments = [fixtures]
        let ready = Pipe()
        fixture.standardOutput = ready
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate() } }

        let line = try #require(String(data: ready.fileHandleForReading.availableData, encoding: .utf8))
        let coordinates = line.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        try #require(coordinates.count == 6)
        let displayID = UInt32(coordinates[0])
        let scale = coordinates[1]
        let fixtureFrame = CGRect(x: coordinates[2], y: coordinates[3], width: coordinates[4], height: coordinates[5])
        let screen = try #require(NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        })
        let pointSize = screen.frame.size
        let fixtureRect = fixtureFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)

        let overlay = CaptureOverlay()
        let recognizer = OfflineEquationRecognizer()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try await Task.sleep(for: .milliseconds(200))

        var results: [Measurement] = []
        var firstBody: String?
        for index in 0..<(samples + 1) {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let selectionTask = Task { await overlay.select() }
            try await Task.sleep(for: .milliseconds(2))
            let panel = try #require(app.windows.first { $0.level == .screenSaver && $0.frame.size == pointSize && $0.isVisible })
            let view = try #require(panel.contentView)
            let down = try makeEvent(.leftMouseDown, at: fixtureRect.origin, window: panel)
            let end = CGPoint(x: fixtureRect.maxX, y: fixtureRect.maxY)
            let up = try makeEvent(.leftMouseUp, at: end, window: panel)
            view.mouseDown(with: down)
            let oldChangeCount = pasteboard.changeCount

            let mouseUp = ContinuousClock.now
            view.mouseUp(with: up)
            let selected = await selectionTask.value
            let preservedFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost
            let selection = try #require(selected)
            let crop = try await selection.screenshot()
            let captured = ContinuousClock.now
            let body = try await recognizeAndCopy(crop, with: recognizer, format: .raw, pasteboard: pasteboard)
            let copied = ContinuousClock.now
            try #require(selection.rect == fixtureRect && selection.displayID == displayID)
            try #require(crop.width == Int(fixtureRect.width * scale) && crop.height == Int(fixtureRect.height * scale))
            try #require(preservedFocus, "Foreground app changed while handling selection.")
            try #require(pasteboard.changeCount > oldChangeCount)
            try #require(pasteboard.string(forType: .string) == body)
            try #require(body.contains(#"\sqrt"#) && body.contains("y"), "Unexpected synthetic fixture result \(body)")
            if let firstBody { try #require(body == firstBody, "Fixture result varied") }
            else { firstBody = body }

            let row = Measurement(
                mouseUpToCopyMs: milliseconds(mouseUp.duration(to: copied)),
                mouseUpToCaptureMs: milliseconds(mouseUp.duration(to: captured)),
                captureToCopyMs: milliseconds(captured.duration(to: copied))
            )
            results.append(row)
            try await Task.sleep(for: .milliseconds(35))
            print("sample \(index): \(row.mouseUpToCopyMs) ms")
        }
        let description = String(format: "%.0f x %.0f points at %.1fx", fixtureRect.width, fixtureRect.height, scale)
        let report = Report(fixture: URL(fileURLWithPath: fixtures).lastPathComponent, geometry: description,
                            observedLaTeX: try #require(firstBody), cold: results.removeFirst(), warm: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output))
    }

    private func makeEvent(_ type: NSEvent.EventType, at location: CGPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: 0))
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private struct Measurement: Codable {
        let mouseUpToCopyMs: Double
        let mouseUpToCaptureMs: Double
        let captureToCopyMs: Double
    }

    private struct Report: Codable {
        let fixture: String
        let geometry: String
        let observedLaTeX: String
        let cold: Measurement
        let warm: [Measurement]
    }
}
