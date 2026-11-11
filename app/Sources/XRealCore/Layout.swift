import Foundation

/// One virtual screen: a macOS display of `pixelWidth`×`pixelHeight` shown at a place around the head.
public struct SpatialScreen: Codable, Equatable, Sendable {
    /// Stable within a layout; names the macOS display ("XReal Desk <id>").
    public var id: Int
    /// Direction of the centre from the head, degrees (HeadPose conventions: +yaw right, +pitch up).
    public var yaw: Double
    public var pitch: Double
    /// Metres.
    public var distance: Double
    /// Physical size, like a monitor's: the diagonal in inches.
    public var diagonalInches: Double
    /// The macOS display's resolution; also sets the aspect ratio.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Curve radius in metres (1.8 = 1800R); 0 = flat.
    public var curveRadius: Double

    public init(id: Int, yaw: Double = 0, pitch: Double = 0, distance: Double = 1.5, diagonalInches: Double = 40,
                pixelWidth: Int = 1920, pixelHeight: Int = 1080, curveRadius: Double = 0) {
        self.id = id
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.diagonalInches = diagonalInches
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.curveRadius = curveRadius
    }

    /// Where and how big it is in metres.
    public var placement: ScreenPlacement {
        let diagonal = diagonalInches * 0.0254
        let k = diagonal / hypot(Double(pixelWidth), Double(pixelHeight))
        return ScreenPlacement(yaw: yaw, pitch: pitch, distance: distance, width: Double(pixelWidth) * k,
                               height: Double(pixelHeight) * k, curveRadius: curveRadius)
    }

    /// Screens within this pitch of the horizon form the row that `Layout.packRow` keeps side by side.
    public static let rowPitchLimit = 10.0
    public var inRow: Bool { abs(pitch) < Self.rowPitchLimit }
}

/// A set of screens around the head, saved and recalled by name.
public struct Layout: Codable, Equatable, Sendable {
    public var name: String
    public var screens: [SpatialScreen]

    /// Every screen is a captured display; more would cost more than it gives.
    public static let maxScreens = 6
    /// Degrees between neighbours in the row.
    public static let rowGap = 8.0

    public init(name: String, screens: [SpatialScreen]) {
        self.name = name
        self.screens = screens
    }

    // MARK: presets

    /// The single screen milestone 3 showed: about 0.9 m wide at 1.6 m.
    public static let single = Layout(name: "One screen", screens: [SpatialScreen(id: 1, distance: 1.6, diagonalInches: 41)])

    /// Three equal screens in a row at arm's length plus, packed edge to edge with `rowGap` between them.
    public static let threeInARow: Layout = {
        var l = Layout(name: "Three in a row", screens: [
            SpatialScreen(id: 1, diagonalInches: 40),
            SpatialScreen(id: 2, yaw: -40, diagonalInches: 40),
            SpatialScreen(id: 3, yaw: 40, diagonalInches: 40),
        ])
        l.packRow()
        return l
    }()

    /// index.html's "Mac · multi-screen": a large centre screen, one each side, a smaller one above.
    public static let desk: Layout = {
        var l = Layout(name: "Desk (four screens)", screens: [
            SpatialScreen(id: 1, diagonalInches: 48),
            SpatialScreen(id: 2, yaw: -44, diagonalInches: 40),
            SpatialScreen(id: 3, yaw: 44, diagonalInches: 40),
            SpatialScreen(id: 4, pitch: 28, distance: 1.6, diagonalInches: 34),
        ])
        l.packRow()
        return l
    }()

    public static let presets = [single, threeInARow, desk]

    // MARK: editing

    public func screen(_ id: Int) -> SpatialScreen? { screens.first { $0.id == id } }

