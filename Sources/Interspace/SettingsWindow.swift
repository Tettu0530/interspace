import AppKit
import SwiftUI

// MARK: - Window

/// Opens the settings window. The window is made new each time, so its previews run only while it is open.
///
/// The window has no title bar. It is a rounded panel that shows a blur of what is behind it, with a tint
/// on top. A Close button is along the bottom, and the band around the divider line moves the window.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let cornerRadius: CGFloat = 22

    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: SettingsView(settings: .shared) { [weak self] in
                self?.window?.close()
            })
            let frame = CGRect(origin: .zero, size: host.fittingSize)

            let window = SettingsWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            // Only two empty areas move the window. See `SettingsWindow.sendEvent`.
            window.isMovableByWindowBackground = false
            window.isReleasedWhenClosed = false
            window.delegate = self

            // The blur of what is behind the window. The tint and the edge are part of the SwiftUI content.
            let blur = NSVisualEffectView(frame: frame)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            // Stay blurred when another app is in front.
            blur.state = .active
            blur.autoresizingMask = [.width, .height]

            host.frame = frame
            host.autoresizingMask = [.width, .height]

            let container = NSView(frame: frame)
            container.wantsLayer = true
            container.layer?.cornerRadius = Self.cornerRadius
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
            container.addSubview(blur)
            container.addSubview(host)

            window.contentView = container
            // Some controls measure larger before they are in a window, so the first size can be too tall.
            // Measure again now. The blur and the content follow the window.
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            window.center()
            self.window = window
        }
        // The app has no Dock icon and is not in the app switcher. While this window is open it is a regular
        // app, so Command-Tab can find the window again when it is behind other windows.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.invalidateShadow()
    }

    func windowWillClose(_ notification: Notification) {
        // Not during the close itself: the window is still in use there.
        DispatchQueue.main.async { [weak self] in
            self?.window = nil
            // Back to a menu bar app, with no Dock icon.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private final class SettingsWindow: NSWindow {
    // A window with no title bar does not take the keyboard unless it says so.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The app has no menu bar, so Command-W has no menu item to go through.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Escape.
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// The window has no title bar. It moves by the band around the line between the list and the
    /// controls, and by the thin strip above the list. The drag starts here, before the content gets the click.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, isInDragBar(event.locationInWindow) {
            // A click on a window that is behind others also brings it to the front.
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    /// The views that mark an empty area of the content as a place to hold the window. See `WindowDragRegion`.
    let dragRegions = NSHashTable<NSView>.weakObjects()

    private func isInDragBar(_ point: CGPoint) -> Bool {
        // The thin strip above the list. The origin of a window is at the bottom left.
        let fromTop = frame.height - point.y
        if fromTop >= 0, fromTop <= SettingsLayout.padding { return true }
        // The marked areas, wherever the layout has put them.
        return dragRegions.allObjects.contains { $0.window === self && $0.convert($0.bounds, to: nil).contains(point) }
    }
}

/// Marks the area behind it as a place to hold and move the window. It draws nothing.
private struct WindowDragRegion: NSViewRepresentable {
    final class RegionView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? SettingsWindow)?.dragRegions.add(self)
        }
    }

    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) {}
}

/// Sizes that the content and the window must agree on.
enum SettingsLayout {
    /// Space between the edge of the window and the content.
    static let padding: CGFloat = 10
    /// The corner radius of a row in the list. The rows are `padding` inside the window on the top and on
    /// the sides, so this makes their corners concentric with the corners of the window.
    static let rowRadius = SettingsWindowController.cornerRadius - padding
    static let closeButtonHeight: CGFloat = 40
    /// Space left and right of the text and the controls, inside the padding.
    static let inset: CGFloat = 16
}

/// Dark and slightly blue in dark mode, white in light mode. See-through, so the blur shows.
private let panelTint = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 0.62)
        : NSColor(white: 1, alpha: 0.5)
}

