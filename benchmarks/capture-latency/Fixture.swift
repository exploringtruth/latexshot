import AppKit
import ImageIO

@main @MainActor
struct Fixture {
    static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count == 2, let screen = NSScreen.main,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(2) }

        let size = CGSize(width: CGFloat(cgImage.width) / screen.backingScaleFactor,
                          height: CGFloat(cgImage.height) / screen.backingScaleFactor)
        let region = CGRect(x: floor(screen.visibleFrame.maxX - size.width - 28),
                            y: floor(screen.visibleFrame.minY + 32),
                            width: ceil(size.width), height: ceil(size.height))
        let panel = NSPanel(contentRect: region, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false, screen: screen)
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.backgroundColor = .white
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let imageView = NSImageView(frame: CGRect(origin: .zero, size: region.size))
        imageView.image = NSImage(cgImage: cgImage, size: size)
        imageView.imageAlignment = .alignBottomLeft
        imageView.imageScaling = .scaleNone
        panel.contentView = imageView
        panel.orderFrontRegardless()
        DispatchQueue.main.async {
            let frame = panel.frame
            print(id.uint32Value, screen.backingScaleFactor, frame.minX, frame.minY, frame.width, frame.height)
            fflush(nil)
        }
        withExtendedLifetime(panel) { app.run() }
    }
}
