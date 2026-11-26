import AppKit
import CoreText
import EquationRecognition

actor RecognitionStartup: EquationRecognizing {
    private let recognizer: any EquationRecognizing
    private let makeWarmupCrop: @Sendable () -> CGImage?
    private var startupTask: Task<Void, Never>?
    private var startupStartedAt: ContinuousClock.Instant?
    private var startupReadyAt: ContinuousClock.Instant?

    init(recognizer: any EquationRecognizing) {
        self.recognizer = recognizer
        self.makeWarmupCrop = Self.makeWarmupCrop
    }

    init(recognizer: any EquationRecognizing, makeWarmupCrop: @escaping @Sendable () -> CGImage?) {
        self.recognizer = recognizer
        self.makeWarmupCrop = makeWarmupCrop
    }

    func start() {
        _ = startIfNeeded()
    }

    func waitUntilReady() async -> Duration? {
        await startIfNeeded().value
        if startupReadyAt == nil {
            startupReadyAt = ContinuousClock.now
        }
        guard let startupStartedAt, let startupReadyAt else { return nil }
        return startupStartedAt.duration(to: startupReadyAt)
    }

    func recognize(_ crop: CGImage) async throws -> String {
        await startIfNeeded().value
        if startupReadyAt == nil {
            startupReadyAt = ContinuousClock.now
        }
        return try await recognizer.recognize(crop)
    }

    private func startIfNeeded() -> Task<Void, Never> {
        if let startupTask { return startupTask }

        startupStartedAt = ContinuousClock.now
        let recognizer = self.recognizer
        let makeWarmupCrop = self.makeWarmupCrop
        let task = Task.detached(priority: .utility) {
            guard let crop = makeWarmupCrop() else { return }
            _ = try? await recognizer.recognize(crop)
        }
        startupTask = task
        return task
    }

    private static func makeWarmupCrop() -> CGImage? {
        let width = 320
        let height = 96
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Times New Roman" as CFString, 48, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "x + 1 = 2", attributes: attributes)
        )
        context.textPosition = CGPoint(x: 24, y: 24)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
