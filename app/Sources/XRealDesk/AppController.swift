#if os(macOS)
import AppKit
import CVirtualDisplay
import GlassesLink
import MetalKit
import SpatialRenderer
import XRealCore

/// Menu bar app: one virtual display, captured and shown as a head-tracked screen in a side-by-side window.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    let options: Options
    private let head = HeadState()
    private var link: GlassesLink?
    private var display: XRVirtualDisplay?
    private var capture: ScreenCapture?
    private var renderer: Renderer?
    private var renderWindow: NSWindow?
    private var contentWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusLines: [NSMenuItem] = []
    private var captureStatus = "Capture: starting"
    private var signalSources: [DispatchSourceSignal] = []
    private var lastStats = (time: 0.0, captured: 0, rendered: 0)
    private var fps = (capture: 0.0, render: 0.0)

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        handleSignals()
        Log.line("XRealDesk pid \(ProcessInfo.processInfo.processIdentifier), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), app \(Bundle.main.bundleURL.path)")
        Log.line("displays before: \(describeDisplays())")
        if options.seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { NSApp.terminate(nil) }
        }
        if options.probe {
            probe()
            return
        }
        createDisplay()
        startGlasses()
        startRenderer()
        makeStatusItem()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        for t in options.snapshots {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.snapshot(at: t) }
        }
        startCapture()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    // MARK: probe

    /// Creates the display, lists displays, removes it. Answers "does CGVirtualDisplay work on this macOS?".
    private func probe() {
        Log.line("probe: CGVirtualDisplay classes present: \(XRVirtualDisplay.isAvailable())")
        createDisplay()
        guard let display else {
            Log.line("probe: RESULT virtual display NOT created")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let id = display.displayID
            Log.line("probe: displays with virtual: \(describeDisplays(virtual: id))")
            Log.line("probe: NSScreens: " + NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height)) id \($0.displayID)" }.joined(separator: "; "))
            if let mode = CGDisplayCopyDisplayMode(id) {
                Log.line("probe: virtual mode \(mode.pixelWidth)x\(mode.pixelHeight) px, \(mode.width)x\(mode.height) pt, \(mode.refreshRate) Hz")
            }
            let present = describeDisplays().contains("\(id) ")
            display.invalidate()
            self.display = nil
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

    private func createDisplay() {
        do {
            let d = try XRVirtualDisplay(name: "XReal Desk", width: UInt(options.displayWidth), height: UInt(options.displayHeight),
                                         refreshRate: 60, hiDPI: false, sizeInMillimeters: CGSize(width: 600, height: 338),
                                         terminated: { Log.line("virtual display: terminated by the system") })
            guard d.displayID != kCGNullDirectDisplay else {
                Log.line("virtual display: FAILED: no display id")
                return
            }
            display = d
            Log.line("virtual display: created id \(d.displayID) \(options.displayWidth)x\(options.displayHeight)")
        } catch {
            Log.line("virtual display: FAILED: \(error.localizedDescription)")
        }
    }

    private func startGlasses() {
        let head = self.head
        let link = GlassesLink(configuration: GlassesLink.Configuration(host: options.host)) { head.handle($0) }
        Log.line("glasses: connecting to \(options.host)")
        link.start()
        self.link = link
    }

    private func startRenderer() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Log.line("renderer: no Metal device")
            return
        }
        do {
            var capture: ScreenCapture?
            do { capture = try ScreenCapture(device: device) } catch { Log.line("capture: \(error)") }
            self.capture = capture
            // One screen 1.6 m ahead, 0.9 m wide, with the virtual display's aspect ratio.
            var placement = ScreenPlacement()
            placement.height = placement.width * Double(options.displayHeight) / Double(options.displayWidth)
            let head = self.head
            let renderer = try Renderer(device: device) { [placement] in
                guard let displays = head.calibration?.displays else { return (nil, nil) }
                let frame = capture?.latestFrame
                return (Renderer.Scene(displays: displays, head: head.orientation, screen: placement, texture: frame?.texture),
                        frame?.backing)
            }
            let window: NSWindow
            if let id = options.outputDisplay {
                guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else {
                    Log.line("renderer: --output display \(id) not found; \(describeDisplays())")
                    NSApp.terminate(nil)
                    return
                }
                // Borderless and covering the whole display; the 3840×1080 drawable is scaled to the screen.
                let view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size))
                renderer.attach(to: view, eyeWidth: 1920, eyeHeight: 1080)
                window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                window.level = .screenSaver
                window.setFrame(screen.frame, display: true)
                Log.line("renderer: full screen on display \(id) (\(Int(screen.frame.width))×\(Int(screen.frame.height)) pt)")
            } else {
                let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 540))
                renderer.attach(to: view, eyeWidth: 1920, eyeHeight: 1080)
                window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
                window.title = "XReal Desk: side-by-side 3840×1080 (shown at half size)"
                window.contentView = view
                if let main = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) {
                    window.setFrameTopLeftPoint(NSPoint(x: main.visibleFrame.minX + 20, y: main.visibleFrame.maxY - 20))
                }
            }
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            self.renderer = renderer
            renderWindow = window
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.charactersIgnoringModifiers == "r" { self?.recenter(); return nil }
                return e
            }
        } catch {
            Log.line("renderer: \(error)")
        }
    }

    private func startCapture() {
        guard let display, let capture else { return }
        if !ScreenRecordingPermission.isGranted {
            ScreenRecordingPermission.request()
            captureStatus = "Capture: Screen Recording permission needed (see log)"
            Log.line("capture: PERMISSION MISSING. \(ScreenRecordingPermission.instructions)")
            return
        }
        capture.onStop = { error in Log.line("capture: stopped: \(error)") }
        let id = display.displayID, w = options.displayWidth, h = options.displayHeight
        let own = Set([renderWindow?.windowNumber].compactMap { $0 })
        Task { @MainActor in
            await placeContentWindow()
            do {
                try await capture.start(displayID: id, width: w, height: h, excluding: own)
                self.captureStatus = "Capture: running"
                Log.line("capture: started on display \(id) (excluding our render window)")
            } catch {
                self.captureStatus = "Capture: failed (see log)"
                Log.line("capture: FAILED: \(error)")
                if !ScreenRecordingPermission.isGranted { Log.line("capture: \(ScreenRecordingPermission.instructions)") }
            }
        }
    }

    /// A window on the virtual display, so the captured content is recognisable and keeps changing. On a Mac without
    /// a monitor the virtual display is the only one and also holds the render window; then the pattern takes the
    /// lower half so it does not cover the render window (an occluded window gets fewer frames).
    private func placeContentWindow() async {
        guard let id = display?.displayID else { return }
        var screen: NSScreen?
        for _ in 0..<30 {
            screen = NSScreen.screens.first { $0.displayID == id }
            if screen != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let screen else {
            Log.line("content window: virtual display \(id) not among NSScreens")
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
        contentWindow = window
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "XR"
        let menu = NSMenu()
        statusLines = (0..<3).map { _ in
            let line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            return line
        }
        menu.addItem(.separator())
        let recenter = NSMenuItem(title: "Recenter", action: #selector(recenterAction), keyEquivalent: "r")
        recenter.target = self
        menu.addItem(recenter)
        menu.addItem(NSMenuItem(title: "Quit XReal Desk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        updateStatus()
    }

    @objc private func recenterAction() { recenter() }

    private func recenter() {
        head.recenter()
        Log.line("recentered")
    }

    private func tick() {
        let now = Log.elapsed
        let captured = capture?.framesReceived ?? 0, rendered = renderer?.framesRendered ?? 0
        let dt = now - lastStats.time
        if dt > 0 {
            fps = (Double(captured - lastStats.captured) / dt, Double(rendered - lastStats.rendered) / dt)
        }
        lastStats = (now, captured, rendered)
        (contentWindow?.contentView as? TestPatternView)?.needsDisplay = true
        updateStatus()
    }

    private func updateStatus() {
        guard statusLines.count == 3 else { return }
        statusLines[0].title = head.status
        statusLines[1].title = display.map { "Virtual display: \($0.displayID), \(options.displayWidth)×\(options.displayHeight)" } ?? "Virtual display: none"
        statusLines[2].title = captureStatus + String(format: " · capture %.0f fps · render %.0f fps", fps.capture, fps.render)
    }

    private func snapshot(at t: Double) {
        let p = HeadPose(head.orientation)
        Log.line(String(format: "snapshot t=%.0f s: yaw %.1f pitch %.1f roll %.1f, capture %.0f fps (%d frames), render %.0f fps",
                        t, p.yaw, p.pitch, p.roll, fps.capture, capture?.framesReceived ?? 0, fps.render))
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
        renderWindow?.orderOut(nil)
        contentWindow?.orderOut(nil)
        link?.stop()
        if let capture {
            let done = DispatchSemaphore(value: 0)
            Task.detached { await capture.stop(); done.signal() }
            _ = done.wait(timeout: .now() + 2)
        }
        let id = display?.displayID
        display?.invalidate()
        display = nil
        Log.line("quit: virtual display \(id.map(String.init) ?? "-") removed; displays now: \(describeDisplays())")
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

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? kCGNullDirectDisplay
    }
}
#endif