    /// Adds a screen like the one closest to straight ahead (same size, distance, resolution and curve) at the end
    /// of the row on the side with fewer screens (right on a tie). Returns nil when the layout is full.
    @discardableResult
    public mutating func addScreen() -> SpatialScreen? {
        guard screens.count < Self.maxScreens else { return nil }
        let template = rowAnchor ?? screens.first ?? Layout.single.screens[0]
        let row = screens.filter(\.inRow)
        let left = row.filter { $0.yaw < template.yaw }.count, right = row.filter { $0.yaw > template.yaw }.count
        var new = template
        new.id = (screens.map(\.id).max() ?? 0) + 1
        new.pitch = 0
        new.yaw = row.isEmpty ? 0 : (right <= left ? (row.map(\.yaw).max()! + 1) : (row.map(\.yaw).min()! - 1))
        screens.append(new)
        packRow()
        return screen(new.id)
    }

    public mutating func removeScreen(_ id: Int) {
        screens.removeAll { $0.id == id }
        packRow()
    }

    /// Changes one screen and re-packs the row, so a bigger or curved screen pushes its neighbours aside.
    public mutating func update(_ id: Int, _ change: (inout SpatialScreen) -> Void) {
        guard let i = screens.firstIndex(where: { $0.id == id }) else { return }
        change(&screens[i])
        screens[i] = screens[i].clamped
        packRow()
    }

    /// The row screen closest to straight ahead; it stays where it is when the row is packed.
    var rowAnchor: SpatialScreen? { screens.filter(\.inRow).min { abs($0.yaw) < abs($1.yaw) } }

    /// Places the row's screens (|pitch| < 10°) side by side in their current yaw order, `rowGap` apart: the screen
    /// closest to straight ahead keeps its yaw, the others move outward from it. Screens above or below keep theirs.
    public mutating func packRow() {
        guard let anchor = rowAnchor else { return }
        let order = screens.indices.filter { screens[$0].inRow }.sorted { screens[$0].yaw < screens[$1].yaw }
        guard let a = order.firstIndex(where: { screens[$0].id == anchor.id }) else { return }
        func halfWidth(_ i: Int) -> Double { screens[i].placement.angularSize.width / 2 }
        var edge = anchor.yaw + halfWidth(order[a])
        for i in order[(a + 1)...] {
            screens[i].yaw = edge + Self.rowGap + halfWidth(i)
            edge = screens[i].yaw + halfWidth(i)
        }
        edge = anchor.yaw - halfWidth(order[a])
        for i in order[..<a].reversed() {
            screens[i].yaw = edge - Self.rowGap - halfWidth(i)
            edge = screens[i].yaw - halfWidth(i)
        }
    }

    /// A layout safe to use whatever a file said: values in range, unique IDs, at most `maxScreens`, at least one.
    public var sanitized: Layout {
        var seen = Set<Int>()
        var out = self
        out.screens = screens.filter { $0.id > 0 && seen.insert($0.id).inserted }.prefix(Self.maxScreens).map(\.clamped)
        if out.screens.isEmpty { out.screens = Layout.single.screens }
        return out
    }
}

extension SpatialScreen {
    var clamped: SpatialScreen {
        var s = self
        s.yaw = remainder(yaw.isFinite ? yaw : 0, 360)
        s.pitch = min(max(pitch.isFinite ? pitch : 0, -80), 80)
        s.distance = min(max(distance.isFinite ? distance : 1.5, 0.5), 10)
        s.diagonalInches = min(max(diagonalInches.isFinite ? diagonalInches : 40, 15), 150)
        s.pixelWidth = min(max(pixelWidth, 640), 7680)
        s.pixelHeight = min(max(pixelHeight, 480), 4320)
        // Tighter than 0.8 m the curve wraps past what any monitor does; non-finite or negative means flat.
        s.curveRadius = curveRadius.isFinite && curveRadius > 0 ? min(max(curveRadius, 0.8), 10) : 0
        return s
    }
}

/// The current layout and the saved ones, kept as JSON (`~/Library/Application Support/XRealDesk/layouts.json`).
public struct LayoutLibrary: Codable, Equatable, Sendable {
    public var current: Layout
    public var saved: [Layout]

    public init(current: Layout = .single, saved: [Layout] = []) {
        self.current = current
        self.saved = saved
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XRealDesk/layouts.json")
    }

