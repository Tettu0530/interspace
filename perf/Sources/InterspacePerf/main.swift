import AppKit
import SwiftUI
import QuartzCore
import ScreenCaptureKit
import ServiceManagement
import ApplicationServices

// InterspacePerf: measures the parts of Interspace that can be measured with nothing on screen.
//
// Rules of this tool:
// - It never posts a space switch, installs no event tap and does not start the trackpad monitor.
// - Every window it makes has alpha 0. The overlay window is also below the desktop picture.
// - It reads the screen (the same captures the app takes at each swipe) and keeps no image.
//
// Usage: InterspacePerf [--only name,name] [--out file.json]
// Names: launch, calls, spring, capture, live, images, wallpaper, overlay, link, settings

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Helpers

func now() -> Double { CACurrentMediaTime() }

func spin(_ seconds: Double) {
    let end = now() + seconds
    while now() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(min(0.005, max(end - now(), 0.0005))))
    }
}

/// Runs the main run loop until `done` is true.
func spin(until done: () -> Bool, timeout: Double = 8) {
    let end = now() + timeout
    while !done(), now() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
    }
}

struct Stats {
    let values: [Double]
    init(_ values: [Double]) { self.values = values.sorted() }
    func p(_ percent: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let k = Double(values.count - 1) * percent / 100
        let f = Int(k.rounded(.down)), c = Int(k.rounded(.up))
        return values[f] + (values[c] - values[f]) * (k - Double(f))
    }
    var json: [String: Any] {
        guard !values.isEmpty else { return ["n": 0] }
        return ["n": values.count, "min": values.first!, "p50": p(50), "p90": p(90), "p99": p(99), "max": values.last!,
                "mean": values.reduce(0, +) / Double(values.count)]
    }
    func line(_ unit: String, digits: Int = 1) -> String {
        guard !values.isEmpty else { return "no data" }
        func f(_ v: Double) -> String { String(format: "%.\(digits)f", v) }
        return "n=\(values.count)  min \(f(values.first!))  p50 \(f(p(50)))  p90 \(f(p(90)))  p99 \(f(p(99)))  max \(f(values.last!)) \(unit)"
    }
}

var results: [String: Any] = [:]

func report(_ section: String, _ name: String, _ values: [Double], unit: String = "ms", digits: Int = 1) {
    let stats = Stats(values)
    print("  \(name): \(stats.line(unit, digits: digits))")
    var entry = stats.json
    entry["unit"] = unit
    var bucket = results[section] as? [String: Any] ?? [:]
    bucket[name] = entry
    results[section] = bucket
}

func note(_ section: String, _ name: String, _ value: Any) {
    print("  \(name): \(value)")
    var bucket = results[section] as? [String: Any] ?? [:]
    bucket[name] = value
    results[section] = bucket
}

/// Milliseconds of `body`, run `count` times.
func time(_ count: Int, _ body: () -> Void) -> [Double] {
    (0..<count).map { _ in
        let start = now()
        body()
        return (now() - start) * 1000
    }
}

