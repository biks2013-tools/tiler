import CoreGraphics

public enum Geometry {
    /// The window whose frame is the nearest neighbour of `source` in
    /// `direction`. Frames that overlap `source` across the movement axis win
    /// over ones that do not; then the closest edge; then the closest centre.
    public static func neighbor(of source: WindowID, _ direction: Direction,
                                in frames: [WindowID: CGRect], tolerance: CGFloat = 4) -> WindowID? {
        guard let s = frames[source] else { return nil }
        var best: (id: WindowID, overlaps: Bool, gap: CGFloat, offset: CGFloat)?
        for (id, f) in frames where id != source {
            let gap: CGFloat
            let overlap: CGFloat
            let offset: CGFloat
            switch direction {
            case .left:
                guard f.maxX <= s.minX + tolerance else { continue }
                gap = s.minX - f.maxX
                overlap = min(s.maxY, f.maxY) - max(s.minY, f.minY)
                offset = abs(f.midY - s.midY)
            case .right:
                guard f.minX >= s.maxX - tolerance else { continue }
                gap = f.minX - s.maxX
                overlap = min(s.maxY, f.maxY) - max(s.minY, f.minY)
                offset = abs(f.midY - s.midY)
            case .up:
                guard f.maxY <= s.minY + tolerance else { continue }
                gap = s.minY - f.maxY
                overlap = min(s.maxX, f.maxX) - max(s.minX, f.minX)
                offset = abs(f.midX - s.midX)
            case .down:
                guard f.minY >= s.maxY - tolerance else { continue }
                gap = f.minY - s.maxY
                overlap = min(s.maxX, f.maxX) - max(s.minX, f.minX)
                offset = abs(f.midX - s.midX)
            }
            let candidate = (id: id, overlaps: overlap > 0, gap: gap, offset: offset)
            guard let b = best else { best = candidate; continue }
            if candidate.overlaps != b.overlaps {
                if candidate.overlaps { best = candidate }
            } else if abs(candidate.gap - b.gap) > 0.5 {
                if candidate.gap < b.gap { best = candidate }
            } else if abs(candidate.offset - b.offset) > 0.5 {
                if candidate.offset < b.offset { best = candidate }
            } else if candidate.id < b.id {
                best = candidate
            }
        }
        return best?.id
    }

    /// The window whose frame contains `point`, if any.
    public static func window(at point: CGPoint, in frames: [WindowID: CGRect]) -> WindowID? {
        frames.first { $0.value.contains(point) }?.key
    }

    /// True when two frames match within `tolerance` points on every edge.
    public static func roughlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// `frame` moved from one usable area to another: the same size, shrunk to
    /// fit, at the same relative position (centred when the source is unknown).
    public static func place(_ frame: CGRect, from source: CGRect?, to target: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, target.width), height: min(frame.height, target.height))
        func fraction(_ offset: CGFloat, _ room: CGFloat) -> CGFloat { room > 0 ? min(max(offset / room, 0), 1) : 0.5 }
        let fx = source.map { fraction(frame.minX - $0.minX, $0.width - frame.width) } ?? 0.5
        let fy = source.map { fraction(frame.minY - $0.minY, $0.height - frame.height) } ?? 0.5
        return CGRect(x: (target.minX + fx * (target.width - size.width)).rounded(),
                      y: (target.minY + fy * (target.height - size.height)).rounded(),
                      width: size.width, height: size.height)
    }
}
