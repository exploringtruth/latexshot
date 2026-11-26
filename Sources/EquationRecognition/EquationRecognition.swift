import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol EquationRecognizing: Sendable {
    func recognize(_ crop: CGImage) async throws -> String
}

public enum EquationRecognitionError: LocalizedError, Equatable {
    case unavailable
    case invalidImage
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The offline recognition runtime and model need to be installed for this local build."
        case .invalidImage:
            return "Select a smaller, nonempty equation and try again."
        case .failed(let message):
            return message
        }
    }
}

/// Serializes requests to one warm local model. No capture is written to disk.
public final class OfflineEquationRecognizer: EquationRecognizing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "LaTeXShot.recognition", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let python: URL?
    private let model: URL?
    private let mode: RuntimeMode
    private static let pix2TextFiles = ["encoder_model.onnx", "decoder_model.onnx"]

    private enum RuntimeMode: Equatable {
        case packaged(pix2Text: Bool)
        case pix2TextTrial
        case development(pix2Text: Bool)

        var usePix2Text: Bool {
            switch self {
            case .packaged(let pix2Text), .development(let pix2Text): pix2Text
            case .pix2TextTrial: true
            }
        }
    }

    public convenience init() {
        self.init(bundle: .main)
    }

    convenience init(bundle: Bundle) {
        let resources = bundle.resourceURL
        if bundle.bundleURL.pathExtension == "app" {
            self.init(
                python: resources?.appendingPathComponent("RecognitionRuntime/bin/python3"),
                model: resources?.appendingPathComponent("RecognitionModel"),
                mode: .packaged(pix2Text: bundle.object(forInfoDictionaryKey: "LaTeXShotRecognitionBackend") as? String == "pix2text")
            )
        } else {
            let environment = ProcessInfo.processInfo.environment
            self.init(
                python: environment["LATEXSHOT_RECOGNITION_PYTHON"].map(URL.init(fileURLWithPath:))
                    ?? resources?.appendingPathComponent("RecognitionRuntime/bin/python3"),
                model: environment["LATEXSHOT_MODEL_DIRECTORY"].map(URL.init(fileURLWithPath:))
                    ?? resources?.appendingPathComponent("RecognitionModel"),
                mode: environment["LATEXSHOT_ALLOW_PIX2TEXT_TRIAL"] == "1" ? .pix2TextTrial : .development(pix2Text: false)
            )
        }
    }

    public convenience init(python: URL?, model: URL?) {
        let usePix2Text = model.map { directory in
            Self.pix2TextFiles.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        } ?? false
        self.init(python: python, model: model, mode: .development(pix2Text: usePix2Text))
    }

    private init(python: URL?, model: URL?, mode: RuntimeMode) {
        self.python = python
        self.model = model
        self.mode = mode
    }

    deinit {
        // EOF lets the idle worker exit without invoking Paddle's signal handler.
        try? input?.close()
        try? output?.close()
    }

    public func recognize(_ crop: CGImage) async throws -> String {
        guard crop.width > 0, crop.height > 0,
              crop.width <= 16_384, crop.height <= 16_384,
              crop.width * crop.height <= 32_000_000 else {
            throw EquationRecognitionError.invalidImage
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw EquationRecognitionError.invalidImage
        }
        CGImageDestinationAddImage(destination, crop, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 64 * 1024 * 1024 else {
            throw EquationRecognitionError.invalidImage
        }
        let png = data as Data
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.predict(png)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        let requiredFiles = mode.usePix2Text ? Self.pix2TextFiles : ["inference.pdiparams"]
        guard let python, let model,
              FileManager.default.isExecutableFile(atPath: python.path),
              requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: model.appendingPathComponent($0).path) }),
              let worker = Bundle.module.url(forResource: "recognize", withExtension: "py", subdirectory: "Resources") else {
            throw EquationRecognitionError.unavailable
        }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = python
        child.arguments = ["-I", "-B", worker.path, model.path]
        if mode.usePix2Text { child.arguments?.append("pix2text") }
        child.standardInput = stdin
        child.standardOutput = stdout
        // The opt-in trial reports readiness to its local launch terminal.
        child.standardError = mode == .pix2TextTrial ? FileHandle.standardError : FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        if case .packaged(let pix2Text) = mode {
            environment = ["PATH": "/usr/bin:/bin"]
            if !pix2Text { environment["LATEXSHOT_ALLOW_PLUS_S_TRIAL"] = "1" }
        }
        environment.removeValue(forKey: "LATEXSHOT_ALLOW_PIX2TEXT_TRIAL")
        environment["HF_HUB_OFFLINE"] = "1"
        environment["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
        child.environment = environment
        try child.run()
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            Darwin.kill(child.processIdentifier, SIGKILL)
            throw EquationRecognitionError.failed("Could not initialize the recognition pipe.")
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    private func predict(_ png: Data) throws -> String {
        try startIfNeeded()
        guard let child = process, let input, let output else { throw EquationRecognitionError.unavailable }
        // Includes cold start. A timeout tears down this worker so a retry starts cleanly.
        // Paddle's SIGTERM handler can crash on macOS. Force-stop a hung worker.
        let timeout = DispatchWorkItem {
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        let cropError: String
        do {
            var size = UInt32(png.count).bigEndian
            try input.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) })
            try input.write(contentsOf: png)
            let header = try readExactly(4, from: output)
            let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count > 0, count <= 1_048_576 else { throw EquationRecognitionError.failed("Invalid recognition response.") }
            let response = try JSONDecoder().decode(Response.self, from: readExactly(Int(count), from: output))
            switch (response.latex, response.error) {
            case (let body?, nil) where !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !body.contains("\0") && response.recoverable == nil:
                return body
            case (nil, let message?) where !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                if response.recoverable != true { throw EquationRecognitionError.failed(message) }
                cropError = message
            default:
                throw EquationRecognitionError.failed("Invalid recognition response.")
            }
        } catch {
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            try? input.close()
            try? output.close()
            self.process = nil
            self.input = nil
            self.output = nil
            throw error
        }
        // A rejected crop leaves the framed stream synchronized and the model warm.
        throw EquationRecognitionError.failed(cropError)
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else {
                throw EquationRecognitionError.failed("Offline recognition stopped or timed out. Try again.")
            }
            data.append(next)
        }
        return data
    }

    private struct Response: Decodable {
        let latex: String?
        let error: String?
        let recoverable: Bool?
    }
}