/// The longest time the main thread did not answer, measured from another thread.
final class StallMeter {
    private let queue = DispatchQueue(label: "perf.stall", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var longest = 0.0

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, !self.pending else { return }
            self.pending = true
            let sent = now()
            DispatchQueue.main.async {
                let latency = now() - sent
                self.queue.async {
                    self.longest = max(self.longest, latency)
                    self.pending = false
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// The longest stall since the last call, in milliseconds.
    func take() -> Double {
        queue.sync {
            let value = longest
            longest = 0
            return value * 1000
        }
    }
}

// MARK: - Invisible windows

/// Makes every window of this process invisible: alpha 0 always, and when `belowDesktop` is set, a level
/// below the desktop picture. The code of the app sets the level and the alpha itself, so this replaces
/// the two setters for the whole process.
enum WindowHider {
    static var belowDesktop = false

    static func install() {
        exchange(#selector(setter: NSWindow.alphaValue), #selector(NSWindow.perf_setAlphaValue(_:)))
        exchange(#selector(setter: NSWindow.level), #selector(NSWindow.perf_setLevel(_:)))
    }

    private static func exchange(_ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(NSWindow.self, original),
              let b = class_getInstanceMethod(NSWindow.self, replacement) else {
            print("could not make windows invisible, stopping")
            exit(3)
        }
        method_exchangeImplementations(a, b)
    }
}

extension NSWindow {
    @objc func perf_setAlphaValue(_ value: CGFloat) {
        perf_setAlphaValue(0)
    }

    @objc func perf_setLevel(_ value: Int) {
        perf_setLevel(WindowHider.belowDesktop ? Int(CGWindowLevelForKey(.desktopWindow)) - 1 : value)
    }
}

// MARK: - Set-up

let arguments = CommandLine.arguments
let only: Set<String>? = arguments.firstIndex(of: "--only").map { Set(arguments[$0 + 1].split(separator: ",").map(String.init)) }
func wants(_ name: String) -> Bool { only?.contains(name) ?? true }

let mainEntered = Date()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let appReady = Date()
WindowHider.install()

guard let screen = NSScreen.main else {
    print("no screen")
    exit(1)
}
let scale = screen.backingScaleFactor
let appDefaults = UserDefaults(suiteName: "com.cnrad.interspace")
let userSpeed = { () -> Double in
    let stored = appDefaults?.double(forKey: "speed") ?? 0
    return stored > 0 ? stored : 1
}()
let userDockMoves = (appDefaults?.object(forKey: "dockMovesWithSpace") as? Bool) ?? true
let userStyle = TransitionStyle(rawValue: appDefaults?.string(forKey: "transition") ?? "") ?? .lightweight

print("InterspacePerf  \(Date())")
print("screen \(Int(screen.frame.width))x\(Int(screen.frame.height)) @\(scale)x, \(screen.maximumFramesPerSecond) Hz, \(screen.colorSpace?.localizedName ?? "?")")
print("settings of the app: transition \(userStyle.rawValue), speed \(String(format: "%.2f", userSpeed)), Dock moves with space \(userDockMoves)")
print("screen recording access: \(CGPreflightScreenCaptureAccess())\n")
results["machine"] = [
    "screen": "\(Int(screen.frame.width))x\(Int(screen.frame.height))@\(scale)x", "hz": screen.maximumFramesPerSecond,
    "os": ProcessInfo.processInfo.operatingSystemVersionString, "speed": userSpeed, "dockMovesWithSpace": userDockMoves,
    "transition": userStyle.rawValue,
]

func processStart(_ pid: pid_t) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let start = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
}

var sharedOverlay: Overlay?
let stall = StallMeter()
stall.start()
let snapshotter = Snapshotter()

// MARK: - Launch

if wants("launch") {
    print("== Launch (this tool links the same frameworks as the app) ==")
    if let started = processStart(getpid()) {
        note("launch", "exec to main() ms", Int(mainEntered.timeIntervalSince(started) * 1000))
        note("launch", "exec to NSApplication ready ms", Int(appReady.timeIntervalSince(started) * 1000))
    }
    // The start time of the running app, to compare with its first log line.
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.cnrad.interspace") {
        if let started = processStart(app.processIdentifier) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            note("launch", "running app pid \(app.processIdentifier) started", formatter.string(from: started))
        }
    }
    let icon = time(20) { _ = MenuBarIcon.image() }
    report("launch", "menu bar icon image", icon, digits: 3)
    print()
}

// MARK: - Calls the app makes on the main thread

if wants("calls") {
    print("== Calls on the main thread ==")
    report("calls", "Spaces.layout (each display frame of the snap, until the hand-off)", time(3000) { _ = Spaces.layout(for: screen) }, unit: "ms", digits: 3)
    report("calls", "NSScreen.underCursor + Spaces.layout (touch down)", time(500) { _ = NSScreen.underCursor.flatMap { Spaces.layout(for: $0) } }, digits: 3)
    report("calls", "read of the scroll direction setting (each touch frame)", time(3000) {
        _ = (UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool) ?? true
    }, digits: 4)
    report("calls", "AXIsProcessTrusted (every 2 s)", time(300) { _ = AXIsProcessTrusted() }, digits: 3)
    report("calls", "CGPreflightScreenCaptureAccess (every 2 s)", time(300) { _ = CGPreflightScreenCaptureAccess() }, digits: 3)
    let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")
    report("calls", "read of the keyboard shortcuts (every 2 s)", time(300) { _ = hotkeys?.dictionary(forKey: "AppleSymbolicHotKeys") }, digits: 3)
    report("calls", "SMAppService status (each menu open; this tool is not the app, so only a guide)", time(30) { _ = SMAppService.mainApp.status }, digits: 3)
    report("calls", "Dock process lookup (each capture below the Dock)", time(100) {
        _ = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }, digits: 3)
    var windowCount = 0
    report("calls", "CGWindowListCopyWindowInfo (each capture below the Dock, off the main thread)", time(100) {
        windowCount = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]])?.count ?? 0
    }, digits: 3)
    note("calls", "windows on screen now", windowCount)
    print()
}

// MARK: - Spring

