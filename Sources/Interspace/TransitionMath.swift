import CoreGraphics

/// The math of the Lightweight transition, in one place. The real transition and its preview in the
/// settings window both use these functions, so the preview cannot drift away from the real thing.
enum TransitionMath {
    /// A release faster than this, in progress per second, is limited to it.
    static let maxReleaseVelocity: CGFloat = 8

    /// 0 at rest, 1 when the screens are at their smallest. `progress` is in spaces: 0 and 1 are at rest.
    static func engage(progress: CGFloat) -> CGFloat {
        // Distance to the nearest resting position. Zero there, so the hand-off to the live desktop is exact.
        let travel = abs(progress - progress.rounded())
        let x = min(max(travel / Config.scaleDistance, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// The size of the screens, where 1 is full size.
    static func scale(progress: CGFloat) -> CGFloat {
        1 - Config.scaleInset * engage(progress: progress)
    }

    /// How dark a screen is. `offCentre` is 0 for the screen in the middle and 1 for a screen one step away.
    static func dim(offCentre: CGFloat) -> CGFloat {
        Config.dimAmount * min(max(offCentre, 0), 1)
    }

    // MARK: Hexagon

    /// The spaces are the sides of a six-sided prism with an upright axis behind the screen.
    /// Two sides that touch are 60 degrees apart, against 90 for a cube.
    static let hexFaceAngle = CGFloat.pi / 3
    /// The distance from a side to the axis, in screen widths.
    static let hexApothem: CGFloat = 0.5 / tan(CGFloat.pi / 6)

    /// How far the prism is moved back, in screen widths.
    static func hexPushback(progress: CGFloat) -> CGFloat {
        Config.hexPushback * engage(progress: progress)
    }

    static func hexDim(offset: CGFloat) -> CGFloat {
        Config.hexDim * min(abs(offset), 1)
    }

    /// Where a point of a side is on the display. `x` and `y` are from the centre of the side, in screen
    /// widths. `offset` is the number of steps the side is away from the front. The result is from the
    /// centre of the display, in screen widths, with the size of things at that point.
    /// This is the same projection that Core Animation does for the real transition.
    static func hexProject(x: CGFloat, y: CGFloat, offset: CGFloat, progress: CGFloat) -> (x: CGFloat, y: CGFloat, scale: CGFloat) {
        let angle = offset * hexFaceAngle
        let turnedX = x * cos(angle) + hexApothem * sin(angle)
        let depth = -x * sin(angle) + hexApothem * cos(angle) - hexApothem - hexPushback(progress: progress)
        let scale = Config.hexPerspective / (Config.hexPerspective - depth)
        return (turnedX * scale, y * scale, scale)
    }

    // MARK: Magnetic

    // Like Lightweight, the screens are in a row and slide. The difference: in Lightweight all screens have
    // the same size at any moment and dip a little together. Here each screen has its own size, from how
    // far it is from the middle of the display. The screen that leaves shrinks as it goes, and the screen
    // that arrives grows into place.
    //
    // `offset` is the number of steps a screen is from the middle: 0 is in the middle.

    /// The size of a screen, where 1 is full size.
    static func magneticScale(offset: CGFloat) -> CGFloat {
        let x = min(abs(offset), 1)
        return 1 - Config.magneticInset * x * x * (3 - 2 * x)
    }

    /// Where the centre of a screen is, from the middle of the display, in screen widths. `gap` is the
    /// space between two screens, also in screen widths.
    ///
    /// Two screens that are next to each other always have exactly `gap` between their edges, though both
    /// change size as they move. That fixes the place of each: between the middle and one step away, the
    /// distance is the part `t` of (half of each of the two widths, plus the gap).
    static func magneticPosition(offset: CGFloat, gap: CGFloat) -> CGFloat {
        let t = abs(offset)
        let sign: CGFloat = offset < 0 ? -1 : 1
        let far = magneticScale(offset: 1)
        if t <= 1 {
            let pair = (magneticScale(offset: t) + magneticScale(offset: 1 - t)) / 2 + gap
            return sign * t * pair
        }
        // Past one step every screen has the small size, so the row goes on in even steps.
        let oneStep = (1 + far) / 2 + gap
        return sign * (oneStep + (t - 1) * (far + gap))
    }

    // MARK: Stack

    // The spaces are a pile of cards in a fixed order. The current space and all spaces before it are on the
    // display, one on top of the other, the current one on top. The spaces after it wait off the right edge.
    // To go forward, the next card slides in from the right and lands on the pile. To go back, the top card
    // slides off to the right and the card below it shows. A card on the pile does not move sideways.
    //
    // `offset` is the number of steps a card is after the current space: 0 is the top of the pile,
    // +1 is one step off to the right, -1 is one card down in the pile.

    /// How far a card is off to the right, in screen widths: 0 on the pile, 1 fully off the display.
    static func stackSlide(offset: CGFloat) -> CGFloat {
        min(max(offset, 0), 1)
    }

    /// How covered a card is: 0 for the top of the pile, 1 with a full card on top of it.
    static func stackCover(offset: CGFloat) -> CGFloat {
        min(max(-offset, 0), 1)
    }

    /// The size of a card, where 1 is full size. A covered card is a little smaller, so it reads as lower.
    static func stackScale(offset: CGFloat) -> CGFloat {
        1 - Config.stackInset * stackCover(offset: offset)
    }

    static func stackDim(offset: CGFloat) -> CGFloat {
        Config.stackDim * stackCover(offset: offset)
    }

    /// The strength of the shadow of a card. A card that is fully off the display has none: its shadow
    /// would reach back onto the display at rest.
    static func stackShadow(offset: CGFloat) -> CGFloat {
        Config.stackShadow * min((1 - stackSlide(offset: offset)) * 8, 1)
    }

    // MARK: Snap

    /// True when the snap is over. `progress` is the distance to the resting position.
    static func isSettled(progress: CGFloat, velocity: CGFloat) -> Bool {
        abs(progress) < 0.001 && abs(velocity) < 0.02
    }

    /// Moves the snap spring forward by `delta` seconds. The spring pulls `progress` to 0.
    /// `response` is the spring response in seconds, `speed` the speed setting.
    /// `limit` is the largest distance there is a picture for.
    static func stepSpring(
        progress: inout CGFloat, velocity: inout CGFloat, delta: CGFloat,
        response: CGFloat = Config.springResponse, speed: CGFloat, limit: CGFloat = 1
    ) {
        let omega = 2 * CGFloat.pi / response * speed
        let stiffness = omega * omega
        let damping = 2 * Config.springDamping * omega
        // Small fixed steps keep the integration stable at any refresh rate.
        var remaining = delta
        while remaining > 0 {
            let step = min(remaining, 0.002)
            velocity += (-stiffness * progress - damping * velocity) * step
            progress += velocity * step
            remaining -= step
        }
        progress = min(max(progress, -limit), limit)
    }
}
