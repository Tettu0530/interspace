import AppKit
import SwiftUI
import ApplicationServices
import CDockSwipe
import ServiceManagement

/// `--unregister-login-item` takes the app out of the login items, then exits. For an uninstall, or before
/// the app is renamed or moved. Only the app itself can do this, so it is a mode of the app.
if CommandLine.arguments.contains("--unregister-login-item") {
    do {
        try SMAppService.mainApp.unregister()
        print("login item removed")
    } catch {
        print("login item not removed: \(error.localizedDescription)")
    }
    exit(0)
}

/// `Interspace --diagnose` prints what the app can see, then exits. It shows no prompt and changes nothing.
private func diagnose() {
    let version = ProcessInfo.processInfo.operatingSystemVersionString
    print("macOS: \(version)")
    print("IOHID payload required (macOS 27+): \(ds_requires_event_augmentation())")
    print("Accessibility access: \(AXIsProcessTrusted())")
    print("Screen Recording access: \(CGPreflightScreenCaptureAccess())")

    let monitor = MultitouchMonitor.shared
    print("MultitouchSupport loaded: \(monitor.isAvailable)")
    print("Multitouch devices: \(monitor.start() ? monitor.deviceCount : 0)")
    monitor.stop()

    print("Space list API: \(Spaces.isAvailable)")
    for screen in NSScreen.screens {
        let size = "\(Int(screen.frame.width))x\(Int(screen.frame.height)) @\(screen.backingScaleFactor)x"
        if let layout = Spaces.layout(for: screen) {
            print("Screen \(screen.displayID) (\(size)): \(layout.spaceIDs.count) spaces, current index \(layout.currentIndex), ids \(layout.spaceIDs)")
        } else {
            print("Screen \(screen.displayID) (\(size)): no space information")
        }
    }
}

if CommandLine.arguments.contains("--diagnose") {
    diagnose()
    exit(0)
}

/// `Interspace --dump-capture <folder>` writes the snapshot of the main screen, and the piece that
/// covers the island, then exits. Start it through `open` so it runs with the app's permissions.
if let flag = CommandLine.arguments.firstIndex(of: "--dump-capture"), CommandLine.arguments.count > flag + 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let snapshotter = Snapshotter()
    func write(_ image: CGImage?, _ name: String) {
        guard let image else { return }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try? data?.write(to: folder.appendingPathComponent(name))
    }
    _ = NSApplication.shared
    snapshotter.refreshDisplays {
        guard let screen = NSScreen.main else { exit(1) }
        let started = CACurrentMediaTime()
        // Add `--below-dock` for the image the app uses when the Dock stays in place.
        snapshotter.capture(screen: screen, includeDock: !CommandLine.arguments.contains("--below-dock")) { snapshot in
            let milliseconds = Int((CACurrentMediaTime() - started) * 1000)
            write(snapshot?.image, "image.png")
            write(snapshot?.patch, "patch.png")
            let report = "capture: \(milliseconds) ms\npatch frame: \(snapshot?.patchFrame ?? .zero)\n"
                + "includes the Dock: \(snapshot.map { String($0.includesDock) } ?? "no image")\n"
            try? report.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            // The capture used during the visit of all spaces: everything below one of our windows.
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            snapshotter.refreshDisplays {
                snapshotter.captureBelow(windowNumber: panel.windowNumber, screen: screen) { below in
                    write(below?.image, "below.png")
                    exit(0)
                }
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(2) }
    NSApplication.shared.run()
}

/// `Interspace --render-settings <folder>` draws the settings window to pictures, in dark and light.
/// Nothing shows on screen.
if let flag = CommandLine.arguments.firstIndex(of: "--render-settings"), CommandLine.arguments.count > flag + 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    _ = NSApplication.shared
    // A moment in the middle of a move, so the picture shows the display between two spaces.
    TransitionPreview.fixedTime = 0.16
    for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
        let host = NSHostingView(rootView: SettingsView(settings: .shared))
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.wantsLayer = true
        // A stand-in for the blur, which a picture taken off screen does not have.
        host.layer?.backgroundColor = (name == "dark" ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.75, alpha: 1)).cgColor
        host.layer?.cornerRadius = SettingsWindowController.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("settings-\(name).png"))
        }
    }
    exit(0)
}

/// `Interspace --show-settings` opens only the settings window, to look at it. The app itself does not start,
/// so this can run next to an installed copy.
if CommandLine.arguments.contains("--show-settings") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let settingsWindow = SettingsWindowController()
    settingsWindow.show()
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
        exit(0)
    }
    withExtendedLifetime(settingsWindow) {
        app.run()
    }
}

/// `Interspace --render-icon <file>` draws the menu bar icon, much larger, on white and on black.
if let flag = CommandLine.arguments.firstIndex(of: "--render-icon"), CommandLine.arguments.count > flag + 1 {
    let zoom: CGFloat = 16
    let width = Int(MenuBarIcon.size.width * zoom), height = Int(MenuBarIcon.size.height * zoom)
    if let context = CGContext(
        data: nil, width: width * 2, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) {
        for (index, dark) in [false, true].enumerated() {
            // The icon is a template: black shapes on nothing. Draw it alone, then put a colour through it.
            guard let layer = CGLayer(context, size: CGSize(width: width, height: height), auxiliaryInfo: nil),
                  let icon = layer.context else { continue }
            icon.translateBy(x: 0, y: CGFloat(height))
            icon.scaleBy(x: zoom, y: -zoom)
            MenuBarIcon.draw(in: icon)
            icon.setBlendMode(.sourceIn)
            icon.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: 1))
            icon.fill(CGRect(origin: .zero, size: MenuBarIcon.size))

            let rect = CGRect(x: index * width, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: dark ? 0.12 : 0.95, alpha: 1))
            context.fill(rect)
            context.draw(layer, in: rect)
        }
        if let image = context.makeImage() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
    }
    exit(0)
}

// Two instances would both post a swipe and switch two spaces.
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty, !CommandLine.arguments.contains("--replace") {
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