// MARK: - Content

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                ForEach(TransitionStyle.allCases) { style in
                    TransitionRow(
                        style: style,
                        speed: settings.speed,
                        sensitivity: settings.sensitivity,
                        dockMovesWithSpace: settings.dockMovesWithSpace,
                        isSelected: settings.transition == style
                    ) {
                        settings.transition = style
                    }
                }
            }

            // A faint line between the list and the controls, as long as the text and the previews.
            // The band around it is empty, so it is a place to hold the window and move it.
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)
                .padding(.horizontal, SettingsLayout.inset)
                .padding(.vertical, 16)
                .background(WindowDragRegion())

            // What applies to every transition the app draws. macOS draws its own, and Instant draws nothing.
            VStack(spacing: 12) {
                SliderRow(title: "Speed", value: $settings.speed, range: AppSettings.speedRange)
                // How far the screens move for the same finger travel. High enough, one swipe passes several spaces.
                SliderRow(title: "Swipe sensitivity", value: $settings.sensitivity, range: AppSettings.sensitivityRange)
                SwitchRow(title: "Dock and menu bar move with the space", isOn: $settings.dockMovesWithSpace)
                SwitchRow(title: "Rounded corners", isOn: $settings.roundedCorners)
            }
            .disabled(!settings.transition.isDrawn)
            // In line with the names in the list on the left, and with the previews on the right.
            .padding(.horizontal, SettingsLayout.inset)
            .padding(.bottom, 18)

            // As wide as the rows and the same distance from the edges, so its corners are concentric
            // with the corners of the window too. Escape and Command-W do the same.
            CloseBar(action: close)
        }
        .padding(SettingsLayout.padding)
        .frame(width: 540)
        // The tint and the edge always fill the window, also if the window is not exactly as tall as the content.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: panelTint))
        .overlay(
            // A thin light edge, so the shape of the panel reads on any background.
            RoundedRectangle(cornerRadius: SettingsWindowController.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }
}

/// The button along the bottom of the window. Quiet: a thin edge at rest, a fill under the pointer.
private struct CloseBar: View {
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button("Close", action: action)
            .buttonStyle(Style(isHovered: hover.isHovered))
            .onHover { hover.isHovered = $0 }
    }

    private struct Style: ButtonStyle {
        let isHovered: Bool

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: SettingsLayout.rowRadius, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: SettingsLayout.closeButtonHeight)
                .background(
                    shape
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.11 : (isHovered ? 0.06 : 0)))
                        // The fill is there at once and fades when the pointer leaves.
                        .animation(isHovered ? nil : .easeOut(duration: 0.15), value: isHovered)
                )
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .contentShape(shape)
        }
    }
}

/// A setting with a range: the name, a slider, and the value as a multiple of normal.
/// The slider moves in equal steps of "twice as much", so each doubling takes the same distance on it.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Environment(\.isEnabled) private var isEnabled

    /// The names have one width, so the sliders of two rows start and end on the same lines.
    static let titleWidth: CGFloat = 112

    private var exponent: Binding<Double> {
        Binding(
            get: { log2(value) },
            set: { newValue in
                // A small catch at normal, which is hard to find by hand.
                let snapped = abs(newValue) < 0.05 ? 0 : newValue
                value = min(max(pow(2, snapped), range.lowerBound), range.upperBound)
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: Self.titleWidth, alignment: .leading)
            GlassSlider(value: exponent, range: log2(range.lowerBound)...log2(range.upperBound))
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.1f times", value))
            Text(String(format: "%.1f×", value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A setting that is on or off: the name on the left, a switch on the right, in line with the previews.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Slider

/// A slider with a Liquid Glass thumb. The thumb gets larger while it is held, and the track shows through it.
private struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var press = PressState()

    private static let thumbSize = CGSize(width: 26, height: 16)
    private static let trackHeight: CGFloat = 4
    private static let height: CGFloat = 22

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geometry in
            // The thumb stays inside the track, so its centre moves over this distance.
            let travel = max(geometry.size.width - Self.thumbSize.width, 1)
            let thumbX = travel * min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: thumbX + Self.thumbSize.width / 2, height: Self.trackHeight)
                thumb
                    .scaleEffect(press.isPressed ? 1.3 : 1)
                    // Larger at once under the pointer, and back with a small bounce when it lets go.
                    .animation(
                        press.isPressed ? .easeOut(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.6),
                        value: press.isPressed
                    )
                    .offset(x: thumbX)
            }
            .frame(height: geometry.size.height)
            .overlay(
                PointerTracker(isEnabled: isEnabled) { phase, x in
                    track(phase, x: x, thumbCentre: thumbX + Self.thumbSize.width / 2, travel: travel)
                }
            )
        }
        .frame(height: Self.height)
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
        }
    }

    @ViewBuilder private var thumb: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                .glassEffect(press.isPressed ? .clear : .regular, in: Capsule())
        } else {
            Capsule()
                .fill(Color.white)
                .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        }
    }

    private func track(_ phase: PointerTracker.Phase, x: CGFloat, thumbCentre: CGFloat, travel: CGFloat) {
        switch phase {
        case .began:
            // A press on the thumb keeps the thumb where it is. A press on the track brings the thumb there.
            let distance = x - thumbCentre
            press.grabOffset = abs(distance) <= Self.thumbSize.width / 2 ? distance : 0
            press.isPressed = true
            if press.grabOffset != 0 { return }
        case .changed:
            break
        case .ended:
            press.isPressed = false
            return
        }
        let centre = x - press.grabOffset
        let fraction = min(max((centre - Self.thumbSize.width / 2) / travel, 0), 1)
        value = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
    }
}

