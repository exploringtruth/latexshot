import CoreGraphics
import ImageIO
import XCTest
@testable import EquationRecognition

final class EquationRecognitionTests: XCTestCase {
    func testInstalledModelThroughAppInterface() async throws {
        guard ProcessInfo.processInfo.environment["LATEXSHOT_RECOGNITION_PYTHON"] != nil else {
            throw XCTSkip("Set the development runtime and model variables to exercise real inference")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("benchmarks/fixtures/roots-01.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let result = try await OfflineEquationRecognizer().recognize(image)
        XCTAssertTrue(result.contains("\\sqrt"))
        XCTAssertTrue(result.contains("y"))
    }

    func testPackagedRecognizerSelectsBundledPix2Text() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        let model = resources.appendingPathComponent("RecognitionModel")
        let bin = resources.appendingPathComponent("RecognitionRuntime/bin")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "test.latexshot.recognition",
                "CFBundlePackageType": "APPL",
                "LaTeXShotRecognitionBackend": "pix2text"
            ],
            format: .xml, options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        for filename in ["encoder_model.onnx", "decoder_model.onnx"] {
            try Data().write(to: model.appendingPathComponent(filename))
        }
        let python = bin.appendingPathComponent("python3")
        let worker = #"""
            #!/bin/sh
            [ "$1" = '-I' ] && [ "$2" = '-B' ] && [ "$5" = 'pix2text' ] || exit 1
            [ -f "$4/encoder_model.onnx" ] && [ -f "$4/decoder_model.onnx" ] || exit 1
            set -- $(/bin/dd bs=1 count=4 2>/dev/null | /usr/bin/od -An -tu1)
            [ "$#" -eq 4 ] || exit 1
            /bin/dd bs=1 count=$(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )) 2>/dev/null >/dev/null
            printf '\000\000\000\015%s' '{"latex":"x"}'
            """#
        try worker.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let bundle = try XCTUnwrap(Bundle(url: app))
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())

        let result = try await OfflineEquationRecognizer(bundle: bundle).recognize(image)
        XCTAssertEqual(result, "x")
    }

    func testExitedWorkerWithLargeImageReturnsErrorAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("inference.pdiparams"))
        let recognizer = OfflineEquationRecognizer(python: URL(fileURLWithPath: "/usr/bin/false"), model: directory)
        var pixels = (0..<(1024 * 1024 * 4)).map { _ in UInt8.random(in: 0...255) }
        let image = try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1024, height: 1024,
                bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        for _ in 0..<3 {
            do {
                _ = try await recognizer.recognize(image)
                XCTFail("Exited worker must throw")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testOnlyRecoverableCropErrorsKeepWorkerAlive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("inference.pdiparams"))
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())

        func frame(_ json: String) -> String {
            let size = UInt32(json.utf8.count).bigEndian
            let header = withUnsafeBytes(of: size) { bytes in
                bytes.map { String(format: "\\0%03o", Int($0)) }.joined()
            }
            return "printf '%b%s' '\(header)' '\(json)'"
        }

        let cropFailure = #"{"error":"Rejected crop","recoverable":true}"#
        let fatalReplies = [
            (#"{"error":"Offline recognition could not start (RuntimeError)."}"#,
                "Offline recognition could not start (RuntimeError)."),
            (#"{"latex":"x","error":"ambiguous"}"#, "Invalid recognition response.")
        ]
        for (index, reply) in fatalReplies.enumerated() {
            let interpreter = directory.appendingPathComponent("mock-worker-\(index)")
            let script = """
                #!/bin/sh
                read_request() {
                    set -- $(/bin/dd bs=1 count=4 2>/dev/null | /usr/bin/od -An -tu1)
                    [ "$#" -eq 4 ] || exit 0
                    /bin/dd bs=1 count=$(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )) 2>/dev/null >/dev/null
                }
                read_request
                \(frame(cropFailure))
                read_request
                \(frame(#"{"latex":"x"}"#))
                read_request
                \(frame(reply.0))
                read_request
                \(frame(#"{"latex":"stale"}"#))
                """
            try script.write(to: interpreter, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
            let recognizer = OfflineEquationRecognizer(python: interpreter, model: directory)
            func expectError(_ message: String) async throws {
                do {
                    let latex = try await recognizer.recognize(image)
                    XCTFail("Unexpected formula: \(latex)")
                } catch let error as EquationRecognitionError {
                    XCTAssertEqual(error, .failed(message))
                }
            }

            try await expectError("Rejected crop")
            let latex = try await recognizer.recognize(image)
            XCTAssertEqual(latex, "x")
            try await expectError(reply.1)
            try await expectError("Rejected crop")
        }
    }

    func testMissingRuntimeReturnsError() async throws {
        let recognizer = OfflineEquationRecognizer(python: nil, model: nil)
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        do {
            _ = try await recognizer.recognize(image)
            XCTFail("Missing models must fail without a fabricated formula")
        } catch let error as EquationRecognitionError {
            XCTAssertEqual(error, .unavailable)
        }
    }
}
