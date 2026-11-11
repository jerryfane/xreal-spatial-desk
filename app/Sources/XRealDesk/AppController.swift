#if os(macOS)
import AppKit
import CVirtualDisplay
import GlassesLink
import MetalKit
import SpatialRenderer
import XRealCore

/// One screen of the layout as a live macOS display and its capture.
@MainActor
final class ScreenSlot {
    let id: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let display: XRVirtualDisplay
    let capture: ScreenCapture?
    var captureStatus = "starting"
    var contentWindow: NSWindow?
    /// Set when the screen leaves the layout; a capture that finishes starting afterwards stops itself.
    var removed = false

    init(id: Int, pixelWidth: Int, pixelHeight: Int, display: XRVirtualDisplay, capture: ScreenCapture?) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.display = display
        self.capture = capture
    }

    var displayID: CGDirectDisplayID { display.displayID }
}

/// Menu bar app: the layout's screens as virtual displays, captured and shown as head-tracked screens in a
/// side-by-side window.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let options: Options
    private let head = HeadState()
    private var link: GlassesLink?
    private let modes = DisplayModeController()
    private var library = LayoutLibrary()
    /// False when layouts.json exists but could be neither used nor moved aside (see LayoutLibrary.load).
    private var libraryWritable = true
    private var slots: [Int: ScreenSlot] = [:]
    private var device: MTLDevice?
    private var renderer: Renderer?
    private var renderWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusLines: [NSMenuItem] = []
    private var permissionRequested = false
    /// The last arrangement asked of macOS, as display ID → [x, y]; asked again only when it changes.
    private var requestedArrangement: [UInt32: [Int]] = [:]
    /// Serial number for the next virtual display: a re-created screen (new resolution) gets a new one, so it is
    /// never confused with the display being torn down.
    private var nextSerial: UInt32 = 1
    private var signalSources: [DispatchSourceSignal] = []
    private var lastStats = (time: 0.0, captured: 0, rendered: 0)
    private var fps = (capture: 0.0, render: 0.0)

    init(options: Options) {
        self.options = options
    }

    private var layout: Layout { library.current }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        handleSignals()
        Log.line("XRealDesk pid \(ProcessInfo.processInfo.processIdentifier), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), app \(Bundle.main.bundleURL.path)")
        Log.line("displays before: \(describeDisplays())")
        if options.seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { NSApp.terminate(nil) }
        }
        loadLibrary()
        if options.probe {
            probe()
            return
        }
        if options.sbsCheck {
            sbsCheck()
            return
        }
        startGlasses()
        startRenderer()
        applyLayout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.placeRenderWindow(.displaysChanged)
                self?.arrangeDisplays()
            }
        }
        if options.sbs { setSideBySide(true) }
        makeStatusItem()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        for t in options.snapshots {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.snapshot(at: t) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    // MARK: layouts

    private func loadLibrary() {
        let loaded = LayoutLibrary.load()
        library = loaded.library
        libraryWritable = loaded.safeToWrite
        if let problem = loaded.problem { Log.line("layouts: \(problem)") }
        if let name = options.layout {
            if let l = (library.saved + Layout.presets).first(where: { $0.name == name }) {
                library.current = l
            } else {
                Log.line("layouts: no layout named \"\(name)\"; using \"\(library.current.name)\"")
            }
        }
        Log.line("layout: \"\(layout.name)\", \(layout.screens.count) screen(s)")
    }

    /// Makes the displays match the layout: removes screens that left it (or changed resolution), creates the new
    /// ones, saves the library, and lets the arrangement and status follow.
    private func applyLayout() {
        for (id, slot) in slots {
            if let s = layout.screen(id), s.pixelWidth == slot.pixelWidth, s.pixelHeight == slot.pixelHeight { continue }
            removeSlot(slot)
        }
        for s in layout.screens where slots[s.id] == nil {
            guard let slot = createSlot(s) else { continue }
            slots[s.id] = slot
            startCapture(slot)
        }
        saveLibrary()
        // New displays appear asynchronously; the screen-parameters notification arranges them too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.arrangeDisplays() }
        updateStatus()
    }

    private func changeLayout(_ change: (inout Layout) -> Void) {
        var l = library.current
        change(&l)
        library.current = l
        applyLayout()
    }

    @discardableResult
    private func saveLibrary() -> Bool {
        guard libraryWritable else {
            Log.line("layouts: not saved (the existing layouts.json could not be read or moved aside)")
            return false
        }
        do {
            try library.write()
            return true
        } catch {
            Log.line("layouts: not saved: \(error)")
            return false
        }
    }

    private func createSlot(_ s: SpatialScreen) -> ScreenSlot? {
        guard let display = makeDisplay(s) else { return nil }
        var capture: ScreenCapture?
        if let device {
            do { capture = try ScreenCapture(device: device) } catch { Log.line("capture: \(error)") }
        }
        return ScreenSlot(id: s.id, pixelWidth: s.pixelWidth, pixelHeight: s.pixelHeight, display: display, capture: capture)
    }

    private func makeDisplay(_ s: SpatialScreen) -> XRVirtualDisplay? {
        do {
            // About 81 dpi, as a 27-inch 1080p monitor; macOS uses it only for its own defaults.
            let mm = CGSize(width: Double(s.pixelWidth) * 0.3125, height: Double(s.pixelHeight) * 0.3125)
            let d = try XRVirtualDisplay(name: "XReal Desk \(s.id)", width: UInt(s.pixelWidth), height: UInt(s.pixelHeight),
                                         refreshRate: 60, hiDPI: false, sizeInMillimeters: mm, serialNumber: nextSerial,
                                         terminated: { Log.line("virtual display: screen \(s.id) terminated by the system") })
            nextSerial += 1
            guard d.displayID != kCGNullDirectDisplay else {
                Log.line("virtual display: screen \(s.id) FAILED: no display id")
                return nil
            }
            Log.line("virtual display: screen \(s.id) created id \(d.displayID) \(s.pixelWidth)x\(s.pixelHeight)")
            return d
        } catch {
            Log.line("virtual display: screen \(s.id) FAILED: \(error.localizedDescription)")
            return nil
        }
    }

    private func removeSlot(_ slot: ScreenSlot) {
        slot.removed = true
        slots[slot.id] = nil
        slot.contentWindow?.orderOut(nil)
        if let capture = slot.capture { Task { await capture.stop() } }
        slot.display.invalidate()
        Log.line("virtual display: screen \(slot.id) removed")
    }

    /// Puts our displays in macOS's arrangement the way they sit around the head (see `DisplayArrangement`), for this
    /// login session only. Does nothing until every display has appeared. Once an arrangement is applied (or already
    /// in place) it is not asked again until the wanted arrangement changes (layout, displays, sizes): if macOS adjusts
    /// it, or the user rearranges in System Settings, that stays. A failed attempt is retried on the next change.
    private func arrangeDisplays() {
        let ours = Set(slots.values.map(\.displayID))
        guard !ours.isEmpty else { return }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let others = ids.filter { !ours.contains($0) }
        guard ours.isSubset(of: Set(ids)), let first = others.first else { return }
        let box = others.dropFirst().reduce(CGDisplayBounds(first)) { $0.union(CGDisplayBounds($1)) }
        let items = layout.screens.compactMap { s -> DisplayArrangement.Item? in
            guard let id = slots[s.id]?.displayID else { return nil }
            let b = CGDisplayBounds(id)
            return DisplayArrangement.Item(id: id, yaw: s.yaw, pitch: s.pitch, width: Int(b.width), height: Int(b.height))
        }
        let origins = DisplayArrangement.origins(items, rightOf: (Int(box.minX), Int(box.minY), Int(box.width), Int(box.height)))
        let request = origins.mapValues { [$0.x, $0.y] }
        guard request != requestedArrangement else { return }
        let moves = origins.filter { id, o in
            let b = CGDisplayBounds(id)
            return Int(b.minX) != o.x || Int(b.minY) != o.y
        }
        guard !moves.isEmpty else {
            requestedArrangement = request
            return
        }
        let described = moves.map { "\($0.key) → (\($0.value.x), \($0.value.y))" }.sorted().joined(separator: ", ")
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            Log.line("arrangement: \(described): FAILED to begin (\(begin.rawValue))")
            return
        }
        for (id, o) in moves {
            let r = CGConfigureDisplayOrigin(config, id, Int32(o.x), Int32(o.y))
            guard r == .success else {
                CGCancelDisplayConfiguration(config)
                Log.line("arrangement: \(described): FAILED for display \(id) (\(r.rawValue))")
                return
            }
        }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result == .success { requestedArrangement = request }
        Log.line("arrangement: \(described): \(result == .success ? "done" : "FAILED (\(result.rawValue))")")
    }

    // MARK: probe

    /// Creates one display, lists displays, removes it. Answers "does CGVirtualDisplay work on this macOS?".
    private func probe() {
        Log.line("probe: CGVirtualDisplay classes present: \(XRVirtualDisplay.isAvailable())")
        guard let display = makeDisplay(layout.screens[0]) else {
            Log.line("probe: RESULT virtual display NOT created")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let id = display.displayID
            Log.line("probe: displays with virtual: \(describeDisplays())")
            Log.line("probe: NSScreens: " + NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height)) id \($0.displayID)" }.joined(separator: "; "))
            if let mode = CGDisplayCopyDisplayMode(id) {
                Log.line("probe: virtual mode \(mode.pixelWidth)x\(mode.pixelHeight) px, \(mode.width)x\(mode.height) pt, \(mode.refreshRate) Hz")
            }
            let present = describeDisplays().contains("\(id) ")
            display.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let after = describeDisplays()
                let removed = !after.contains("\(id) ")
                Log.line("probe: displays after removal: \(after)")
                Log.line("probe: RESULT created=\(present) removed=\(removed)")
                exit(present && removed ? 0 : 1)
            }
        }
    }

    // MARK: setup

    private func startGlasses() {
        let head = self.head, modes = self.modes
        let link = GlassesLink(configuration: GlassesLink.Configuration(host: options.host)) { event in
            head.handle(event)
            modes.handle(event)
        }
        Log.line("glasses: connecting to \(options.host)")
        modes.attach(link)
        link.start()
        self.link = link
    }

    // MARK: side-by-side (milestone 1)

    /// Owner-watched first hardware run: only the link, then the scripted mode check; the app quits when it ends.
    private func sbsCheck() {
        startGlasses()
        let modes = self.modes
        DispatchQueue.global().async {
            let pass = modes.runCheck()
            DispatchQueue.main.async { exit(pass ? 0 : 1) }
        }
    }

    private func setSideBySide(_ on: Bool) {
        if on {
            guard let glasses = GlassesDisplay.find() else {
                Log.line("display mode: glasses display not found (\(describeDisplays())); side-by-side not switched on")
                updateStatus()
                return
            }
            // Cover the glasses with our image before they switch, so neither eye ever sees half a desktop. If they
            // cannot be covered (no renderer, screen not found), do not switch.
            guard placeRenderWindow(.sideBySideOn, forceGlasses: glasses) == glasses.id else {
                Log.line("display mode: could not cover the glasses with the image; side-by-side not switched on")
                updateStatus()
                return
            }
            _ = modes.switchTo(.sideBySide, glasses: glasses)
        } else if modes.keeper.restore() != nil {
            // The window stays on the glasses until they report regular mode again (placeRenderWindow on the change).
            modes.send(why: "menu")
        }
        updateStatus()
    }

    /// Places the side-by-side image per `RenderTarget.choose`: on the glasses whenever they are (or are being
    /// switched to) side-by-side, or a switch back is owed, even over --output; else on --output or in a half-size
    /// preview window. Called on every display change and every second (`tick`); it moves the window only when the
    /// target or the target screen's frame changed, so whatever cleared or set a condition, the next call reconciles.
    /// Returns the display now covered.
    @discardableResult
    private func placeRenderWindow(_ trigger: PlacementTrigger, forceGlasses: GlassesDisplay? = nil) -> CGDirectDisplayID? {
        guard let window = renderWindow else { return nil }
        let glasses = forceGlasses ?? GlassesDisplay.find()
        if forceGlasses == nil, let mode = glasses?.mode { modes.keeper.glassesObserved(mode) }
        let target = RenderTarget.choose(outputDisplay: options.outputDisplay, glassesDisplay: glasses?.id,
                                         glassesSideBySide: glasses?.mode == .sideBySide,
                                         sideBySideWanted: forceGlasses != nil || sideBySideOn
                                             || modes.keeper.awaitingPhysicalRestore != nil)
        if case .display(let id) = target, let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            let alreadyThere = window.level == .screenSaver && window.frame == screen.frame
            if !alreadyThere {
                window.styleMask = [.borderless]
                window.level = .screenSaver
                window.setFrame(screen.frame, display: true)
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
                Log.line("renderer: full screen on display \(id) (\(Int(screen.frame.width))×\(Int(screen.frame.height)) pt; \(trigger.rawValue)); Esc quits")
            }
            return id
        }
        if case .display(let id) = target, trigger.logsMissingDisplay {
            Log.line("renderer: display \(id) not among screens (\(trigger.rawValue)); \(describeDisplays())")
        }
        let alreadyPreview = window.level == .normal && window.styleMask.contains(.titled)
        if !alreadyPreview {
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.level = .normal
            window.title = "XReal Desk: side-by-side 3840×1080 (shown at half size)"
            window.setContentSize(NSSize(width: 1920, height: 540))
            if let main = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) {
                window.setFrameTopLeftPoint(NSPoint(x: main.visibleFrame.minX + 20, y: main.visibleFrame.maxY - 20))
            }
            window.orderFrontRegardless()
            Log.line("renderer: preview window (\(trigger.rawValue))")
        }
        return nil
    }

    /// Side-by-side is "on" while this run has the glasses switched away from their original mode.
    private var sideBySideOn: Bool { modes.keeper.requested == .sideBySide && modes.keeper.pendingRestore != nil }

    private func startRenderer() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Log.line("renderer: no Metal device")
            return
        }
        self.device = device
        do {
            let renderer = try Renderer(device: device) { [weak self] in
                // MTKView draws on the main thread.
                var frame: (scene: Renderer.Scene?, keepAlive: Any?) = (nil, nil)
                MainActor.assumeIsolated { frame = self?.scene() ?? (nil, nil) }
                return frame
            }
            // One window; placeRenderWindow decides between full screen on the glasses and a preview window.
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 540))
            view.autoresizingMask = [.width, .height]
            renderer.attach(to: view, eyeWidth: 1920, eyeHeight: 1080)
            let window = KeyableWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable],
                                       backing: .buffered, defer: false)
            window.title = "XReal Desk: side-by-side 3840×1080 (shown at half size)"
            window.contentView = view
            window.isReleasedWhenClosed = false
            if let main = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) {
                window.setFrameTopLeftPoint(NSPoint(x: main.visibleFrame.minX + 20, y: main.visibleFrame.maxY - 20))
            }
            window.orderFrontRegardless()
            self.renderer = renderer
            renderWindow = window
            if let id = options.outputDisplay, !NSScreen.screens.contains(where: { $0.displayID == id }) {
                Log.line("renderer: --output display \(id) not found; \(describeDisplays())")
                NSApp.terminate(nil)
                return
            }
            placeRenderWindow(.start)
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.charactersIgnoringModifiers == "r" { self?.recenter(); return nil }
                // Esc always quits: the full-screen image can cover the only display. Quitting restores the mode.
                if e.keyCode == 53 { NSApp.terminate(nil); return nil }
                return e
            }
        } catch {
            Log.line("renderer: \(error)")
        }
    }

    /// Every screen of the layout with its latest captured frame (a placeholder until the first one). The frames'
    /// backings are kept alive until the GPU is done with them.
    private func scene() -> (scene: Renderer.Scene?, keepAlive: Any?) {
        guard let displays = head.calibration?.displays else { return (nil, nil) }
        var backings: [CVMetalTexture] = []
        let screens = layout.screens.map { s -> Renderer.Screen in
            let frame = slots[s.id]?.capture?.latestFrame
            if let frame { backings.append(frame.backing) }
            return Renderer.Screen(placement: s.placement, texture: frame?.texture)
        }
        return (Renderer.Scene(displays: displays, head: head.orientation, screens: screens), backings)
    }

    private func startCapture(_ slot: ScreenSlot) {
        guard let capture = slot.capture else {
            slot.captureStatus = "unavailable"
            return
        }
        if !ScreenRecordingPermission.isGranted {
            slot.captureStatus = "Screen Recording permission needed (see log)"
            if !permissionRequested {
                permissionRequested = true
                ScreenRecordingPermission.request()
                Log.line("capture: PERMISSION MISSING. \(ScreenRecordingPermission.instructions)")
            }
            return
        }
        let id = slot.displayID, screenID = slot.id
        capture.onStop = { error in Log.line("capture: screen \(screenID) stopped: \(error)") }
        let own = Set([renderWindow?.windowNumber].compactMap { $0 })
        Task { @MainActor in
            if options.testPattern { await placeContentWindow(slot) }
            do {
                try await capture.start(displayID: id, width: slot.pixelWidth, height: slot.pixelHeight, excluding: own)
                if slot.removed {
                    await capture.stop()
                    return
                }
                slot.captureStatus = "running"
                Log.line("capture: screen \(screenID) started on display \(id) (excluding our render window)")
            } catch {
                slot.captureStatus = "failed (see log)"
                Log.line("capture: screen \(screenID) FAILED: \(error)")
                if !ScreenRecordingPermission.isGranted { Log.line("capture: \(ScreenRecordingPermission.instructions)") }
            }
        }
    }

    /// With --test-pattern: a window covering the virtual display, so the captured content is recognisable and keeps
    /// changing in unattended runs. Without it the display shows its own desktop. On a Mac without a monitor the
    /// first virtual display can be the only real screen and also hold the render window; then the pattern takes the
    /// lower half so it does not cover the render window (an occluded window gets fewer frames).
    private func placeContentWindow(_ slot: ScreenSlot) async {
        let id = slot.displayID
        var screen: NSScreen?
        for _ in 0..<30 {
            screen = NSScreen.screens.first { $0.displayID == id }
            if screen != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let screen, !slot.removed else {
            if !slot.removed { Log.line("content window: virtual display \(id) not among NSScreens") }
            return
        }
        var frame = screen.frame
        if renderWindow?.screen == screen {
            frame.size.height /= 2
            Log.line("content window: virtual display is also the render window's screen (\(NSScreen.screens.count) screen(s)); using its lower half")
        }
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = TestPatternView(frame: NSRect(origin: .zero, size: frame.size), displayID: id)
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        renderWindow?.orderFrontRegardless()
        slot.contentWindow = window
    }

    // MARK: menu

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "XR"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        buildMenu(menu)
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { buildMenu(menu) }
    }

    /// The whole menu, rebuilt each time it opens so it always shows the current layout.
    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        statusLines = (0..<3).map { _ in
            let line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            return line
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Recenter", key: "r") { [weak self] in self?.recenter() })
        var sbsTitle = "Side-by-side 3D on the glasses"
        if let last = modes.keeper.last, last.result != .accepted { sbsTitle += " (glasses replied: \(last.result))" }
        menu.addItem(ActionItem(sbsTitle, key: "s", checked: sideBySideOn) { [weak self] in
            guard let self else { return }
            setSideBySide(!sideBySideOn)
        })
        menu.addItem(.separator())
        menu.addItem(submenu("Screens", screensMenu()))
        menu.addItem(submenu("Layouts", layoutsMenu()))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit XReal Desk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        updateStatus()
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for i in items { menu.addItem(i) }
        item.submenu = menu
        return item
    }

    private static let sizes: [Double] = [27, 32, 40, 48, 55, 65, 85]
    private static let distances: [Double] = [1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
    private static let shapes: [(radius: Double, title: String)] = [
        (0, "Flat"), (4, "Curved 4000R"), (2.5, "Curved 2500R"), (1.8, "Curved 1800R"), (1, "Curved 1000R"),
    ]
    private static let resolutions: [(w: Int, h: Int, title: String)] = [
        (1920, 1080, "1920×1080 (16:9)"), (2560, 1440, "2560×1440 (16:9)"), (2560, 1080, "2560×1080 (21:9)"),
        (3440, 1440, "3440×1440 (21:9)"), (3840, 1080, "3840×1080 (32:9)"), (1080, 1920, "1080×1920 (portrait)"),
    ]
    private static let positions: [(pitch: Double, title: String)] = [(0, "In the row"), (25, "Above the row"), (-25, "Below the row")]

    private func screensMenu() -> [NSMenuItem] {
        var items = layout.screens.map { s -> NSMenuItem in
            let shape = Self.shapes.first { $0.radius == s.curveRadius }?.title ?? String(format: "Curved %.0fR", s.curveRadius * 1000)
            let title = String(format: "Screen %d: %.0f″ %@, %d×%d, %.1f m, %.0f°", s.id, s.diagonalInches, shape.lowercased(),
                               s.pixelWidth, s.pixelHeight, s.distance, s.yaw)
            return submenu(title, screenMenu(s))
        }
        items.append(.separator())
        items.append(ActionItem("Add screen", enabled: layout.screens.count < Layout.maxScreens) { [weak self] in
            self?.changeLayout { _ = $0.addScreen() }
        })
        return items
    }

    private func screenMenu(_ s: SpatialScreen) -> [NSMenuItem] {
        let id = s.id
        func edit(_ change: @escaping (inout SpatialScreen) -> Void) -> () -> Void {
            { [weak self] in self?.changeLayout { $0.update(id, change) } }
        }
        let sizes = Self.sizes.map { d in ActionItem(String(format: "%.0f″", d), checked: s.diagonalInches == d, edit { $0.diagonalInches = d }) }
        let distances = Self.distances.map { d in ActionItem(String(format: "%.2g m", d), checked: s.distance == d, edit { $0.distance = d }) }
        let shapes = Self.shapes.map { r in ActionItem(r.title, checked: s.curveRadius == r.radius, edit { $0.curveRadius = r.radius }) }
        let resolutions = Self.resolutions.map { r in
            ActionItem(r.title, checked: s.pixelWidth == r.w && s.pixelHeight == r.h, edit { $0.pixelWidth = r.w; $0.pixelHeight = r.h })
        }
        let positions = Self.positions.map { p in
            ActionItem(p.title, checked: (p.pitch == 0) == s.inRow && (p.pitch == 0 || (p.pitch > 0) == (s.pitch > 0)), edit { $0.pitch = p.pitch })
        }
        return [
            submenu("Size", sizes), submenu("Distance", distances), submenu("Shape", shapes),
            submenu("Resolution", resolutions), submenu("Position", positions), .separator(),
            ActionItem("Remove", enabled: layout.screens.count > 1) { [weak self] in self?.changeLayout { $0.removeScreen(id) } },
        ]
    }

    private func layoutsMenu() -> [NSMenuItem] {
        func choose(_ l: Layout) -> NSMenuItem {
            ActionItem(l.name, checked: l == layout) { [weak self] in
                self?.changeLayout { $0 = l }
                Log.line("layout: \"\(l.name)\"")
            }
        }
        var items = Layout.presets.map(choose)
        if !library.saved.isEmpty {
            items.append(.separator())
            items += library.saved.map(choose)
        }
        items.append(.separator())
        items.append(ActionItem("Save current layout as…") { [weak self] in self?.saveLayoutAs() })
        if !library.saved.isEmpty {
            items.append(submenu("Delete saved layout", library.saved.map { l in
                ActionItem(l.name) { [weak self] in
                    guard let self else { return }
                    library.saved.removeAll { $0.name == l.name }
                    saveLibrary()
                }
            }))
        }
        return items
    }

    private func saveLayoutAs() {
        let alert = NSAlert()
        alert.messageText = "Save layout"
        alert.informativeText = "Name for the current screens. A saved layout with the same name is replaced."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = Layout.presets.contains { $0.name == layout.name } ? "" : layout.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chosen = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty, !Layout.presets.contains(where: { $0.name == chosen }) else {
            Log.line("layouts: not saved: empty name or the name of a preset")
            return
        }
        var l = layout
        l.name = chosen
        library.save(l)
        library.current = l
        if saveLibrary() { Log.line("layouts: saved \"\(chosen)\"") }
    }

    private func recenter() {
        head.recenter()
        Log.line("recentered")
    }

    private func tick() {
        let now = Log.elapsed
        let captured = slots.values.reduce(0) { $0 + ($1.capture?.framesReceived ?? 0) }
        let rendered = renderer?.framesRendered ?? 0
        let dt = now - lastStats.time
        if dt > 0 {
            fps = (Double(captured - lastStats.captured) / dt / Double(max(slots.count, 1)), Double(rendered - lastStats.rendered) / dt)
        }
        lastStats = (now, captured, rendered)
        for slot in slots.values { slot.contentWindow?.contentView?.needsDisplay = true }
        // Reconcile where the image goes once a second. Mode replies arrive on the glasses thread and can change the
        // target with no screen notification after them (e.g. a restore accepted after the display already changed).
        placeRenderWindow(.periodicCheck)
        updateStatus()
    }

    private func updateStatus() {
        guard statusLines.count == 3 else { return }
        statusLines[0].title = head.status
        statusLines[1].title = "Layout: \(layout.name), \(slots.count) of \(layout.screens.count) screen(s) live"
        let statuses = Set(slots.values.map(\.captureStatus))
        let capture = statuses.count == 1 ? statuses.first! : statuses.sorted().joined(separator: " / ")
        statusLines[2].title = "Capture: \(capture.isEmpty ? "none" : capture)"
            + String(format: " · %.0f fps per screen · render %.0f fps", fps.capture, fps.render)
    }

    private func snapshot(at t: Double) {
        let p = HeadPose(head.orientation)
        let frames = slots.values.reduce(0) { $0 + ($1.capture?.framesReceived ?? 0) }
        Log.line(String(format: "snapshot t=%.0f s: yaw %.1f pitch %.1f roll %.1f, capture %.0f fps per screen (%d frames), render %.0f fps",
                        t, p.yaw, p.pitch, p.roll, fps.capture, frames, fps.render))
        guard let out = options.out else { return }
        let name = String(format: "sbs-%03.0fs.png", t)
        renderer?.snapshot(to: out.appendingPathComponent(name)) { ok in
            Log.line(ok ? "snapshot: wrote \(name)" : "snapshot: FAILED \(name)")
        }
    }

    // MARK: teardown

    private func handleSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { Log.line("signal \(sig): quitting"); NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown() {
        // Put the glasses' display mode back first, while the control connection is still up, and keep the image on
        // them until they are seen back in their original mode, so neither eye sees half a desktop meanwhile.
        modes.restoreBlocking()
        renderWindow?.orderOut(nil)
        for slot in slots.values { slot.contentWindow?.orderOut(nil) }
        link?.stop()
        let captures = slots.values.compactMap(\.capture)
        if !captures.isEmpty {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                for c in captures { await c.stop() }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 2)
        }
        let ids = slots.values.map(\.displayID)
        for slot in slots.values { slot.display.invalidate() }
        slots = [:]
        // WindowServer updates the display list asynchronously, so listing displays here would still show them.
        Log.line("quit: virtual displays \(ids.map(String.init).sorted().joined(separator: ", ")) released")
    }
}