if wants("spring") {
    print("== The snap spring, simulated at \(screen.maximumFramesPerSecond) Hz (milliseconds after release) ==")
    let hz = Double(screen.maximumFramesPerSecond)
    var table: [[String: Any]] = []
    for speed in [0.5, userSpeed, 1.0, 2.0] {
        for (start, velocity) in [(0.85, -2.5), (0.5, -2.0), (0.25, 0.0)] {
            var progress = CGFloat(start), v = CGFloat(velocity)
            var t = 0.0
            var marks: [String: Double] = [:]
            while t < 3 {
                TransitionMath.stepSpring(progress: &progress, velocity: &v, delta: CGFloat(1 / hz), speed: CGFloat(speed), limit: 2)
                t += 1 / hz
                if marks["within 2%"] == nil, abs(progress) < 0.02 { marks["within 2%"] = t * 1000 }
                if marks["within 5 points"] == nil, abs(progress) * screen.frame.width < 5 { marks["within 5 points"] = t * 1000 }
                if marks["fade may start"] == nil, abs(progress) < Config.revealStartDistance { marks["fade may start"] = t * 1000 }
                if TransitionMath.isSettled(progress: progress, velocity: v) {
                    marks["settled"] = t * 1000
                    break
                }
            }
            func m(_ key: String) -> String { marks[key].map { String(format: "%3.0f", $0) } ?? "  -" }
            print(String(format: "  speed %.2f  from %.2f  velocity %+.1f:  within 2%% %@   within 5 pt %@   fade may start %@   settled %@   +%.0f ms fade",
                         speed, start, velocity, m("within 2%"), m("within 5 points"), m("fade may start"), m("settled"), Double(Config.revealDuration) * 1000))
            table.append(["speed": speed, "from": start, "velocity": velocity, "marks": marks])
        }
    }
    results["spring"] = table
    print()
}

// MARK: - Captures

/// A 1 x 1 window with alpha 0 above everything, so "everything below this window" is the whole screen.
func makeProbe() -> NSPanel {
    let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    panel.ignoresMouseEvents = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.alphaValue = 0
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.orderFrontRegardless()
    return panel
}

/// One capture through the code of the app. Returns the image, the milliseconds to the callback, and the
/// longest stall of the main thread during that time.
func capture(includeDock: Bool) -> (snapshot: Snapshot?, ms: Double, stall: Double) {
    var done = false
    var result: Snapshot?
    var finished = 0.0
    _ = stall.take()
    let start = now()
    snapshotter.capture(screen: screen, includeDock: includeDock) { snapshot in
        finished = now()
        result = snapshot
        done = true
    }
    spin(until: { done })
    return (result, (finished - start) * 1000, stall.take())
}

func describe(_ image: CGImage) -> String {
    let name = (image.colorSpace?.name as String?) ?? image.colorSpace.map { "unnamed: \(String(describing: $0).prefix(160))" } ?? "none"
    return "\(image.width)x\(image.height), \(image.bitsPerComponent) bits per channel, \(image.bitsPerPixel) per pixel, alpha \(image.alphaInfo.rawValue), colour space \(name)"
}

var keptFull: Snapshot?
var keptBelowDock: Snapshot?

