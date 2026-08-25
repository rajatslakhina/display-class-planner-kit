//
//  TransitionDebouncer.swift
//  DisplayClassPlanner
//

/// What the caller should do about a viewport observation.
public enum TransitionDecision: Sendable, Hashable {
    /// Same display class as the committed one, and nothing was pending.
    case ignore

    /// Commit immediately. Returned for expansions.
    case applyNow(Viewport)

    /// A contraction was observed; commit it at `deadline` if it survives.
    /// Call ``TransitionDebouncer/tick(at:)`` at or after that timestamp.
    case hold(Viewport, until: UInt64)

    /// A pending change was withdrawn because the surface returned to the
    /// committed display class before its deadline. Nothing was cancelled,
    /// nothing needs restarting — the storm cost zero requests.
    case withdrawn
}

/// Asymmetric hysteresis for display-class changes.
///
/// **The problem.** A fold, a Split View drag and a Stage Manager resize all
/// emit a stream of size changes, and the sequence can reverse within a few
/// hundred milliseconds. Re-planning on every observation means cancelling
/// requests that the very next observation asks for again — the user pays for
/// the same bytes twice and sees a flash of empty cells for the privilege.
///
/// **The design.** Expansion and contraction are not symmetric events, so they
/// do not get symmetric treatment:
///
/// - **Expanding is applied immediately.** A pane appeared and it is empty.
///   Every millisecond of delay is visible.
/// - **Contracting is held.** The pane that is going away still has its content;
///   nothing is visibly wrong while we wait. Holding costs nothing and buys
///   immunity to the reversal.
/// - **A reversal during the hold withdraws the pending change entirely,** so a
///   fold-unfold-fold storm settles without ever having cancelled a request.
///
/// **Deliberately not a `Clock`.** Every method takes an explicit `now`. That
/// makes a fold storm a table of integers in a test rather than a sequence of
/// `Task.sleep` calls, and it means the same code drives the deterministic
/// replay harness and the real `CADisplayLink`.
public struct TransitionDebouncer: Sendable, Hashable {

    public struct Policy: Sendable, Hashable {
        /// Hold applied before committing an expansion. Zero by default.
        public var expansionHoldNanos: UInt64
        /// Hold applied before committing a contraction.
        public var contractionHoldNanos: UInt64

        public init(expansionHoldNanos: UInt64 = 0, contractionHoldNanos: UInt64 = 400_000_000) {
            self.expansionHoldNanos = expansionHoldNanos
            self.contractionHoldNanos = contractionHoldNanos
        }

        public static let `default` = Policy()

        /// No hysteresis at all. Useful for tests that want to isolate the
        /// reconciler, and for surfaces whose size only changes on a hard
        /// scene transition.
        public static let immediate = Policy(expansionHoldNanos: 0, contractionHoldNanos: 0)
    }

    /// A change waiting for its deadline.
    public struct Pending: Sendable, Hashable {
        public let viewport: Viewport
        public let deadline: UInt64
    }

    public let policy: Policy
    public private(set) var committed: Viewport
    public private(set) var pending: Pending?

    /// Number of pending changes withdrawn by a reversal. This is the metric
    /// that justifies the hysteresis existing at all — if it stays at zero in
    /// production, the hold is pure latency and should be turned off.
    public private(set) var withdrawnCount: Int = 0

    public init(committed: Viewport = .zero, policy: Policy = .default) {
        self.committed = committed
        self.policy = policy
    }

    /// Feeds a viewport observation in.
    ///
    /// - Parameter now: a monotonic timestamp in nanoseconds. Must be
    ///   non-decreasing across calls; a decreasing clock cannot make this trap
    ///   (all arithmetic is saturating) but it will delay a pending commit.
    public mutating func observe(_ viewport: Viewport, at now: UInt64) -> TransitionDecision {
        let target = viewport.displayClass
        let current = committed.displayClass

        guard target != current else {
            // Back to where we started. If something was pending, the storm
            // reversed and we get to keep every in-flight request.
            if pending != nil {
                pending = nil
                withdrawnCount = Saturating.adding(withdrawnCount, 1)
                // Adopt the latest measurements even though the class is
                // unchanged: width may have shifted within the same class and
                // the budget should track it.
                committed = viewport
                return .withdrawn
            }
            committed = viewport
            return .ignore
        }

        let isExpansion = target > current
        let hold = isExpansion ? policy.expansionHoldNanos : policy.contractionHoldNanos

        guard hold > 0 else {
            pending = nil
            committed = viewport
            return .applyNow(viewport)
        }

        // A change to the same target class that is already pending keeps its
        // ORIGINAL deadline. Extending it on every observation is the classic
        // debounce-starvation bug: a surface emitting size changes at 60 Hz
        // during a drag would push the deadline out forever and never commit.
        if let existing = pending, existing.viewport.displayClass == target {
            return .hold(existing.viewport, until: existing.deadline)
        }

        let deadline = Saturating.adding(now, hold)
        let next = Pending(viewport: viewport, deadline: deadline)
        pending = next
        return .hold(viewport, until: deadline)
    }

    /// Commits a pending change whose deadline has arrived.
    ///
    /// - Returns: the newly committed viewport, or `nil` if nothing was due.
    public mutating func tick(at now: UInt64) -> Viewport? {
        guard let existing = pending, now >= existing.deadline else { return nil }
        pending = nil
        committed = existing.viewport
        return existing.viewport
    }

    /// The deadline the caller should schedule a `tick` for, if any.
    public var nextDeadline: UInt64? { pending?.deadline }
}
