//
//  PlanTransition.swift
//  DisplayClassPlanner
//

/// The instruction set a display-class change produces.
///
/// This is deliberately a *diff*, not a new plan. Handing a caller a fresh list
/// of "what should be in flight" and letting it work out the delta is how the
/// duplicated-fetch bug gets written: the obvious implementation cancels
/// everything and starts the new list, and roughly 80% of that list was already
/// running.
public struct PlanTransition: Sendable, Hashable {

    /// The generation this transition establishes. Strictly increasing.
    public let generation: UInt64

    /// The budget that produced it.
    public let budget: CapacityBudget

    /// The viewport that produced it.
    public let viewport: Viewport

    /// Already in flight, still wanted, still at the same priority.
    /// **Do nothing with these.** Touching them is the bug.
    public let retained: [WorkID]

    /// Already in flight, still wanted, at a new priority. Re-order the queue;
    /// do not restart the request.
    public let reprioritized: [Reprioritization]

    /// Was in flight, no longer wanted. Cancel these.
    public let cancelled: [WorkID]

    /// Newly wanted and not currently in flight. Start these.
    public let admitted: [WorkItem]

    public init(
        generation: UInt64,
        budget: CapacityBudget,
        viewport: Viewport,
        retained: [WorkID],
        reprioritized: [Reprioritization],
        cancelled: [WorkID],
        admitted: [WorkItem]
    ) {
        self.generation = generation
        self.budget = budget
        self.viewport = viewport
        self.retained = retained
        self.reprioritized = reprioritized
        self.cancelled = cancelled
        self.admitted = admitted
    }

    /// A priority change applied to work that is already running.
    public struct Reprioritization: Sendable, Hashable {
        public let id: WorkID
        public let from: WorkPriority
        public let to: WorkPriority

        public init(id: WorkID, from: WorkPriority, to: WorkPriority) {
            self.id = id
            self.from = from
            self.to = to
        }
    }

    /// Number of items that will be in flight once the caller has applied this.
    ///
    /// Saturating, like every other runtime-value sum in the package. These
    /// three counts are bounded by `CapacityBudget.maxPrefetchDepth` when the
    /// transition comes from `PlanReconciler`, but `PlanTransition` is a public
    /// value type anyone can construct — including a test feeding it garbage —
    /// and "it can't overflow if you built it correctly" is not a bound.
    public var resultingInFlightCount: Int {
        Saturating.adding(
            Saturating.adding(retained.count, reprioritized.count),
            admitted.count
        )
    }

    /// True when nothing needs to happen. Callers can short-circuit on this
    /// rather than scheduling an empty batch of work.
    public var isNoop: Bool {
        cancelled.isEmpty && admitted.isEmpty && reprioritized.isEmpty
    }
}

// MARK: - Invariants

extension PlanTransition {

    /// A way in which a transition is self-contradictory.
    ///
    /// These are the properties the README claims, expressed as something a
    /// test can falsify. Every case here corresponds to a real bug shape, not a
    /// hypothetical one.
    public enum InvariantViolation: Sendable, Hashable, CustomStringConvertible {
        /// The same id is both cancelled and (retained | reprioritized |
        /// admitted). This is the duplicated-fetch bug: the caller tears down a
        /// request and immediately starts an identical one.
        case cancelledAndKept(WorkID)

        /// The same id appears in two of the "keep it running" buckets, so the
        /// caller has two contradictory instructions for one request.
        case duplicateInstruction(WorkID)

        /// A reprioritization that does not change anything. Harmless at
        /// runtime, but it means the reconciler mis-bucketed something that
        /// belonged in `retained`, and it inflates "work done" metrics.
        case degenerateReprioritization(WorkID)

        /// The transition leaves more work in flight than the budget allows.
        case overAdmitted(count: Int, limit: Int)

        /// `admitted` exceeds the decode byte budget. Reported with both
        /// numbers so a failure message is actionable.
        case overDecodeBudget(bytes: Int, limit: Int)

        /// An id that was in flight before this transition appears in *none* of
        /// the four buckets. The caller is never told to cancel it and never
        /// told to keep it, so the request runs forever and its slot is never
        /// reclaimed. Checking only for contradictions misses this entirely,
        /// which is why the in-flight set is worth passing in.
        case leaked(WorkID)

        /// `cancelled` names an id that was not running. Tearing down a request
        /// that does not exist is either a double-cancel or a bookkeeping
        /// error; both are bugs.
        case phantomCancellation(WorkID)

        /// `retained` or `reprioritized` names an id that was not running, so
        /// the caller is told to keep alive something it never started — and
        /// the item is silently never fetched.
        case keptButNotRunning(WorkID)

