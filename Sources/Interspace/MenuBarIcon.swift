import AppKit

/// The menu bar icon: two screens with round corners. The smaller one is in front, to the left;
/// the larger one is behind it, to the right, and its outline stops a little before the front one.
enum MenuBarIcon {
    static let size = CGSize(width: 22, height: 15)

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context)
            return true
        }
        // The menu bar gives it the right colour, also when it is selected or dimmed.
        image.isTemplate = true
        image.accessibilityDescription = "Interspace"
        return image
    }

    /// Draws in a space of `size` with the origin at the top left.
    static func draw(in context: CGContext) {
        let lineWidth: CGFloat = 1.25
        // The front screen is as tall as it can be. Its top and bottom edges must stay about one line
        // width away from those of the back screen: closer, and the two lines turn into one thick line
        // at menu bar size.
        let back = CGRect(x: 5.6, y: 0.65, width: 15.75, height: 13.7)
        let front = CGRect(x: 0.65, y: 2.85, width: 13.0, height: 9.3)
        let frontRadius: CGFloat = 3.0
        let backPath = CGPath(roundedRect: back, cornerWidth: 3.6, cornerHeight: 3.6, transform: nil)
        let frontPath = CGPath(roundedRect: front, cornerWidth: frontRadius, cornerHeight: frontRadius, transform: nil)

        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor.black.cgColor)

        context.addPath(backPath)
        context.strokePath()

        // Remove the part of the back screen that is behind the front one, with a small gap around it.
        let gap: CGFloat = 0.9
        let hole = front.insetBy(dx: -(lineWidth / 2 + gap), dy: -(lineWidth / 2 + gap))
        context.setBlendMode(.clear)
        context.addPath(CGPath(roundedRect: hole, cornerWidth: frontRadius + lineWidth / 2 + gap, cornerHeight: frontRadius + lineWidth / 2 + gap, transform: nil))
        context.fillPath()
        context.setBlendMode(.normal)

        context.addPath(frontPath)
        context.strokePath()
    }
}
