import AppKit
import EquationRecognition
import Foundation
import Testing
@testable import LaTeXShotApp

struct RecognitionStartupTests {
    @MainActor
    @Test func captureUsesFormatSelectedWhileRecognitionWasRunning() async throws {
        let domain = "LaTeXShotAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let started = AsyncGate()
        let release = AsyncGate()
        let preferences = Preferences(defaults: defaults)
        let runtime = AppRuntime(
            recognizer: StartupProbeRecognizer(started: started, release: release),
            preferences: preferences, pasteboard: pasteboard
        )
        try runtime.copyEquation("y")

        let crop = try makeCrop(width: 10)
        let capture = Task { try await runtime.recognizeCapture(crop) }
        await started.wait()
        runtime.selectClipboardFormat(.inlineMarkdown)
        #expect(pasteboard.string(forType: .string) == "$y$")
        await release.open()
        let captured = try await capture.value
        #expect(pasteboard.string(forType: .string) == "$" + captured + "$")
        #expect(preferences.equationHistory == [captured, "y"])
    }

    @Test func launchPrewarmIsNonblockingAndCaptureWaitsBehindIt() async throws {
        let warmupStarted = AsyncGate()
        let releaseWarmup = AsyncGate()
        let worker = StartupProbeRecognizer(started: warmupStarted, release: releaseWarmup)
        let startup = RecognitionStartup(
            recognizer: worker,
            makeWarmupCrop: { try? makeCrop(width: 10) }
        )

        let launchHook = ContinuousClock.now
        await startup.start()
        let launchHookReturned = ContinuousClock.now

        let captureStarted = ContinuousClock.now
        let capture = Task { try await startup.recognize(try makeCrop(width: 20)) }
        await warmupStarted.wait()
        #expect(await worker.callCount() == 1)

        await releaseWarmup.open()
        #expect(try await capture.value == "x+1=2")
        let captureFinished = ContinuousClock.now
        let startupDuration = await startup.waitUntilReady()

        let warmCaptureStarted = ContinuousClock.now
        #expect(try await startup.recognize(try makeCrop(width: 20)) == "x+1=2")
        let warmCaptureFinished = ContinuousClock.now

        #expect(await worker.callCount() == 3)
        #expect(await worker.maximumConcurrentCalls() == 1)
        print(
            """
            Recognition startup timing (controlled worker test, not model benchmark):
              launch hook return: \(milliseconds(launchHook.duration(to: launchHookReturned)))
              startup hook to ready: \(milliseconds(startupDuration ?? .zero))
              capture during startup: \(milliseconds(captureStarted.duration(to: captureFinished)))
              warm capture: \(milliseconds(warmCaptureStarted.duration(to: warmCaptureFinished)))
            """
        )
    }

    @MainActor
    @Test func reportsRealWorkerStartupWarmAndCaptureDuringStartupTimings() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LATEXSHOT_RECOGNITION_STARTUP_BENCHMARK"] == "1",
              let python = environment["LATEXSHOT_RECOGNITION_PYTHON"],
              let model = environment["LATEXSHOT_MODEL_DIRECTORY"],
              let fixture = environment["LATEXSHOT_STARTUP_FIXTURE"] else {
            return
        }

        let crop = try loadImage(at: fixture)
        let startup = RecognitionStartup(recognizer: OfflineEquationRecognizer(
            python: URL(fileURLWithPath: python),
            model: URL(fileURLWithPath: model)
        ))
        let clock = ContinuousClock()
        let startupHook = clock.now
        await startup.start()
        let startupScheduled = clock.now

        let readiness = Task { await startup.waitUntilReady() }
        let duringStartupPasteboard = NSPasteboard.withUniqueName()
        defer { duringStartupPasteboard.releaseGlobally() }
        let duringStartup = clock.now
        let duringStartupBody = try await recognizeAndCopy(
            crop, with: startup, format: .raw, pasteboard: duringStartupPasteboard
        )
        let duringStartupCopied = clock.now
        let startupDuration = await readiness.value
        let startupReady = clock.now

        let warmPasteboard = NSPasteboard.withUniqueName()
        defer { warmPasteboard.releaseGlobally() }
        let warmStarted = clock.now
        let warmBody = try await recognizeAndCopy(crop, with: startup, format: .raw, pasteboard: warmPasteboard)
        let warmCopied = clock.now

        #expect(!duringStartupBody.isEmpty)
        #expect(warmBody == duringStartupBody)
        #expect(duringStartupPasteboard.string(forType: .string) == duringStartupBody)
        #expect(warmPasteboard.string(forType: .string) == warmBody)
        print(
            """
            Real worker timing (recognition + private pasteboard; excludes mouse-up and popup rendering):
              startup scheduling: \(milliseconds(startupHook.duration(to: startupScheduled)))
              startup hook to ready: \(milliseconds(startupHook.duration(to: startupReady)))
              coordinator startup duration: \(milliseconds(startupDuration ?? .zero))
              capture during startup to clipboard: \(milliseconds(duringStartup.duration(to: duringStartupCopied)))
              warm capture to clipboard: \(milliseconds(warmStarted.duration(to: warmCopied)))
            """
        )
    }

    private func makeCrop(width: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private func loadImage(at path: String) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

private actor StartupProbeRecognizer: EquationRecognizing {
    private let started: AsyncGate
    private let release: AsyncGate
    private var calls = 0
    private var activeCalls = 0
    private var maximumActiveCalls = 0

    init(started: AsyncGate, release: AsyncGate) {
        self.started = started
        self.release = release
    }

    func recognize(_ crop: CGImage) async throws -> String {
        calls += 1
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        defer { activeCalls -= 1 }

        if crop.width == 10 {
            await started.open()
            await release.wait()
            return "warmup"
        }
        return "x+1=2"
    }

    func callCount() -> Int { calls }
    func maximumConcurrentCalls() -> Int { maximumActiveCalls }
}