private final class PressState: ObservableObject {
    @Published var isPressed = false
    /// Where on the thumb the pointer took hold, from the centre of the thumb.
    var grabOffset: CGFloat = 0
}

/// Reports a press and a drag, with the horizontal position in the view.
///
/// An AppKit view and not a SwiftUI gesture, so a drag here can never be taken for a drag of the window.
private struct PointerTracker: NSViewRepresentable {
    enum Phase {
        case began, changed, ended
    }

    var isEnabled: Bool
    var onEvent: (Phase, CGFloat) -> Void

    final class TrackerView: NSView {
        var isEnabled = true
        var onEvent: (Phase, CGFloat) -> Void = { _, _ in }
        private var isTracking = false

        override var mouseDownCanMoveWindow: Bool { false }
        // The first click on a window that is not in front already moves the thumb.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            isTracking = true
            send(.began, event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isTracking else { return }
            send(.changed, event)
        }

        override func mouseUp(with event: NSEvent) {
            guard isTracking else { return }
            isTracking = false
            send(.ended, event)
        }

        private func send(_ phase: Phase, _ event: NSEvent) {
            onEvent(phase, convert(event.locationInWindow, from: nil).x)
        }
    }

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.isEnabled = isEnabled
        view.onEvent = onEvent
    }
}

/// The Command Line Tools have no support for `@State`, so the hover state is an object.
private final class HoverState: ObservableObject {
    @Published var isHovered = false
}

private struct TransitionRow: View {
    let style: TransitionStyle
    let speed: Double
    let sensitivity: Double
    let dockMovesWithSpace: Bool
    let isSelected: Bool
    let select: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: select) {
            HStack(spacing: 0) {
                // The preview beside it says what the transition does, so the name is enough.
                // The description is still read out by VoiceOver.
                Text(style.title)
                    .font(.system(size: 15, weight: .medium))
                    .accessibilityHint(style.detail)

                Spacer(minLength: 12)

                TransitionPreview(
                    style: style, speed: speed, sensitivity: sensitivity, dockMovesWithSpace: dockMovesWithSpace
                )
            }
            // The same space left of the text as right of the preview.
            .padding(.horizontal, SettingsLayout.inset)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.rowRadius, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.07 : (hover.isHovered ? 0.045 : 0)))
                    // The highlight is there at once and fades when the pointer leaves.
                    .animation(hover.isHovered ? nil : .easeOut(duration: 0.15), value: hover.isHovered)
            )
            .overlay(
                // Only the selected row has an edge, so it stays apart from a row that is hovered.
                RoundedRectangle(cornerRadius: SettingsLayout.rowRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0.16 : 0), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