if wants("capture") {
    print("== Captures (the screen as it is now; nothing is shown) ==")
    guard CGPreflightScreenCaptureAccess() else {
        print("  no screen recording access for this terminal, skipped\n")
        exit(1)
    }

    // The list of displays and windows. The app loads it one time at launch.
    var refreshTimes: [Double] = []
    for _ in 0..<8 {
        var done = false
        let start = now()
        var finished = 0.0
        snapshotter.refreshDisplays {
            finished = now()
            done = true
        }
        spin(until: { done })
        refreshTimes.append((finished - start) * 1000)
        spin(0.05)
    }
    note("capture", "list of displays and windows, first call ms", Int(refreshTimes[0]))
    report("capture", "list of displays and windows, later calls", Array(refreshTimes.dropFirst()))

    for (label, includeDock) in [("with the Dock (ScreenCaptureKit)", true), ("below the Dock (CGWindowListCreateImage)", false)] {
        var times: [Double] = [], stalls: [Double] = []
        var first = 0.0
        for index in 0..<40 {
            let shot = capture(includeDock: includeDock)
            guard let snapshot = shot.snapshot else {
                note("capture", "\(label): FAILED at try \(index)", true)
                break
            }
            if index == 0 {
                first = shot.ms
                note("capture", "\(label): image", describe(snapshot.image))
                note("capture", "\(label): includesDock", snapshot.includesDock)
                if let patch = snapshot.patch {
                    note("capture", "\(label): island piece", "\(patch.width)x\(patch.height) at \(snapshot.patchFrame)")
                }
            } else {
                times.append(shot.ms)
                stalls.append(shot.stall)
            }
            if includeDock { keptFull = snapshot } else { keptBelowDock = snapshot }
            spin(0.12)
        }
        note("capture", "\(label): first capture ms", Int(first))
        report("capture", "\(label): touch down to image", times)
        report("capture", "\(label): longest main thread stall during it", stalls)
    }

    // Two captures at the same moment, as a touch down next to the refresh after a switch would be.
    var shared: [Double] = []
    for _ in 0..<10 {
        var count = 0
        let start = now()
        var finished = 0.0
        for _ in 0..<2 {
            snapshotter.capture(screen: screen, includeDock: userDockMoves) { _ in
                count += 1
                finished = now()
            }
        }
        spin(until: { count == 2 })
        shared.append((finished - start) * 1000)
        spin(0.1)
    }
    report("capture", "two requests at the same time (they share one capture)", shared)

    let probe = makeProbe()
    spin(0.2)
    var refreshed = false
    snapshotter.refreshDisplays { refreshed = true }
    spin(until: { refreshed })

    // The capture used during the visit of all spaces when the Dock moves with the space.
    var belowTotal: [Double] = [], belowBlocked: [Double] = []
    for _ in 0..<15 {
        var done = false
        let start = now()
        var finished = 0.0
        snapshotter.captureBelow(windowNumber: probe.windowNumber, screen: screen) { _ in
            finished = now()
            done = true
        }
        belowBlocked.append((now() - start) * 1000)
        spin(until: { done })
        belowTotal.append((finished - start) * 1000)
        spin(0.12)
    }
    report("capture", "below the cover (visit of all spaces): total", belowTotal)
    report("capture", "below the cover: main thread blocked inside the call", belowBlocked)
    probe.orderOut(nil)
    print()
}

// MARK: - The look at the live desktop before the hand-off

if wants("live") {
    print("== The check of the live desktop before the hand-off ==")
    let probe = makeProbe()
    spin(0.2)

    func sample() -> (pixels: [UInt8]?, ms: Double) {
        var done = false
        var result: [UInt8]?
        let start = now()
        var finished = 0.0
        snapshotter.sampleBelow(windowNumber: probe.windowNumber, screen: screen) { pixels in
            finished = now()
            result = pixels
            done = true
        }
        spin(until: { done })
        return (result, (finished - start) * 1000)
    }

    var sampleTimes: [Double] = []
    var failed = 0
    for _ in 0..<60 {
        let one = sample()
        if one.pixels == nil { failed += 1 }
        sampleTimes.append(one.ms)
        spin(0.03)
    }
    report("live", "one small sample of the screen", sampleTimes)
    note("live", "samples that failed", failed)

    // The loop of the app: sample, wait 10 ms, sample, until two in a row are the same or 0.6 s have passed.
    var waits: [Double] = [], looks: [Double] = []
    var timedOut = 0
    for _ in 0..<40 {
        let start = now()
        var previous: [UInt8]?
        var count = 0
        while true {
            let one = sample()
            count += 1
            guard let pixels = one.pixels else { break }
            if let previous, Snapshotter.samplesMatch(previous, pixels) { break }
            if now() - start > Config.revealMaxWait {
                timedOut += 1
                break
            }
            previous = pixels
            spin(0.01)
        }
        waits.append((now() - start) * 1000)
        looks.append(Double(count))
        spin(0.25)
    }
    report("live", "time until the desktop counts as still (your desktop, now)", waits)
    report("live", "samples needed", looks, unit: "samples", digits: 0)
    note("live", "gave up after \(Int(Config.revealMaxWait * 1000)) ms", "\(timedOut) of 40")
    probe.orderOut(nil)
    print()
}

// MARK: - What is in the images

/// Draws a part of an image into 8-bit sRGB, so two images with different colour spaces can be compared
/// as they would look on screen. `rect` is in fractions of the image, from the top left.
func pixels(of image: CGImage, rect: CGRect, width: Int, height: Int) -> [UInt8]? {
    let crop = CGRect(
        x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
        width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)
    ).integral
    guard let part = image.cropping(to: crop), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(
            data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        context.interpolationQuality = .medium
        context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? buffer : nil
}

