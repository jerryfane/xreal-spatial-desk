import CaptureTools
import Foundation
import XCTest

/// The capture committed with the repository (captures/20261110-140512, 93 s, firmware 1.9.1).
enum Fixtures {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let captureDirectory = repoRoot.appendingPathComponent("captures/20261110-140512")

    static func capture() throws -> Capture {
        try loaded.get()
    }

    private static let loaded = Result { try Capture(directory: captureDirectory) }

    static func bytes(_ hex: String) -> [UInt8] {
        [UInt8](hex: hex)!
    }
}