/// Grid, label and a clock: recognisable in the capture, and it changes every second so frames keep coming.
final class TestPatternView: NSView {
    let displayID: CGDirectDisplayID

    init(frame: NSRect, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
        let grid = NSBezierPath()
        for x in stride(from: 0.0, through: bounds.width, by: bounds.width / 16) {
            grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: bounds.height))
        }
        for y in stride(from: 0.0, through: bounds.height, by: bounds.height / 9) {
            grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: bounds.width, y: y))
        }
        grid.lineWidth = 2
        grid.stroke()
        // Marks the top-left corner, to check orientation in the capture.
        NSColor.white.setFill()
        NSRect(x: 0, y: bounds.height - bounds.height / 9, width: bounds.width / 16, height: bounds.height / 9).fill()
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let text = "XReal Desk virtual display \(displayID)\n\(Int(bounds.width))×\(Int(bounds.height))  \(time)"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: bounds.height / 12, weight: .semibold),
                                                    .foregroundColor: NSColor.white, .paragraphStyle: style]
        let size = (text as NSString).boundingRect(with: bounds.size, options: [.usesLineFragmentOrigin], attributes: attrs).size
        (text as NSString).draw(with: NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height),
                                options: [.usesLineFragmentOrigin], attributes: attrs)
    }
}

/// Why the image placement is being (re)computed; `rawValue` is the text logged.
enum PlacementTrigger: String {
    case start
    case displaysChanged = "displays changed"
    case sideBySideOn = "side-by-side on"
    case periodicCheck = "periodic check"

    /// The per-second check would repeat the same warning every second.
    var logsMissingDisplay: Bool { self != .periodicCheck }
}

/// A menu item that runs a closure (menus are rebuilt each time they open, so no selectors per item).
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// Borderless windows cannot normally become key; this one must, so Esc reaches the app while it covers the glasses.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? kCGNullDirectDisplay
    }
}
#endif
