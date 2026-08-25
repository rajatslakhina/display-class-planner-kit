//
//  PlanReconciler.swift
//  DisplayClassPlanner
//

/// Turns "what is running" plus "what we now want" into a minimal set of
/// instructions.
///
/// Pure, synchronous, and deliberately not an actor. Everything that makes this
/// hard is arithmetic and set logic; making it concurrent would only add
/// suspension points to a computation that has no I/O in it, and would make the
/// property tests non-deterministic for no benefit.
public struct PlanReconciler: Sendable {

    public struct Policy: Sendable, Hashable {
        /// Admit the single highest-priority item even when it alone exceeds
        /// the decode budget.
        ///
        /// **The trade-off.** With this off, a surface whose first visible cell
        /// happens to be a very large asset renders permanently blank — the
        /// admission loop skips it every pass and nothing behind it fills the
        /// hole either, because the loop is priority-ordered. With it on, the
        /// decode budget can be overshot by exactly one item. Overshooting a
        /// soft memory budget by one asset is recoverable; a permanently blank
        /// hero cell is a bug report. Off is still offered because a surface
        /// under real memory pressure may prefer the blank.
        public var admitsOversizedHeadItem: Bool

        /// Stop the admission scan at the first item that does not fit, rather
        /// than continuing to look for smaller items further down.
        ///
        /// **The trade-off.** Continuing (`false`) packs the budget tighter but
        /// admits low-priority work ahead of high-priority work that merely
        /// happened to be large, which inverts the priority order the caller
        /// asked for. Stopping (`true`) preserves the order at the cost of some
        /// unused budget. Order is the property callers actually reason about,
        /// so it is the default.
        public var stopsAtFirstOverflow: Bool

        public init(admitsOversizedHeadItem: Bool = true, stopsAtFirstOverflow: Bool = true) {
            self.admitsOversizedHeadItem = admitsOversizedHeadItem
            self.stopsAtFirstOverflow = stopsAtFirstOverflow
        }

        public static let `default` = Policy()
    }

    public let policy: Policy

    public init(policy: Policy = .default) {
        self.policy = policy
    }

    /// The subset of `desired` that fits inside `budget`, in admission order.
    ///
    /// Deterministic for any input: the sort is a total order (priority, then
    /// index, then id), so two callers that build the same set of items in a
    /// different sequence get byte-identical output.
    public func admissibleSet(
        from desired: [WorkItem],
        budget: CapacityBudget
    ) -> [WorkItem] {
        guard budget.prefetchDepth > 0, !desired.isEmpty else { return [] }

        // De-duplicate by id before admitting. A caller assembling `desired`
        // from several sections can legitimately produce the same asset twice;
        // admitting both would let one logical request occupy two slots and
        // would make the "no duplicate instruction" invariant unsatisfiable.
        var byID: [WorkID: WorkItem] = [:]
        byID.reserveCapacity(desired.count)
        for item in desired {
            if let existing = byID[item.id] {
                // Keep the more urgent copy; ties resolve by admission order so
                // the choice does not depend on input sequence.
                if WorkItem.admissionOrder(item, existing) { byID[item.id] = item }
            } else {
                byID[item.id] = item
            }
        }

        let ordered = byID.values.sorted(by: WorkItem.admissionOrder)

        var admitted: [WorkItem] = []
        admitted.reserveCapacity(Swift.min(ordered.count, budget.prefetchDepth))
        var spentBytes = 0

        for item in ordered {
            if admitted.count >= budget.prefetchDepth { break }

            let projected = Saturating.adding(spentBytes, item.estimatedDecodeBytes)
            let fits = projected <= budget.decodeByteBudget

            if fits {
                admitted.append(item)
                spentBytes = projected
                continue
            }

            // Does not fit. The head item gets the documented exemption.
            let isHeadItem = admitted.isEmpty
            if isHeadItem && policy.admitsOversizedHeadItem {
                admitted.append(item)
                spentBytes = projected
                continue
            }

            if policy.stopsAtFirstOverflow { break }
            // Otherwise: skip this one and keep scanning for something smaller.
        }

        return admitted
    }

    /// Diffs `inFlight` against the admissible set for `viewport`.
    ///
    /// - Parameters:
    ///   - inFlight: what the caller currently has running, and at what
    ///     priority. Keyed by id, so ordering of the caller's own bookkeeping
    ///     cannot leak into the output.
    ///   - desired: every unit of work the surface would like, at any priority.
    ///     May be larger than the budget; that is the point.
    ///   - generation: the generation number this transition establishes.
    public func reconcile(
        inFlight: [WorkID: WorkPriority],
        desired: [WorkItem],
        viewport: Viewport,
        budget: CapacityBudget,
        generation: UInt64
    ) -> PlanTransition {
        let admissible = admissibleSet(from: desired, budget: budget)
        var admissibleByID: [WorkID: WorkItem] = [:]
        admissibleByID.reserveCapacity(admissible.count)
        for item in admissible { admissibleByID[item.id] = item }

        var retained: [WorkID] = []
        var reprioritized: [PlanTransition.Reprioritization] = []
        var admitted: [WorkItem] = []

        // Walk the admissible set in admission order so the three output
        // arrays are ordered by urgency — a caller feeding a priority queue can
        // enqueue them directly without re-sorting.
        for item in admissible {
            guard let runningPriority = inFlight[item.id] else {
                admitted.append(item)
                continue
            }
            if runningPriority == item.priority {
                retained.append(item.id)
            } else {
                reprioritized.append(
                    .init(id: item.id, from: runningPriority, to: item.priority)
                )
            }
        }

        // Anything running that the new plan does not want.
        // Sorted, because `Dictionary.keys` has no defined order and a
        // non-deterministic cancel list makes replay tests useless.
        let cancelled = inFlight.keys
            .filter { admissibleByID[$0] == nil }
            .sorted()

        return PlanTransition(
            generation: generation,
            budget: budget,
            viewport: viewport,
            retained: retained,
            reprioritized: reprioritized,
            cancelled: cancelled,
            admitted: admitted
        )
    }
}
