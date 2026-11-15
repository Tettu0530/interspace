import AppKit
import ApplicationServices
import CDockSwipe
import Combine
import os
import ServiceManagement
import notify
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let loginItemSetUpKey = "loginItemSetUp"

    private var statusItem: NSStatusItem?
    private let controller = TransitionController()
    private var permissionTimer: Timer?

    private let settings = AppSettings.shared
    private let settingsWindow = SettingsWindowController()
    private var settingsObserver: AnyCancellable?
    private var hasAccessibility = false
    private var hasScreenRecording = false
    private var tapInstalled = false
    private var keyTapInstalled = false
    private var hasTrackpad = false

    private let log = Logger(subsystem: "com.cnrad.interspace", category: "state")
    private var lastStatus = ""
    private var didCaptureSpaces = false
    private var devRecorder: DevRecorder?
    /// The kind of image the spaces were captured as: with the Dock in it, or without.
    private var capturedWithDock: Bool?
    private var selfTestToken: Int32 = 0
    private var coverTestToken: Int32 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The notice comes before the value changes, so read it one step later.
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.evaluate()
            }
        }

        setUpStatusItem()

        // Open at login is on by default. This runs one time, so a later choice in the menu stays.
        if !UserDefaults.standard.bool(forKey: Self.loginItemSetUpKey) {
            UserDefaults.standard.set(true, forKey: Self.loginItemSetUpKey)
            setOpensAtLogin(true)
        }
        log.notice("opens at login: \(self.opensAtLogin)")

        SpaceShortcuts.onStep = { [weak self] step in
            self?.controller.keyboardStep(step)
        }

        MultitouchMonitor.shared.debugLogging = CommandLine.arguments.contains("--debug-touches")
        MultitouchMonitor.shared.onFrame = { [weak self] frame in
            self?.controller.handle(frame)
        }
        hasTrackpad = MultitouchMonitor.shared.start()

        // Both prompts appear one time. The timer below sees the result.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        // Development only. When the app is started with `--dev`, `notifyutil -p com.cnrad.interspace.selftest`
        // replays swipes with no hands and writes small pictures of the screen to /tmp/sg-frames.
        if CommandLine.arguments.contains("--dev") {
            notify_register_dispatch("com.cnrad.interspace.selftest", &selfTestToken, .main) { [weak self] _ in
                self?.runSelfTest()
            }
            // `notifyutil -p com.cnrad.interspace.covertest`: the cover with no space switch, short and long, recorded.
            notify_register_dispatch("com.cnrad.interspace.covertest", &coverTestToken, .main) { [weak self] _ in
                guard let self, let screen = NSScreen.main else { return }
                let recorder = DevRecorder()
                self.devRecorder = recorder
                recorder.start(screen: screen)
                let holds = [0.3, 1.5]
                for (index, hold) in holds.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(index) * 1.7) {
                        self.log.notice("cover test: \(hold) s")
                        self.controller.debugCoverTest(hold: hold)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(holds.count) * 1.7 + 0.5) {
                    recorder.stop(folder: URL(fileURLWithPath: "/tmp/sg-frames")) { self.log.notice("recording written"); self.devRecorder = nil }
                }
            }
        }

        evaluate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    /// Turns the transition on only when every part it needs works. If not, the system swipe stays as it is.
    private func evaluate() {
        hasAccessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        if screenRecording, !hasScreenRecording {
            controller.prewarm()
        }
        hasScreenRecording = screenRecording

        if hasAccessibility, !tapInstalled {
            tapInstalled = ds_tap_install()
        }
        if hasAccessibility, !keyTapInstalled {
            keyTapInstalled = SpaceShortcuts.install()
            log.notice("keyboard tap installed: \(self.keyTapInstalled)")
        }
        if !hasTrackpad {
            hasTrackpad = MultitouchMonitor.shared.start()
        }

        let active = settings.transition.isCustom && hasAccessibility && hasScreenRecording && tapInstalled && hasTrackpad
            && Spaces.isAvailable
        let status = "active=\(active) transition=\(settings.transition.rawValue) accessibility=\(hasAccessibility) "
            + "screenRecording=\(hasScreenRecording) tap=\(tapInstalled) trackpad=\(hasTrackpad) spaces=\(Spaces.isAvailable)"
        if status != lastStatus {
            lastStatus = status
            log.notice("\(status, privacy: .public)")
        }

        controller.isEnabled = active
        // The images of the other spaces are of the wrong kind after this setting changes. Capture them again.
        if capturedWithDock != settings.dockMovesWithSpace {
            capturedWithDock = settings.dockMovesWithSpace
            didCaptureSpaces = false
        }
        // Instant draws nothing and needs no images. They are taken when a drawn transition is chosen.
        if active, settings.transition.isDrawn, !didCaptureSpaces, Config.captureSpacesAtLaunch {
            didCaptureSpaces = true
            // Development: record the screen during this capture of all spaces.
            if CommandLine.arguments.contains("--dev"), let screen = NSScreen.main {
                let recorder = DevRecorder()
                devRecorder = recorder
                recorder.start(screen: screen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                    recorder.stop(folder: URL(fileURLWithPath: "/tmp/sg-frames")) {
                        self?.log.notice("recording written")
                        self?.devRecorder = nil
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.controller.captureAllSpaces()
            }
        }
        ds_tap_set_suppress(active)
        // The keyboard shortcuts get the same transition as the swipe. Read again each time: the user can
        // change the shortcuts in System Settings.
        SpaceShortcuts.update(enabled: active && keyTapInstalled)
        statusItem?.button?.appearsDisabled = !active
    }

    @objc private func didWake() {
        // The contact callbacks can stop after sleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.hasTrackpad = MultitouchMonitor.shared.start()
            self.evaluate()
        }
    }

    @objc private func screensChanged() {
        controller.displaysChanged()
        hasTrackpad = MultitouchMonitor.shared.start()
        evaluate()
    }

    // MARK: - Self test

    /// Sends the touch frames of a three-finger swipe to the controller, as the trackpad would.
    /// `travel` is in trackpad widths, negative to the left. Calls `completion` at the release.
    private func replaySwipe(travel: CGFloat, duration: Double, rest: Double = 0.06, completion: @escaping () -> Void) {
        let start = CACurrentMediaTime()
        let device: UInt = 0xFEED
        func frame(_ x: CGFloat, _ fingers: Int) -> TouchFrame {
            let points = (0..<fingers).map { CGPoint(x: x + CGFloat($0) * 0.08, y: 0.5) }
            return TouchFrame(device: device, timestamp: CACurrentMediaTime(), points: points)
        }
        let origin: CGFloat = travel < 0 ? 0.75 : 0.1
        controller.handle(frame(origin, 3))
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { return }
            let elapsed = CACurrentMediaTime() - start
            // The fingers rest for a moment first, as real ones do.
            let t = min(max((elapsed - rest) / duration, 0), 1)
            if t >= 1 {
                timer.invalidate()
                self.controller.handle(frame(origin + travel, 2))
                self.controller.handle(frame(origin + travel, 0))
                completion()
            } else {
                self.controller.handle(frame(origin + travel * CGFloat(t), 3))
            }
        }
    }

    private func runSelfTest() {
        log.notice("self test start")
        func after(_ delay: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        // Swipe 1, recorded: the overlay window is replaced at the switch, while it is on screen.
        // Swipe 2: back, with the window replaced before it is shown.
        controller.debugWindowFault = .atSwitch
        recordScreen(frames: 21, interval: 0.03, to: "/tmp/sg-frames/sheet.png")
        after(0.1) {
            self.replaySwipe(travel: -0.45, duration: 0.18) {
                after(1.8) {
                    self.controller.debugWindowFault = .whenShown
                    self.replaySwipe(travel: 0.45, duration: 0.18) {
                        after(1.5) { self.log.notice("self test end") }
                    }
                }
            }
        }
    }

    /// Takes small pictures of the screen, overlay included, and writes them as one sheet (row by row).
    private func recordScreen(frames count: Int, interval: Double, to path: String) {
        guard #available(macOS 15.2, *), let screen = NSScreen.main else { return }
        let bounds = CGDisplayBounds(screen.displayID)
        let start = CACurrentMediaTime()
        var shots: [(time: Double, image: CGImage)] = []
        func finish() {
            let columns = 7, width = 360, height = Int(360 * bounds.height / bounds.width)
            let rows = (shots.count + columns - 1) / columns
            guard rows > 0, let context = CGContext(
                data: nil, width: columns * width, height: rows * (height + 14), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: columns * width, height: rows * (height + 14)))
            var times: [String] = []
            for (index, shot) in shots.enumerated() {
                let column = index % columns, row = index / columns
                let y = (rows - 1 - row) * (height + 14) + 7
                context.draw(shot.image, in: CGRect(x: column * width + 2, y: y, width: width - 4, height: height))
                times.append("\(index): \(Int((shot.time - start) * 1000)) ms")
            }
            if let sheet = context.makeImage() {
                let url = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:])?.write(to: url)
                try? times.joined(separator: "\n").write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            }
        }
        func next() {
            guard shots.count < count else {
                finish()
                return
            }
            let requested = CACurrentMediaTime()
            SCScreenshotManager.captureImage(in: bounds) { image, _ in
                DispatchQueue.main.async {
                    if let image { shots.append((requested, image)) }
                    let wait = max(0.001, interval - (CACurrentMediaTime() - requested))
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { next() }
                }
            }
        }
        next()
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarIcon.image()
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        evaluate()
        menu.removeAllItems()

        let enabled = NSMenuItem(title: "Enable", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.transition.isCustom ? .on : .off
        menu.addItem(enabled)

        let open = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let capture = actionItem("Capture All Spaces Again", #selector(captureSpaces))
        capture.isEnabled = controller.isEnabled
        menu.addItem(capture)

        let login = actionItem("Open at Login", #selector(toggleOpensAtLogin))
        login.state = opensAtLogin ? .on : .off
        menu.addItem(login)

        var problems: [NSMenuItem] = []
        if !hasAccessibility {
            problems.append(actionItem("Allow Accessibility Access…", #selector(openAccessibilitySettings)))
        }
        if !hasScreenRecording {
            problems.append(actionItem("Allow Screen Recording…", #selector(openScreenRecordingSettings)))
        }
        if !hasTrackpad {
            problems.append(infoItem("No trackpad found"))
        }
        if !Spaces.isAvailable {
            problems.append(infoItem("Space list is not available on this macOS version"))
        }
        if hasAccessibility, !tapInstalled {
            problems.append(infoItem("Could not start the gesture filter"))
        }
        if !problems.isEmpty {
            menu.addItem(.separator())
            problems.forEach(menu.addItem)
            if !hasAccessibility || !hasScreenRecording {
                menu.addItem(actionItem("Relaunch Interspace", #selector(relaunch)))
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Interspace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() {
        settings.transition = settings.transition.isCustom ? .system : settings.lastCustomTransition
        evaluate()
    }

    private var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("open at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func toggleOpensAtLogin() {
        setOpensAtLogin(!opensAtLogin)
    }

    @objc private func captureSpaces() {
        // After the menu has closed, so it is not in the frozen image.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.controller.captureAllSpaces(again: true)
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording access applies only after a new launch.
    @objc private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Without this the new instance sees this one, takes itself for a duplicate, and exits.
        configuration.arguments = ["--replace"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
