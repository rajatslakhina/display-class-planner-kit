//
//  WorkItem.swift
//  DisplayClassPlanner
//

/// A stable identity for a unit of prefetchable work.
///
/// Identity is the load-bearing idea in this package. A display-class change
/// recomputes *what should be in flight*, and the only way to avoid cancelling
/// a request and immediately re-issuing the identical one is to compare plans
/// by an identity that survives the re-plan. `WorkID` must therefore be derived
/// from the *content* (a media URL, a record id) — never from an array index or
/// an `IndexPath`, both of which change when the layout does.
public struct WorkID: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: WorkID, rhs: WorkID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }
}

/// How badly the surface wants a unit of work, right now.
///
/// Ordered so `>` means "more urgent", which lets admission sort descending
/// without a custom comparator at every call site.
public enum WorkPriority: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Not on screen and not adjacent. First to be cancelled under pressure.
    case speculative = 0
    /// Just off screen in the scroll direction, or in a pane that just appeared.
    case adjacent = 1
    /// On screen now. Cancelling this is user-visible as a blank cell.
    case visible = 2

    public static func < (lhs: WorkPriority, rhs: WorkPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One unit of prefetchable work the surface would like performed.
public struct WorkItem: Sendable, Hashable {
    public let id: WorkID
    public let priority: WorkPriority

    /// Position along the surface's content axis. Used only as a deterministic
    /// tie-break within a priority band, so that two runs over the same input
    /// produce byte-identical plans.
    public let index: Int

    /// Decoded size this item is expected to occupy, in bytes.
    ///
    /// Clamped to `0...` in `init`: a negative estimate would let an item
    /// *refund* budget to the admission loop and admit unbounded work.
    public let estimatedDecodeBytes: Int

    public init(id: WorkID, priority: WorkPriority, index: Int, estimatedDecodeBytes: Int) {
        self.id = id
        self.priority = priority
        self.index = index
        self.estimatedDecodeBytes = Swift.max(0, estimatedDecodeBytes)
    }
}

extension WorkItem {
    /// The total order admission uses: urgent first, then content order, then
    /// id as a final tie-break so the ordering is total (never a stable-sort
    /// coin flip) and therefore reproducible across runs and platforms.
    @usableFromInline
    static func admissionOrder(_ lhs: WorkItem, _ rhs: WorkItem) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.index != rhs.index { return lhs.index < rhs.index }
        return lhs.id < rhs.id
    }
}