/// Mean difference of two pixel buffers, absolute and with its sign, on the 0...255 scale.
func difference(_ a: [UInt8], _ b: [UInt8]) -> (absolute: Double, signed: Double) {
    var absolute = 0, signed = 0, count = 0
    var index = 0
    while index < min(a.count, b.count) {
        if index % 4 != 3 {
            let d = Int(a[index]) - Int(b[index])
            absolute += abs(d)
            signed += d
            count += 1
        }
        index += 1
    }
    return (Double(absolute) / Double(max(count, 1)), Double(signed) / Double(max(count, 1)))
}

/// A capture with the cursor certainly left out, to compare with.
func captureWithoutCursor() -> CGImage? {
    var content: SCShareableContent?
    var done = false
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { value, _ in
        DispatchQueue.main.async {
            content = value
            done = true
        }
    }
    spin(until: { done })
    guard let display = content?.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
    let configuration = SCStreamConfiguration()
    configuration.width = Int((CGFloat(display.width) * scale).rounded())
    configuration.height = Int((CGFloat(display.height) * scale).rounded())
    configuration.showsCursor = false
    configuration.captureResolution = .best
    configuration.colorSpaceName = CGColorSpace.displayP3
    var image: CGImage?
    done = false
    SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration) { value, _ in
        DispatchQueue.main.async {
            image = value
            done = true
        }
    }
    spin(until: { done })
    return image
}

if wants("images") {
    print("== What is in the images ==")
    let expected = "\(Int(screen.frame.width * scale))x\(Int(screen.frame.height * scale))"
    note("images", "pixels of the display", expected)

    // The same moment through the two capture paths of the app, and through a third with no cursor.
    // The middle of the screen only: the Dock and the menu bar are not in one of the two.
    let middle = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.55)
    var pathDifference: [Double] = [], pathSigned: [Double] = [], brightness: [Double] = [], contrast: [Double] = []
    var cursorFull: [Double] = [], cursorBelow: [Double] = [], control: [Double] = []
    for _ in 0..<6 {
        var full: Snapshot?, below: Snapshot?
        var count = 0
        let mouse = NSEvent.mouseLocation
        // Two snapshotters, so the two captures run at the same time and do not share a result.
        let second = Snapshotter()
        snapshotter.capture(screen: screen, includeDock: true) { full = $0; count += 1 }
        second.capture(screen: screen, includeDock: false) { below = $0; count += 1 }
        spin(until: { count == 2 })
        let clean = captureWithoutCursor()
        guard let full, let below, let clean else { continue }

        if let a = pixels(of: full.image, rect: middle, width: 256, height: 160),
           let b = pixels(of: below.image, rect: middle, width: 256, height: 160) {
            let d = difference(a, b)
            // Proof that the comparison sees a real picture: its mean level and how much it varies.
            let levels = a.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }
            let mean = levels.reduce(0, +) / Double(levels.count)
            let spread = (levels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(levels.count)).squareRoot()
            brightness.append(mean)
            contrast.append(spread)
            pathDifference.append(d.absolute)
            pathSigned.append(d.signed)
        }

        // A small box at the pointer, and the same box moved away as a control.
        let x = (mouse.x - screen.frame.minX) / screen.frame.width
        let y = (screen.frame.maxY - mouse.y) / screen.frame.height
        let box = CGRect(x: x - 4 / screen.frame.width, y: y - 4 / screen.frame.height, width: 28 / screen.frame.width, height: 28 / screen.frame.height)
        let away = box.offsetBy(dx: box.minX > 0.5 ? -0.1 : 0.1, dy: 0)
        func compare(_ image: CGImage, _ rect: CGRect) -> Double? {
            guard let a = pixels(of: image, rect: rect, width: 56, height: 56), let b = pixels(of: clean, rect: rect, width: 56, height: 56) else { return nil }
            return difference(a, b).absolute
        }
        if box.minX >= 0, box.minY >= 0, box.maxX <= 1, box.maxY <= 1 {
            if let d = compare(full.image, box) { cursorFull.append(d) }
            if let d = compare(below.image, box) { cursorBelow.append(d) }
            if let d = compare(full.image, away) { control.append(d) }
        }
        keptFull = full
        keptBelowDock = below
        spin(0.4)
    }
    if let image = keptFull?.image { note("images", "with the Dock", describe(image)) }
    if let image = keptBelowDock?.image { note("images", "below the Dock", describe(image)) }
    report("images", "mean level of the compared area (proof that it is a real picture)", brightness, unit: "levels", digits: 1)
    report("images", "spread of levels in it", contrast, unit: "levels", digits: 1)
    report("images", "difference between the two capture paths, middle of the screen (0 = same, 255 = opposite)", pathDifference, unit: "levels", digits: 2)
    report("images", "the same, with sign (a constant value is a colour or brightness shift)", pathSigned, unit: "levels", digits: 2)
    report("images", "at the pointer: image with the Dock against a capture with no cursor", cursorFull, unit: "levels", digits: 2)
    report("images", "at the pointer: image below the Dock against a capture with no cursor", cursorBelow, unit: "levels", digits: 2)
    report("images", "control box away from the pointer", control, unit: "levels", digits: 2)
    print()
}

