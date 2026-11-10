// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XRealDesk",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XRealCore", targets: ["XRealCore"]),
        .library(name: "GlassesLink", targets: ["GlassesLink"]),
        .executable(name: "xreal-track", targets: ["xreal-track"]),
    ],
    targets: [
        // Pure logic: framing, message parsing, factory calibration, head tracking. No I/O.
        .target(name: "XRealCore"),
        // TCP connection to the glasses (or tools/fake_glasses.py).
        .target(name: "GlassesLink", dependencies: ["XRealCore"]),
        // Loading captures/ recordings and measuring tracking against their recorded steps (tests and CLI only).
        .target(name: "CaptureTools", dependencies: ["XRealCore"]),
        // Command-line tool: live pose, replay of a capture, measurement against the fake glasses.
        .executableTarget(name: "xreal-track", dependencies: ["XRealCore", "GlassesLink", "CaptureTools"]),
        .testTarget(name: "XRealCoreTests", dependencies: ["XRealCore", "CaptureTools"]),
        .testTarget(name: "GlassesLinkTests", dependencies: ["GlassesLink", "XRealCore"]),
    ]
)
