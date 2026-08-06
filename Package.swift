// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "overscroll",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: no AppKit, no ScreenCaptureKit. Fully unit-testable.
        .target(name: "OverscrollCore"),
        // Accessibility + window-server access, shared by the app and the diagnostic CLI so the
        // probe reports exactly what the app will see rather than a re-implementation of it.
        .target(
            name: "OverscrollAX",
            dependencies: ["OverscrollCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "axprobe",
            dependencies: ["OverscrollAX", "OverscrollCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app: overlay, accessibility harvest, scrolling, OCR fallback.
        .executableTarget(
            name: "overscroll",
            dependencies: ["OverscrollCore", "OverscrollAX"],
            // AppKit + the C accessibility APIs predate strict concurrency; v6 mode buries this in
            // sendability noise for no safety gain in a single-main-actor app.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "OverscrollCoreTests", dependencies: ["OverscrollCore"]),
    ]
)
