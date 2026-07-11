import Foundation

/// Vertical ordering of Take tracks under Original.
/// Lower `displayOrder` is closer to Original (higher on screen).
enum TakeDisplayOrdering {
    /// Display order for a newly appended take so it appears directly under Original.
    static func nextTopDisplayOrder(existing: [Take]) -> Int {
        guard let minimum = existing.map(\.displayOrder).min() else {
            return 0
        }
        return minimum - 1
    }

    /// Assigns contiguous display orders `0..<count` matching the given visual order.
    static func reindexed(_ takes: [Take]) throws -> [Take] {
        try takes.enumerated().map { index, take in
            try take.withDisplayOrder(index)
        }
    }

    /// Moves a take within the list and reindexes display orders.
    static func moving(
        _ takes: [Take],
        fromOffsets: IndexSet,
        toOffset: Int
    ) throws -> [Take] {
        var ordered = takes
        ordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        return try reindexed(ordered)
    }

    /// Moves `draggedID` onto `targetID`'s current slot (target shifts away).
    static func moving(
        _ takes: [Take],
        draggedID: UUID,
        onto targetID: UUID
    ) throws -> [Take]? {
        guard draggedID != targetID,
              let from = takes.firstIndex(where: { $0.id == draggedID }),
              let to = takes.firstIndex(where: { $0.id == targetID })
        else {
            return nil
        }
        let destination = to > from ? to + 1 : to
        return try moving(takes, fromOffsets: IndexSet(integer: from), toOffset: destination)
    }
}
