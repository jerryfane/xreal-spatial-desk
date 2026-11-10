import XCTest
@testable import XRealCore

final class RenderTargetTests: XCTestCase {
    func testSideBySideAlwaysCoversTheGlassesEvenWithAnotherOutput() {
        // --output 1 (another display), glasses are display 3.
        XCTAssertEqual(RenderTarget.choose(outputDisplay: 1, glassesDisplay: 3, glassesSideBySide: false, sideBySideWanted: true), .display(3))
        XCTAssertEqual(RenderTarget.choose(outputDisplay: 1, glassesDisplay: 3, glassesSideBySide: true, sideBySideWanted: false), .display(3))
    }

    func testWithoutSideBySideTheOutputChoiceOrPreviewApplies() {
        XCTAssertEqual(RenderTarget.choose(outputDisplay: 1, glassesDisplay: 3, glassesSideBySide: false, sideBySideWanted: false), .display(1))
        XCTAssertEqual(RenderTarget.choose(outputDisplay: nil, glassesDisplay: 3, glassesSideBySide: false, sideBySideWanted: false), .preview)
    }

    func testUnidentifiedGlassesAreNeverCoveredByGuess() {
        XCTAssertEqual(RenderTarget.choose(outputDisplay: 1, glassesDisplay: nil, glassesSideBySide: false, sideBySideWanted: true), .preview)
    }
}
