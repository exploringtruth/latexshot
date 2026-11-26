// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LaTeXShot",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LaTeXShot", targets: ["LaTeXShotApp"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0")
    ],
    targets: [
        .target(name: "EquationRecognition", resources: [.copy("Resources")]),
        .executableTarget(
            name: "LaTeXShotApp",
            dependencies: [
                "EquationRecognition",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [.copy("Resources/MathRenderer")],
            linkerSettings: [
                // Packaged builds embed Sparkle in Contents/Frameworks.
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(name: "EquationRecognitionTests", dependencies: ["EquationRecognition"]),
        .testTarget(name: "LaTeXShotAppTests", dependencies: ["LaTeXShotApp"])
    ]
)
