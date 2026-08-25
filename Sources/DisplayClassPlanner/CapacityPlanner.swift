//
//  CapacityPlanner.swift
//  DisplayClassPlanner
//

/// What a viewport observation resulted in.
public enum PlanOutcome: Sendable, Hashable {
    /// Same display class, same budget. Nothing to do.
    case unchanged

    /// A contraction is waiting out its hysteresis hold. Schedule a
    /// ``CapacityPlanner/tick(desired:at:)`` for `deadline`.
    case held(until: UInt64)

    /// A pending change was withdrawn because the surface reverted before its
    /// deadline. **No request was cancelled.** The associated transition is
    /// non-`nil` only when the reverted surface came back at different
    /// dimensions and the budget genuinely moved.
    case withdrawn(replan: PlanTransition?)

    /// A new generation was established. Apply the transition.
    case replanned(PlanTransition)

    /// The transition, if this outcome produced one.
    public var transition: PlanTransition? {
        switch self {
        case .unchanged, .held: return nil
        case .withdrawn(let replan): return replan
        case .replanned(let transition): return transition
        }
    }
}

/// What to do with a response that has just landed.
public enum CompletionVerdict: Sendable, Hashable {
    /// Still wanted, and issued under the current generation.
    case accepted

    /// Still wanted. Issued under an older generation, but the item's current
    /// admission is no newer than the request, so this really is that request's
    /// response arriving late.
    case acceptedStale

    /// **The storm payoff.** This request was issued, cancelled by a re-plan,
    /// and the same id was admitted again before the original response landed.
    /// The payload satisfies the new admission: keep it, and do not issue the
    /// duplicate request the naive implementation would.
    case salvaged(originalGeneration: UInt64, currentAdmission: UInt64)

    /// Cancelled and never re-admitted. Drop the payload.
    case discarded
}

/// Something the planner did, for diagnostics and for the demo UI.
public struct PlannerEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case replanned
        case held
        case withdrawn
        case salvaged
        case discarded
    }

    public let generation: UInt64
    public let kind: Kind
    public let detail: String

    public init(generation: UInt64, kind: Kind, detail: String) {
        self.generation = generation
        self.kind = kind
        self.detail = detail
    }
}

/// A consistent read of the planner's state, taken inside the actor.
///
/// Returned as one value rather than exposed as a dozen `async` properties.
/// Reading six properties one at a time is six suspension points, and the
/// values a caller assembles that way need never have been true simultaneously
/// — which is exactly how a debug overlay ends up showing a generation that
/// does not match the in-flight set beside it.
public struct PlannerSnapshot: Sendable, Hashable {
    public let generation: UInt64
    public let committed: Viewport
    public let budget: CapacityBudget
    public let pendingDeadline: UInt64?
    public let inFlight: [WorkID: WorkPriority]
    public let withdrawnStorms: Int
    public let salvagedResponses: Int
    public let cancelledTotal: Int
    public let admittedTotal: Int
    public let events: [PlannerEvent]

    public init(
        generation: UInt64,
        committed: Viewport,
        budget: CapacityBudget,
        pendingDeadline: UInt64?,
        inFlight: [WorkID: WorkPriority],
        withdrawnStorms: Int,
        salvagedResponses: Int,
        cancelledTotal: Int,
        admittedTotal: Int,
        events: [PlannerEvent]
    ) {
        self.generation = generation
        self.committed = committed
        self.budget = budget
        self.pendingDeadline = pendingDeadline
        self.inFlight = inFlight
        self.withdrawnStorms = withdrawnStorms
        self.salvagedResponses = salvagedResponses
        self.cancelledTotal = cancelledTotal
        self.admittedTotal = admittedTotal
        self.events = events
    }

