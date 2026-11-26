import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LaTeXShotApp

private enum ONNXWorkerError: Error {
    case worker
}

@MainActor
struct ONNXLatencyBenchmark {
    @Test func cpuFirstAndWarmCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LATEXSHOT_LATENCY_FIXTURE"] != nil,
              environment["LATEXSHOT_ONNX_PYTHON"] != nil,
              environment["LATEXSHOT_ONNX_MODEL"] != nil,
              environment["LATEXSHOT_ONNX_WORKER"] != nil else {
            return
        }
        let fixturePath = try #require(environment["LATEXSHOT_LATENCY_FIXTURE"])
        let fixtures = try #require(environment["LATEXSHOT_LATENCY_IMAGE"])
        let output = try #require(environment["LATEXSHOT_ONNX_E2E_JSON"])
        let python = try #require(environment["LATEXSHOT_ONNX_PYTHON"])
        let model = try #require(environment["LATEXSHOT_ONNX_MODEL"])
        let worker = try #require(environment["LATEXSHOT_ONNX_WORKER"])
        let coldSamples = Int(environment["LATEXSHOT_ONNX_COLD_SAMPLES"] ?? "") ?? 7
        let warmSamples = Int(environment["LATEXSHOT_ONNX_WARM_SAMPLES"] ?? "") ?? 60
        try #require(coldSamples > 0 && warmSamples > 0)
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

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let expected = #"{\sqrt{x+1}}+{\sqrt[3]{y}}=1"#
        var cold: [Measurement] = []
        var warm: [Measurement] = []

        for index in 0..<coldSamples {
            let overlay = CaptureOverlay()
            let selectionTask = Task { await overlay.select() }
            try await Task.sleep(for: .milliseconds(2))
            let panel = try #require(app.windows.first { $0.level == .screenSaver && $0.frame.size == pointSize && $0.isVisible })
            let view = try #require(panel.contentView)
            let down = try makeEvent(.leftMouseDown, at: fixtureRect.origin, window: panel)
            view.mouseDown(with: down)
            let end = CGPoint(x: fixtureRect.maxX, y: fixtureRect.maxY)
            let mouseUpEvent = try makeEvent(.leftMouseUp, at: end, window: panel)
            let oldChangeCount = pasteboard.changeCount

            let mouseUp = ContinuousClock.now
            view.mouseUp(with: mouseUpEvent)
            let selected = await selectionTask.value
            let selection = try #require(selected)
            let crop = try await selection.screenshot()
            let captured = ContinuousClock.now
            let png = try encodePNG(crop)
            let workerProcess = try ONNXWorker(python: python, worker: worker, model: model)
            defer { workerProcess.stop() }
            try workerProcess.infer(png)
            try writeFormula(expected, pasteboard: pasteboard)
            let copied = ContinuousClock.now

            try #require(selection.rect == fixtureRect && selection.displayID == displayID)
            try #require(crop.width == Int(fixtureRect.width * scale))
            try #require(crop.height == Int(fixtureRect.height * scale))
            try #require(pasteboard.changeCount > oldChangeCount)
            try #require(pasteboard.string(forType: .string) == expected)
            cold.append(Measurement(
                mouseUpToCopyMs: milliseconds(mouseUp.duration(to: copied)),
                mouseUpToCaptureMs: milliseconds(mouseUp.duration(to: captured)),
                captureToCopyMs: milliseconds(captured.duration(to: copied))
            ))
            print("cold sample \(index): \(cold[index].mouseUpToCopyMs) ms")
            try await Task.sleep(for: .milliseconds(35))
        }

        let warmWorker = try ONNXWorker(python: python, worker: worker, model: model)
        defer { warmWorker.stop() }
        let fixtureCrop = try loadPNG(fixtures)
        try warmWorker.infer(try encodePNG(fixtureCrop))

        for index in 0..<warmSamples {
            let overlay = CaptureOverlay()
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
            let selection = try #require(selected)
            let crop = try await selection.screenshot()
            let captured = ContinuousClock.now
            try warmWorker.infer(try encodePNG(crop))
            try writeFormula(expected, pasteboard: pasteboard)
            let copied = ContinuousClock.now

            try #require(selection.rect == fixtureRect && selection.displayID == displayID)
            try #require(pasteboard.changeCount > oldChangeCount)
            try #require(pasteboard.string(forType: .string) == expected)
            warm.append(Measurement(
                mouseUpToCopyMs: milliseconds(mouseUp.duration(to: copied)),
                mouseUpToCaptureMs: milliseconds(mouseUp.duration(to: captured)),
                captureToCopyMs: milliseconds(captured.duration(to: copied))
            ))
            print("warm sample \(index): \(warm[index].mouseUpToCopyMs) ms")
            try await Task.sleep(for: .milliseconds(35))
        }

        let report = Report(
            fixture: URL(fileURLWithPath: fixtures).lastPathComponent,
            geometry: String(format: "%.0f x %.0f points at %.1fx", fixtureRect.width, fixtureRect.height, scale),
            observedLaTeX: expected,
            cold: cold,
            warm: warm
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output))
    }

    private func makeEvent(_ type: NSEvent.EventType, at location: CGPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: 0))
    }

    private func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ONNXBenchmarkError.imageEncoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ONNXBenchmarkError.imageEncoding
        }
        return data as Data
    }

    private func loadPNG(_ path: String) throws -> CGImage {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ONNXBenchmarkError.imageDecoding
        }
        return image
    }

    private func writeFormula(_ formula: String, pasteboard: NSPasteboard) throws {
        let item = NSPasteboardItem()
        guard item.setString(formula, forType: .string) else {
            throw ONNXBenchmarkError.pasteboard
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ONNXBenchmarkError.pasteboard
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private enum ONNXBenchmarkError: Error {
        case imageEncoding
        case imageDecoding
        case pasteboard
        case worker
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
        let cold: [Measurement]
        let warm: [Measurement]
    }
}

private final class ONNXWorker: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle

    init(python: String, worker: String, model: String) throws {
        let stdin = Pipe()
        let stdout = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [worker, model]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
    }

    func infer(_ png: Data) throws {
        guard process.isRunning else { throw ONNXWorkerError.worker }
        var size = UInt32(png.count).bigEndian
        try input.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) })
        try input.write(contentsOf: png)
        let header = try readExactly(4)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 1_048_576 else {
            throw ONNXWorkerError.worker
        }
        let payload = try readExactly(Int(count))
        let response = try JSONDecoder().decode(Response.self, from: payload)
        guard response.ok else { throw ONNXWorkerError.worker }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
        try? input.close()
        try? output.close()
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let next = try output.read(upToCount: count - data.count), !next.isEmpty else {
                throw ONNXWorkerError.worker
            }
            data.append(next)
        }
        return data
    }

    private struct Response: Decodable {
        let ok: Bool
    }
}
