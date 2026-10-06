import Combine
import Foundation

/// The one owner of "the pointer should be the left-right resize cursor" for every waveform
/// lane. Lanes only report what happens; each draws the resize pointer through SwiftUI's
/// `.pointerStyle` while `showsResize(in:)` says so, and AppKit owns the cursor. Nothing is
/// pushed or popped, so nothing can stay unbalanced, and only one lane can ask at a time.
///
/// Designer rule: the resize cursor shows while the pointer is in an edge's 5 px zone, and
/// stays for an edge drag until mouse-up, also when the pointer leaves the zone. On mouse-up,
/// wherever it is, or when the pointer leaves the zone, it is the normal arrow again at once.
@MainActor
final class EdgeCursorController: ObservableObject {
    static let shared = EdgeCursorController()

    /// The lane whose edge zone the pointer is in.
    @Published private(set) var hoveredLane: String?
    /// The lane whose edge is being dragged; it keeps the resize cursor until mouse-up.
    @Published private(set) var draggingLane: String?

    func showsResize(in lane: String) -> Bool {
        if let draggingLane {
            return draggingLane == lane
        }
        return hoveredLane == lane
    }

    /// True while any lane shows the resize cursor; otherwise it is the normal arrow.
    var showsResize: Bool {
        draggingLane != nil || hoveredLane != nil
    }

    /// The pointer moved inside `lane`: in an edge zone or not.
    func hover(in lane: String, overEdge: Bool) {
        if overEdge {
            update(\.hoveredLane, to: lane)
        } else if hoveredLane == lane {
            update(\.hoveredLane, to: nil)
        }
    }

    /// The pointer left `lane`. A leave arriving after the next lane's enter changes nothing.
    func hoverEnded(in lane: String) {
        if hoveredLane == lane {
            update(\.hoveredLane, to: nil)
        }
    }

    func dragBegan(in lane: String) {
        update(\.draggingLane, to: lane)
    }

    /// Mouse-up, wherever it is: the resize cursor stays only if released over an edge zone
    /// of `lane` (the dragged edge is then under the pointer); otherwise it is the arrow.
    func dragEnded(in lane: String, overEdge: Bool) {
        guard draggingLane == lane else {
            return
        }
        update(\.draggingLane, to: nil)
        hover(in: lane, overEdge: overEdge)
    }

    /// The lane went away (e.g. its take was deleted mid-drag).
    func laneDisappeared(_ lane: String) {
        if draggingLane == lane {
            update(\.draggingLane, to: nil)
        }
        hoverEnded(in: lane)
    }

    /// Publishes only real changes: every lane observes this.
    private func update(_ keyPath: ReferenceWritableKeyPath<EdgeCursorController, String?>, to lane: String?) {
        if self[keyPath: keyPath] != lane {
            self[keyPath: keyPath] = lane
        }
    }
}
