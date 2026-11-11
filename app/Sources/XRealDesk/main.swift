#if os(macOS)
import AppKit

let options: Options
do {
    options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n\n\(Options.usage)\n".utf8))
    exit(2)
}
if let out = options.out {
    do { try Log.open(out) } catch {
        FileHandle.standardError.write(Data("cannot write to \(out.path): \(error)\n".utf8))
        exit(2)
    }
} else {
    // Started from Finder there is no terminal: keep the last run's log where Console.app and the user can find it.
    let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/XRealDesk")
    do { try Log.open(logs) } catch {
        FileHandle.standardError.write(Data("cannot write to \(logs.path): \(error)\n".utf8))
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController(options: options)
    app.delegate = controller
    withExtendedLifetime(controller) { app.run() }
}
#else
import Foundation
FileHandle.standardError.write(Data("XRealDesk needs macOS (AppKit, ScreenCaptureKit, Metal).\n".utf8))
exit(1)
#endif