// MARK: - Wallpaper

var keptWallpaper: Snapshot?

if wants("wallpaper") {
    print("== The desktop picture, shown for a space with no image yet (made on the main thread, in the first swipe) ==")
    if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
        note("wallpaper", "file type", url.pathExtension)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            note("wallpaper", "file pixels", "\(properties[kCGImagePropertyPixelWidth] ?? "?")x\(properties[kCGImagePropertyPixelHeight] ?? "?")")
        }
    }
    var times: [Double] = []
    for _ in 0..<5 {
        let start = now()
        keptWallpaper = snapshotter.wallpaper(for: screen)
        times.append((now() - start) * 1000)
    }
    // The same picture made off the main thread, as the app now does at launch and at a display change.
    var asyncTimes: [Double] = [], asyncStalls: [Double] = []
    for _ in 0..<5 {
        var done = false
        // Let the meter finish with the blocking calls above before this one is measured.
        spin(0.1)
        _ = stall.take()
        let start = now()
        var finished = 0.0
        snapshotter.wallpaper(for: screen) { snapshot in
            finished = now()
            keptWallpaper = snapshot ?? keptWallpaper
            done = true
        }
        spin(until: { done })
        asyncTimes.append((finished - start) * 1000)
        asyncStalls.append(stall.take())
    }
    report("wallpaper", "off the main thread: time until it is ready", asyncTimes)
    report("wallpaper", "off the main thread: longest main thread stall during it", asyncStalls)
    note("wallpaper", "made", keptWallpaper != nil)
    report("wallpaper", "time on the main thread", times)
    print()
}

// MARK: - Overlay

