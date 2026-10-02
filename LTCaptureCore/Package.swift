// swift-tools-version: 6.2
import PackageDescription

// The same isolation rules as the app target (plan F38, F64): Swift 6 mode,
// main-actor by default, and nonisolated async functions run on the caller's actor.
let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "LTCaptureCore",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "LTCaptureCore", targets: ["LTCaptureCore"]),
    ],
    targets: [
        .target(name: "LTCaptureCore", swiftSettings: settings),
        .testTarget(name: "LTCaptureCoreTests", dependencies: ["LTCaptureCore"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