        public var description: String {
            switch self {
            case .cancelledAndKept(let id):
                return "\(id) is cancelled and also kept — a cancel-then-refetch of the same identity"
            case .duplicateInstruction(let id):
                return "\(id) appears in more than one instruction bucket"
            case .degenerateReprioritization(let id):
                return "\(id) was reprioritized from a priority to itself"
            case .overAdmitted(let count, let limit):
                return "transition leaves \(count) in flight, budget allows \(limit)"
            case .overDecodeBudget(let bytes, let limit):
                return "admitted \(bytes) decode bytes, budget allows \(limit)"
            case .leaked(let id):
                return "\(id) was in flight and this transition says nothing about it — it leaks"
            case .phantomCancellation(let id):
                return "\(id) is cancelled but was not in flight"
            case .keptButNotRunning(let id):
                return "\(id) is retained or reprioritized but was not in flight"
            }
        }
    }

    /// Checks the transition against every invariant the package claims.
    ///
    /// Exposed publicly on purpose. A caller that writes its own reconciler —
    /// or wraps this one — can assert against the same contract in its own test
    /// suite, and `DisplayClassPlannerTests` uses it against *deliberately
    /// broken* transitions to prove the checker is not vacuous.
    ///
    /// - Parameters:
    ///   - inFlight: what was running *before* this transition. Optional,
    ///     because a caller holding only the transition can still check it for
    ///     self-contradiction — but **pass it when you have it.** Without it,
    ///     `validate` can only catch contradictions (an id both cancelled and
    ///     kept); with it, it also catches *omissions* (an id that was running
    ///     and is now mentioned nowhere), which is the leak this package exists
    ///     to prevent and which no amount of internal-consistency checking can
    ///     see.
    ///   - allowOversizedHeadItem: mirrors
    ///     ``PlanReconciler/Policy/admitsOversizedHeadItem``. When `true`, a
    ///     lone admitted item is permitted to exceed the whole decode budget,
    ///     because starving the one visible cell is worse than overshooting.
    ///     The exemption additionally requires `retained` and `reprioritized`
    ///     to be empty: the reconciler only exempts the item at the *head* of
    ///     admission order, and anything already retained sits ahead of it.
    /// - Returns: every violation found, in a deterministic order. Empty means
    ///   the transition is consistent.
    public func validate(
        inFlight: Set<WorkID>? = nil,
        allowOversizedHeadItem: Bool = true
    ) -> [InvariantViolation] {
        var violations: [InvariantViolation] = []

        let cancelledSet = Set(cancelled)
        var seen = Set<WorkID>()
        var duplicates = Set<WorkID>()
        var conflicts = Set<WorkID>()

        // One pass over the three "keep it" buckets, in a fixed order so the
        // reported violations are deterministic.
        let keptIDs: [WorkID] = retained + reprioritized.map(\.id) + admitted.map(\.id)
        for id in keptIDs {
            if !seen.insert(id).inserted { duplicates.insert(id) }
            if cancelledSet.contains(id) { conflicts.insert(id) }
        }

        // `cancelled` may itself contain duplicates; two cancels of one request
        // is a double-teardown, which is the same class of bug.
        var seenCancelled = Set<WorkID>()
        for id in cancelled where !seenCancelled.insert(id).inserted {
            duplicates.insert(id)
        }

        for id in conflicts.sorted() { violations.append(.cancelledAndKept(id)) }
        for id in duplicates.sorted() where !conflicts.contains(id) {
            violations.append(.duplicateInstruction(id))
        }

        for change in reprioritized where change.from == change.to {
            violations.append(.degenerateReprioritization(change.id))
        }

        if resultingInFlightCount > budget.prefetchDepth {
            violations.append(
                .overAdmitted(count: resultingInFlightCount, limit: budget.prefetchDepth)
            )
        }

        // Only `admitted` consumes fresh decode budget; retained work already
        // holds its bytes and re-charging it would double-count.
        var admittedBytes = 0
        for item in admitted {
            admittedBytes = Saturating.adding(admittedBytes, item.estimatedDecodeBytes)
        }
        let overshoots = admittedBytes > budget.decodeByteBudget
        // The reconciler's exemption is for the item at the *head* of admission
        // order. Anything retained or reprioritized was admitted ahead of this
        // item and has already spent budget, so a lone oversized item behind it
        // is not a head item and is not excused.
        let excusedAsHeadItem = allowOversizedHeadItem
            && admitted.count <= 1
            && retained.isEmpty
            && reprioritized.isEmpty
        if overshoots && !excusedAsHeadItem {
            violations.append(
                .overDecodeBudget(bytes: admittedBytes, limit: budget.decodeByteBudget)
            )
        }

        // Completeness. Only checkable against the pre-transition in-flight set.
        if let inFlight {
            let keptSet = Set(retained).union(reprioritized.map(\.id))
            for id in inFlight.subtracting(keptSet).subtracting(cancelledSet).sorted() {
                violations.append(.leaked(id))
            }
            for id in cancelledSet.subtracting(inFlight).sorted() {
                violations.append(.phantomCancellation(id))
            }
            for id in keptSet.subtracting(inFlight).sorted() {
                violations.append(.keptButNotRunning(id))
            }
        }

        return violations
    }
}