/// Proves on a 1 x 1 window that the window server sees our windows with alpha 0 and below the desktop
/// picture, before a window of the size of the screen is made. Stops the tool if not.
func checkWindowsAreInvisible() {
    WindowHider.belowDesktop = true
    let test = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    test.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    test.ignoresMouseEvents = true
    test.alphaValue = 1
    test.orderFrontRegardless()
    spin(0.15)
    let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(test.windowNumber)) as? [[String: Any]])?.first
    let alpha = (info?[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1
    let layer = (info?[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    test.orderOut(nil)
    WindowHider.belowDesktop = false
    let wanted = Int(CGWindowLevelForKey(.desktopWindow)) - 1
    print("  check: a test window has alpha \(alpha) and level \(layer) (wanted: 0 and \(wanted))")
    guard alpha == 0, layer == wanted else {
        print("  the windows of this tool would be visible, stopping")
        exit(4)
    }
}

if wants("overlay") || wants("link") {
    if keptFull == nil { keptFull = capture(includeDock: true).snapshot }
    if keptBelowDock == nil { keptBelowDock = capture(includeDock: false).snapshot }
    if keptWallpaper == nil { keptWallpaper = snapshotter.wallpaper(for: screen) }
}

/// Another image of the same kind with its own memory, as the image of another space would be.
func another(_ kind: Bool) -> Snapshot? {
    spin(0.05)
    return capture(includeDock: kind).snapshot
}

if wants("overlay") || wants("link") { checkWindowsAreInvisible() }

if wants("overlay") {
    print("== The overlay window (alpha 0 and below the desktop picture: the work of this process is real, the work of the window server is not measured) ==")
    WindowHider.belowDesktop = true

    for (label, kind) in [("images with the Dock (ScreenCaptureKit)", true), ("images below the Dock (CGWindowListCreateImage)", false)] {
        guard let centre = kind ? keptFull : keptBelowDock else { continue }
        var presents: [Double] = [], stalls: [Double] = [], hides: [Double] = [], swaps: [Double] = []
        var firstPresent = 0.0
        for round in 0..<12 {
            // New images each time: the first time an image goes to the window server is the expensive one.
            guard let left = another(kind), let right = another(kind), let current = another(kind) else { continue }
            let overlay = round == 0 ? Overlay() : sharedOverlay ?? Overlay()
            sharedOverlay = overlay
            overlay.isBelowDock = !kind
            overlay.style = userStyle.isDrawn ? userStyle : .lightweight
            overlay.roundsCorners = true
            spin(0.1)
            _ = stall.take()
            let start = now()
            CATransaction.begin()
            overlay.attach(to: screen)
            overlay.setCards { offset in
                switch offset {
                case 0: return .snapshot(current)
                case -1: return .snapshot(left)
                case 1: return .snapshot(right)
                default: return .none
                }
            }
            overlay.render(progress: 0)
            CATransaction.commit()
            overlay.present()
            let presented = (now() - start) * 1000
            if round == 0 { firstPresent = presented } else { presents.append(presented) }
            // The frames that follow: any late work of the commit shows as a stall here.
            spin(0.1)
            if round > 0 { stalls.append(stall.take()) }

            // A commit to the next space: three screens get other images in one transaction.
            let swapStart = now()
            CATransaction.begin()
            overlay.setCards { offset in
                switch offset {
                case 0: return .snapshot(right)
                case -1: return .snapshot(current)
                case 1: return .snapshot(centre)
                default: return .none
                }
            }
            overlay.render(progress: -0.8)
            CATransaction.commit()
            CATransaction.flush()
            swaps.append((now() - swapStart) * 1000)
            spin(0.05)

            let hideStart = now()
            overlay.hide()
            hides.append((now() - hideStart) * 1000)
        }
        note("overlay", "\(label): first show of the window ms", String(format: "%.1f", firstPresent))
        report("overlay", "\(label): show (size, 3 images, first frame, order front)", presents, digits: 2)
        report("overlay", "\(label): longest main thread stall in the 100 ms after", stalls, digits: 2)
        report("overlay", "\(label): move to the next space (3 new images in one frame)", swaps, digits: 2)
        report("overlay", "\(label): hide", hides, digits: 2)
    }

    // One frame of each transition: set every layer, then send it to the window server.
    if let overlay = sharedOverlay, let a = keptFull, let b = keptBelowDock ?? keptFull {
        for style in [TransitionStyle.lightweight, .hexagon] {
            overlay.style = style
            CATransaction.begin()
            overlay.attach(to: screen)
            overlay.setCards { offset in abs(offset) <= 1 ? .snapshot(offset == 0 ? a : b) : .none }
            overlay.render(progress: 0)
            CATransaction.commit()
            overlay.present()
            spin(0.1)
            var frames: [Double] = []
            for index in 0..<1200 {
                let progress = CGFloat(sin(Double(index) / 60)) * 0.95
                let start = now()
                overlay.render(progress: progress)
                CATransaction.flush()
                frames.append((now() - start) * 1000)
            }
            report("overlay", "one frame, \(style.title) (budget at \(screen.maximumFramesPerSecond) Hz: \(String(format: "%.1f", 1000 / Double(screen.maximumFramesPerSecond))) ms)", frames, digits: 3)
            overlay.hide()
        }
    }
    WindowHider.belowDesktop = false
    print()
}

// MARK: - Display link

/// The same work as one `tick` of the app during the snap: the spring, the layers, and one read of the
/// space list (the app asks the window server each frame if the Dock has landed).
final class LinkRun: NSObject {
    struct Tick {
        let interval: Double
        let late: Double
        let work: Double
    }

    private let overlay: Overlay
    private let screen: NSScreen
    private var link: CADisplayLink?
    private var progress: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastTick = 0.0
    private var added = 0.0
    private(set) var firstTickDelay = 0.0
    private(set) var nominal = 0.0
    private(set) var ticks: [Tick] = []
    private(set) var finished = false
    private let readsSpaces: Bool

    init(overlay: Overlay, screen: NSScreen, readsSpaces: Bool) {
        self.overlay = overlay
        self.screen = screen
        self.readsSpaces = readsSpaces
    }

    func start(from: CGFloat, velocity: CGFloat) {
        progress = from
        self.velocity = velocity
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        added = now()
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let entered = now()
        let stamp = link.timestamp
        nominal = link.duration
        if lastTick == 0 { firstTickDelay = entered - added }
        let delta = lastTick == 0 ? link.duration : min(stamp - lastTick, 1.0 / 30)
        let interval = lastTick == 0 ? 0 : stamp - lastTick
        lastTick = stamp

        TransitionMath.stepSpring(progress: &progress, velocity: &velocity, delta: CGFloat(delta), speed: CGFloat(userSpeed), limit: 2)
        overlay.render(progress: progress)
        if readsSpaces { _ = Spaces.layout(for: screen) }
        if TransitionMath.isSettled(progress: progress, velocity: velocity) {
            link.invalidate()
            self.link = nil
            finished = true
        }
        ticks.append(Tick(interval: interval, late: entered - stamp, work: now() - entered))
    }
}

if wants("link") {
    print("== The display link during a snap (the timing of this process under your load now; nothing is shown) ==")
    WindowHider.belowDesktop = true
    let overlay = sharedOverlay ?? Overlay()
    sharedOverlay = overlay
    if let a = keptFull, let b = keptBelowDock ?? keptFull {
        for (label, readsSpaces) in [("as the app does it", true), ("with no read of the space list", false)] {
            var intervals: [Double] = [], late: [Double] = [], work: [Double] = [], first: [Double] = [], lengths: [Double] = []
            var long = 0, total = 0
            var nominal = 0.0
            for run in 0..<40 {
                overlay.style = userStyle.isDrawn ? userStyle : .lightweight
                CATransaction.begin()
                overlay.attach(to: screen)
                overlay.setCards { offset in abs(offset) <= 1 ? .snapshot(offset == 0 ? a : b) : .none }
                overlay.render(progress: 0.85)
                CATransaction.commit()
                overlay.present()
                let driver = LinkRun(overlay: overlay, screen: screen, readsSpaces: readsSpaces)
                driver.start(from: run % 2 == 0 ? 0.85 : -0.85, velocity: run % 2 == 0 ? -2.5 : 2.5)
                spin(until: { driver.finished }, timeout: 3)
                overlay.hide()
                nominal = driver.nominal
                first.append(driver.firstTickDelay * 1000)
                lengths.append(Double(driver.ticks.count))
                for tick in driver.ticks.dropFirst() {
                    intervals.append(tick.interval * 1000)
                    total += 1
                    if tick.interval > driver.nominal * 1.5 { long += 1 }
                }
                for tick in driver.ticks {
                    late.append(tick.late * 1000)
                    work.append(tick.work * 1000)
                }
                spin(0.12)
            }
            note("link", "\(label): frame time of the display ms", String(format: "%.2f", nominal * 1000))
            report("link", "\(label): frames in one snap", lengths, unit: "frames", digits: 0)
            report("link", "\(label): time between two frames", intervals, digits: 2)
            note("link", "\(label): frames that came late by half a frame or more", "\(long) of \(total)")
            report("link", "\(label): start of the callback after its frame time", late, digits: 2)
            report("link", "\(label): work in the callback", work, digits: 3)
            report("link", "\(label): release to the first frame of the snap", first, digits: 2)
        }
    }
    WindowHider.belowDesktop = false
    print()
}

// MARK: - Settings window

if wants("settings") {
    print("== The settings window (built and drawn off screen; it is built new at each open) ==")
    var builds: [Double] = [], draws: [Double] = []
    var firstBuild = 0.0
    var size = CGSize.zero
    for round in 0..<8 {
        let start = now()
        let host = NSHostingView(rootView: SettingsView(settings: .shared))
        let frame = CGRect(origin: .zero, size: host.fittingSize)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        let built = (now() - start) * 1000
        size = host.fittingSize
        if round == 0 { firstBuild = built } else { builds.append(built) }
        let drawStart = now()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        draws.append((now() - drawStart) * 1000)
        window.contentView = nil
        spin(0.05)
    }
    note("settings", "size", "\(Int(size.width))x\(Int(size.height))")
    note("settings", "first build ms (menu click to a window that can be shown)", String(format: "%.1f", firstBuild))
    report("settings", "later builds", builds)
    report("settings", "first draw of the content", draws)

    // The four previews animate all the time the window is open. One frame of all four, drawn to a bitmap.
    final class Clock: ObservableObject {
        @Published var value = 0.0
    }
    struct Previews: View {
        @ObservedObject var clock: Clock
        var body: some View {
            VStack(spacing: 4) {
                ForEach(TransitionStyle.allCases) { style in
                    // A new speed value each frame, so the canvas draws again.
                    TransitionPreview(style: style, speed: 1 + clock.value * 1e-9)
                }
            }
        }
    }
    let clock = Clock()
    let host = NSHostingView(rootView: Previews(clock: clock))
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    var frames: [Double] = []
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        for index in 0..<240 {
            TransitionPreview.fixedTime = Double(index) / 120
            let start = now()
            clock.value = Double(index)
            host.layoutSubtreeIfNeeded()
            host.cacheDisplay(in: host.bounds, to: bitmap)
            frames.append((now() - start) * 1000)
        }
    }
    report("settings", "one frame of the four previews (drawn to a bitmap: a guide, not the real path)", frames, digits: 3)
    print()
}

// MARK: - Output

if let flag = arguments.firstIndex(of: "--out"), arguments.count > flag + 1,
   let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: URL(fileURLWithPath: arguments[flag + 1]))
    print("wrote \(arguments[flag + 1])")
}
exit(0)
