import CoreGraphics
import Foundation

/// Designer rule for grabbing the selection's edges, in screen points, so it is the same in
/// the full and the zoomed view. An edge is grabbed within `grabZone` of it on either side.
/// A press there that moves less than `clickSlop` before release is a plain click: it only
/// moves the playhead and never changes the selection. Elsewhere a press becomes a new
/// selection once it moves `selectSlop`; less is a plain click as well.
struct WaveformSelectionEdges {
    enum Edge: Equatable {
        case start
        case end
    }

    /// What a press has become so far; `nil` while it is still a plain click.
    enum PressKind: Equatable {
        case resize(Edge)
        case select
    }

    static let grabZone: CGFloat = 5
    static let clickSlop: CGFloat = 3
    static let selectSlop: CGFloat = 4

    let viewport: TimelineViewport
    let width: CGFloat

    func time(at xPosition: CGFloat) -> TimeInterval {
        guard width > 0 else {
            return viewport.start
        }
        let fraction = min(max(xPosition / width, 0), 1)
        return viewport.start + viewport.duration * Double(fraction)
    }

    func xPosition(for time: TimeInterval) -> CGFloat {
        guard viewport.duration > 0 else {
            return 0
        }
        return width * CGFloat((time - viewport.start) / viewport.duration)
    }

    /// The edge whose grab zone holds `xPosition`; the nearer one when the zones overlap.
    func edge(at xPosition: CGFloat, of region: PracticeRegion?) -> Edge? {
        guard let region else {
            return nil
        }
        let startDistance = abs(xPosition - self.xPosition(for: region.start))
        let endDistance = abs(xPosition - self.xPosition(for: region.end))
        guard min(startDistance, endDistance) <= Self.grabZone else {
            return nil
        }
        return startDistance <= endDistance ? .start : .end
    }

    func pressKind(startX: CGFloat, distance: CGFloat, region: PracticeRegion?) -> PressKind? {
        if let edge = edge(at: startX, of: region) {
            return distance >= Self.clickSlop ? .resize(edge) : nil
        }
        return distance >= Self.selectSlop ? .select : nil
    }

    /// Where a dragged edge goes: it moves by the drag, so it does not jump to the pointer
    /// when the press was a few points beside it.
    func draggedEdgeTime(
        _ edge: Edge,
        of region: PracticeRegion,
        from startX: CGFloat,
        to currentX: CGFloat
    ) -> TimeInterval {
        let base = edge == .start ? region.start : region.end
        guard width > 0 else {
            return base
        }
        return base + Double((currentX - startX) / width) * viewport.duration
    }
}
