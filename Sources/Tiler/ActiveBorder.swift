import AppKit

/// The frame drawn around the active window on a tiled desktop
/// (`activeBorder`, `activeBorderWidth`).
///
/// - One borderless, click-through, transparent window, ordered directly above
///   the active window, so windows stacked above that one (a floating window,
///   a menu) still cover the frame where they overlap.
/// - The ring is drawn outside the window's edges, in the gap between tiles,
///   so it never covers the window's content.
/// - No polling: the controller calls `show` on focus changes, after layouts
///   and when the window reports a move or resize, and `hide` when the active
///   window is not on a tiled desktop or is being dragged.
final class ActiveBorder {
    private var panel: NSPanel?
    private var view: RingView?
    private(set) var windowID: CGWindowID?

    /// Frame `id` (on screen at `frame`, top-left coordinates) in `color`.
    func show(around id: CGWindowID, frame: CGRect, color: NSColor, width: Double) {
        let panel = self.panel ?? makePanel()
        let outer = frame.insetBy(dx: -width, dy: -width)
        // Window-server coordinates are top-left; AppKit's are bottom-left.
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: outer.minX, y: primary - outer.maxY, width: outer.width, height: outer.height)
        view?.color = color
        view?.width = width
        view?.needsDisplay = true
        if panel.frame != rect { panel.setFrame(rect, display: true) }
        panel.order(.above, relativeTo: Int(id))
        windowID = id
    }

    func hide() {
        panel?.orderOut(nil)
        windowID = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.level = .normal
        // Stays on the desktop it is shown on, out of Mission Control's window
        // list and the window cycle.
        p.collectionBehavior = [.managed, .ignoresCycle, .fullScreenNone]
        let v = RingView()
        p.contentView = v
        panel = p
        view = v
        return p
    }
}

extension NSColor {
    /// An sRGB colour from 0xRRGGBB, as config colours are written.
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// 0xRRGGBB in sRGB (nil if the colour has no sRGB form).
    var rgb: UInt32? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }
}

/// A rounded ring hugging the edges of its bounds.
private final class RingView: NSView {
    var color: NSColor = .clear
    var width: Double = 4

    override func draw(_ dirtyRect: NSRect) {
        // macOS windows have rounded corners; the ring follows them outside.
        let radius = 10 + width
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2),
                                xRadius: radius - width / 2, yRadius: radius - width / 2)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }
}