    /// Saves `layout` under its name, replacing a saved layout of the same name.
    public mutating func save(_ layout: Layout) {
        saved.removeAll { $0.name == layout.name }
        saved.append(layout)
    }

    public struct Loaded {
        public var library: LayoutLibrary
        /// Why the file was not used, if it exists and was not.
        public var problem: String?
        /// False when an existing file could neither be used nor moved aside: writing would destroy it.
        public var safeToWrite: Bool
    }

    /// Reads the library. A missing file gives the default. A file that cannot be read or decoded is renamed to
    /// `layouts.json.bad` (kept for the user, out of the way) and also gives the default, with the reason; if it
    /// cannot be renamed either, `safeToWrite` is false.
    public static func load(from url: URL = defaultURL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded(library: LayoutLibrary(), safeToWrite: true) }
        let reason: String
        do {
            var l = try JSONDecoder().decode(LayoutLibrary.self, from: Data(contentsOf: url))
            l.current = l.current.sanitized
            l.saved = l.saved.map(\.sanitized)
            return Loaded(library: l, safeToWrite: true)
        } catch {
            reason = "\(url.lastPathComponent) unusable (\(error))"
        }
        let bad = url.appendingPathExtension("bad")
        do {
            if FileManager.default.fileExists(atPath: bad.path) { try FileManager.default.removeItem(at: bad) }
            try FileManager.default.moveItem(at: url, to: bad)
            return Loaded(library: LayoutLibrary(), problem: "\(reason); moved to \(bad.lastPathComponent)", safeToWrite: true)
        } catch {
            return Loaded(library: LayoutLibrary(), problem: "\(reason); could not move it aside (\(error)), so layouts will not be saved this run",
                          safeToWrite: false)
        }
    }

    public func write(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Where macOS should put our virtual displays in its arrangement, so the pointer moves between them the way they
/// sit around the head: the row left to right in yaw order, right of the other displays and top-aligned with them;
/// a screen above (below) the row sits on top of (under) the row display nearest its yaw, centred on it, pushed
/// right only as far as needed to clear the one before it in its band.
public enum DisplayArrangement {
    public struct Item: Equatable, Sendable {
        public var id: UInt32
        public var yaw: Double
        public var pitch: Double
        /// Points (the virtual displays are not HiDPI, so pixels).
        public var width: Int
        public var height: Int

        public init(id: UInt32, yaw: Double, pitch: Double, width: Int, height: Int) {
            self.id = id
            self.yaw = yaw
            self.pitch = pitch
            self.width = width
            self.height = height
        }
    }

    /// Global origins (top-left, y down, as CoreGraphics) keyed by display ID. `others` is the bounding box of every
    /// other display (x, y, width, height); our displays go right of it.
    public static func origins(_ items: [Item], rightOf others: (x: Int, y: Int, width: Int, height: Int))
        -> [UInt32: (x: Int, y: Int)] {
        let row = items.filter { abs($0.pitch) < SpatialScreen.rowPitchLimit }.sorted { $0.yaw < $1.yaw }
        let above = items.filter { $0.pitch >= SpatialScreen.rowPitchLimit }.sorted { $0.yaw < $1.yaw }
        let below = items.filter { $0.pitch <= -SpatialScreen.rowPitchLimit }.sorted { $0.yaw < $1.yaw }
        let left = others.x + others.width, top = others.y
        let rowHeight = row.map(\.height).max() ?? 0
        var out: [UInt32: (x: Int, y: Int)] = [:]
        var x = left
        for i in row {
            out[i.id] = (x, top)
            x += i.width
        }
        func band(_ items: [Item], y: (Item) -> Int) {
            var end = Int.min
            for i in items {
                // Centred on the nearest row display, else from the left edge.
                let under = row.min { abs($0.yaw - i.yaw) < abs($1.yaw - i.yaw) }
                let centred = under.map { out[$0.id]!.x + ($0.width - i.width) / 2 } ?? left
                let ix = max(centred, end)
                out[i.id] = (ix, y(i))
                end = ix + i.width
            }
        }
        band(above) { top - $0.height }
        band(below) { _ in top + rowHeight }
        return out
    }
}
