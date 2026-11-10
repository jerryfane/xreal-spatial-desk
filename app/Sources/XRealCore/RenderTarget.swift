/// Where the app's side-by-side image goes. The rule that matters: while the glasses are, or are about to be, in
/// side-by-side input, the image covers the glasses; otherwise each eye would see a different half of the desktop.
public enum RenderTarget: Equatable, Sendable {
    /// A half-size window on the main display.
    case preview
    /// Full screen on this display.
    case display(UInt32)

    /// - Parameters:
    ///   - outputDisplay: the `--output` choice, if any.
    ///   - glassesDisplay: the glasses' display ID, if identified.
    ///   - glassesSideBySide: the glasses currently show a 3840×1080 (side-by-side) display.
    ///   - sideBySideWanted: side-by-side is requested or being switched to.
    public static func choose(outputDisplay: UInt32?, glassesDisplay: UInt32?, glassesSideBySide: Bool,
                              sideBySideWanted: Bool) -> RenderTarget {
        if glassesSideBySide || sideBySideWanted {
            // The glasses win over --output; if they are not identified there is nothing safe to cover.
            return glassesDisplay.map(RenderTarget.display) ?? .preview
        }
        return outputDisplay.map(RenderTarget.display) ?? .preview
    }
}