    /// The state of a planner that has never been driven. Lets a UI render a
    /// real (if empty) layout on its first frame instead of a spinner.
    public static let empty = PlannerSnapshot(
        generation: 0,
        committed: .zero,
        budget: .empty,
        pendingDeadline: nil,
        inFlight: [:],
        withdrawnStorms: 0,
        salvagedResponses: 0,
        cancelledTotal: 0,
        admittedTotal: 0,
        events: []
    )
}

/// Owns the display-class lifecycle: hysteresis, generation fencing, and the
/// in-flight table.
///
/// **Reentrancy.** Every mutating method on this actor is synchronous — there
/// is no `await` anywhere inside the actor's own body. That is deliberate and
/// load-bearing: an actor method that suspends can be interleaved with another
/// call to the same actor, so a `read → await → write` sequence here would let
/// a second fold event observe a half-applied plan and produce a transition
/// diffed against state that no longer exists. All I/O — issuing requests,
/// cancelling them — belongs to the caller, which receives a `PlanTransition`
/// value and performs the awaiting outside. The actor computes; the caller
/// suspends.
public actor CapacityPlanner {

    /// Upper bound on the retained event log. The planner runs for the lifetime
    /// of a surface and a fold storm can emit dozens of events a second, so the
    /// log is a ring, not an array that grows.
    public static let maxEventLogSize = 64

    private let budgetPolicy: any BudgetPolicy
    private let reconciler: PlanReconciler

    private struct InFlightRecord: Sendable, Hashable {
        var priority: WorkPriority
        var admittedGeneration: UInt64
    }

    private var debouncer: TransitionDebouncer
    private var inFlight: [WorkID: InFlightRecord] = [:]
    private var generation: UInt64 = 0
    private var committedBudget: CapacityBudget = .empty
    private var events: [PlannerEvent] = []

    private var salvagedResponses = 0
    private var cancelledTotal = 0
    private var admittedTotal = 0

    public init(
        viewport: Viewport = .zero,
        budgetPolicy: any BudgetPolicy = AreaProportionalBudgetPolicy(),
        reconciler: PlanReconciler = PlanReconciler(),
        debouncePolicy: TransitionDebouncer.Policy = .default
    ) {
        self.budgetPolicy = budgetPolicy
        self.reconciler = reconciler
        self.debouncer = TransitionDebouncer(committed: viewport, policy: debouncePolicy)
        // Deliberately `.empty`, not `budgetPolicy.budget(for: viewport)`.
        // A planner that has never planned has no budget, so the first `apply`
        // — even at the very viewport it was constructed with — sees a budget
        // change and seeds a real plan. Pre-computing the budget here would
        // make that first call a no-op and leave the surface empty until
        // something happened to resize it.
        self.committedBudget = .empty
    }

    // MARK: - Driving the planner

    /// Feeds a viewport observation in and returns what the caller must do.
    ///
    /// - Parameters:
    ///   - viewport: the measured surface.
    ///   - desired: every unit of work the surface would like at this size,
    ///     regardless of budget. The planner decides what fits.
    ///   - now: monotonic nanoseconds.
    public func apply(
        viewport: Viewport,
        desired: [WorkItem],
        at now: UInt64
    ) -> PlanOutcome {
        switch debouncer.observe(viewport, at: now) {
        case .ignore:
            return replanIfBudgetMoved(desired: desired)

        case .withdrawn:
            record(.withdrawn, detail: "storm reverted before deadline; 0 cancelled")
            let replan = replanIfBudgetMoved(desired: desired).transition
            return .withdrawn(replan: replan)

        case .applyNow(let committed):
            return .replanned(commit(viewport: committed, desired: desired))

        case .hold(_, let deadline):
            record(.held, detail: "contraction held until \(deadline)")
            return .held(until: deadline)
        }
    }

    /// Commits a pending change whose hysteresis hold has elapsed.
    ///
    /// - Returns: the transition to apply, or `nil` if nothing was due.
    public func tick(desired: [WorkItem], at now: UInt64) -> PlanTransition? {
        guard let committed = debouncer.tick(at: now) else { return nil }
        return commit(viewport: committed, desired: desired)
    }

    /// Reports a completed unit of work.
    ///
    /// - Parameter generation: the generation the request was issued under —
    ///   `PlanTransition.generation` from the transition that admitted it.
    public func complete(_ id: WorkID, generation completionGeneration: UInt64) -> CompletionVerdict {
        guard let entry = inFlight[id] else {
            record(.discarded, detail: "\(id) completed after cancellation")
            return .discarded
        }
        inFlight.removeValue(forKey: id)

        if completionGeneration < entry.admittedGeneration {
            salvagedResponses = Saturating.adding(salvagedResponses, 1)
            record(
                .salvaged,
                detail: "\(id) issued at gen \(completionGeneration), re-admitted at gen \(entry.admittedGeneration)"
            )
            return .salvaged(
                originalGeneration: completionGeneration,
                currentAdmission: entry.admittedGeneration
            )
        }

        return completionGeneration == generation ? .accepted : .acceptedStale
    }

    // MARK: - Reading state

    public func snapshot() -> PlannerSnapshot {
        PlannerSnapshot(
            generation: generation,
            committed: debouncer.committed,
            budget: committedBudget,
            pendingDeadline: debouncer.nextDeadline,
            inFlight: inFlight.mapValues(\.priority),
            withdrawnStorms: debouncer.withdrawnCount,
            salvagedResponses: salvagedResponses,
            cancelledTotal: cancelledTotal,
            admittedTotal: admittedTotal,
            events: events
        )
    }

    // MARK: - Internals

    private func replanIfBudgetMoved(desired: [WorkItem]) -> PlanOutcome {
        let committed = debouncer.committed
        let budget = budgetPolicy.budget(for: committed)
        // Re-planning is driven by a *budget* change, not by an observation.
        // A drag emits size changes at display refresh rate; most of them do
        // not move any of the three budget numbers, and bumping the generation
        // for each one would invalidate every in-flight response for nothing.
        guard budget != committedBudget else { return .unchanged }
        return .replanned(commit(viewport: committed, desired: desired))
    }

    private func commit(viewport: Viewport, desired: [WorkItem]) -> PlanTransition {
        generation = Saturating.adding(generation, 1)
        let budget = budgetPolicy.budget(for: viewport)

        let transition = reconciler.reconcile(
            inFlight: inFlight.mapValues(\.priority),
            desired: desired,
            viewport: viewport,
            budget: budget,
            generation: generation
        )

        for id in transition.cancelled {
            inFlight.removeValue(forKey: id)
        }
        for change in transition.reprioritized {
            // `reconcile` only emits a reprioritization for an id it found in
            // `inFlight`, so the lookup succeeds. `guard` rather than `!` so a
            // future change to the reconciler degrades into a dropped update
            // instead of a crash.
            guard var entry = inFlight[change.id] else { continue }
            entry.priority = change.to
            inFlight[change.id] = entry
        }
        for item in transition.admitted {
            inFlight[item.id] = InFlightRecord(
                priority: item.priority,
                admittedGeneration: generation
            )
        }

        committedBudget = budget
        cancelledTotal = Saturating.adding(cancelledTotal, transition.cancelled.count)
        admittedTotal = Saturating.adding(admittedTotal, transition.admitted.count)

        record(
            .replanned,
            detail: "\(viewport.displayClass) "
                + "keep:\(transition.retained.count) "
                + "repri:\(transition.reprioritized.count) "
                + "cancel:\(transition.cancelled.count) "
                + "admit:\(transition.admitted.count)"
        )
        return transition
    }

    private func record(_ kind: PlannerEvent.Kind, detail: String) {
        events.append(PlannerEvent(generation: generation, kind: kind, detail: detail))
        // Bounded ring. `count > max` rather than `>=` so the log settles at
        // exactly `maxEventLogSize` entries.
        while events.count > CapacityPlanner.maxEventLogSize {
            events.removeFirst()
        }
    }
}
