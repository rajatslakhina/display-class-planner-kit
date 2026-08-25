//
//  CapacityPlannerViewModel.swift
//  DisplayClassPlannerUI
//

#if canImport(SwiftUI)

import Foundation
import Observation
import DisplayClassPlanner

/// Drives a ``CapacityPlanner`` from a SwiftUI surface.
///
/// **Clock.** The planner takes an explicit `now` on every call, so this view
/// model owns one monotonic accumulator and feeds it in. Real elapsed time is
/// sampled from `DispatchTime.uptimeNanoseconds` and *added* to the
/// accumulator; scripted scenarios add a jump. Time therefore only ever moves
/// forward, whether it is being advanced by the display link or by a button,
/// which is what the debouncer's deadlines assume.
@MainActor
@Observable
public final class CapacityPlannerViewModel {

    public private(set) var snapshot: PlannerSnapshot = .empty
    public private(set) var lastTransition: PlanTransition?
    public private(set) var activityLine: String = "Idle — pick a surface below."
    public private(set) var selectedStageID: String
    public private(set) var isRunningScenario = false

    public let configuration: PlannerDemoConfiguration

    private let planner: CapacityPlanner
    private var clock: UInt64 = 0
    private var lastRealSample: UInt64

    public init(configuration: PlannerDemoConfiguration = .default) {
        self.configuration = configuration
        // `stages` is guaranteed non-empty by PlannerDemoConfiguration.init,
        // but `first` is still used rather than `stages[0]` so this file
        // contains no unchecked subscript.
        let initialStage = configuration.stages.first
        self.selectedStageID = initialStage?.id ?? ""
        self.planner = CapacityPlanner(
            viewport: initialStage?.viewport ?? .zero,
            budgetPolicy: configuration.budgetPolicy,
            debouncePolicy: configuration.debouncePolicy
        )
        self.lastRealSample = DispatchTime.now().uptimeNanoseconds
    }

    public var stages: [PlannerDemoConfiguration.Stage] { configuration.stages }

    public var selectedStage: PlannerDemoConfiguration.Stage? {
        configuration.stages.first { $0.id == selectedStageID }
    }

    /// Every catalogue item, tagged with whether the planner currently has it
    /// in flight. This is what the grid renders.
    public var catalogRows: [CatalogRow] {
        let desired = configuration.catalog(snapshot.committed)
        let inFlight = snapshot.inFlight
        return desired.map { item in
            CatalogRow(
                item: item,
                inFlightPriority: inFlight[item.id]
            )
        }
    }

    public struct CatalogRow: Identifiable, Hashable, Sendable {
        public let item: WorkItem
        public let inFlightPriority: WorkPriority?
        public var id: String { item.id.rawValue }
        public var isInFlight: Bool { inFlightPriority != nil }
    }

    // MARK: - Lifecycle

    /// Seeds the first plan and then services hysteresis deadlines.
    ///
    /// Driven from SwiftUI's `.task`, so cancellation is the view's lifetime
    /// and nothing needs to be stored, retained or torn down here.
    public func run() async {
        await seedInitialPlan()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
            await serviceDeadline()
        }
    }

    private func seedInitialPlan() async {
        guard let stage = selectedStage else { return }
        advanceClockToRealTime()
        let outcome = await planner.apply(
            viewport: stage.viewport,
            desired: configuration.catalog(stage.viewport),
            at: clock
        )
        absorb(outcome, context: "Seeded \(stage.title)")
        await refresh()
    }

    private func serviceDeadline() async {
        advanceClockToRealTime()
        let desired = configuration.catalog(snapshot.committed)
        guard let transition = await planner.tick(desired: desired, at: clock) else { return }
        lastTransition = transition
        activityLine = "Hold elapsed — contraction committed. "
            + "\(transition.cancelled.count) cancelled."
        await refresh()
    }

    // MARK: - Actions

    /// Switches to a stage. Expansions apply immediately; contractions enter
    /// the hysteresis hold and only commit if they survive it.
    public func select(stageID: String) async {
        guard !isRunningScenario else { return }
        guard let stage = configuration.stages.first(where: { $0.id == stageID }) else { return }
        selectedStageID = stageID
        advanceClockToRealTime()
        let outcome = await planner.apply(
            viewport: stage.viewport,
            desired: configuration.catalog(stage.viewport),
            at: clock
        )
        absorb(outcome, context: stage.title)
        await refresh()
    }

    /// Contract, then revert before the hold elapses.
    ///
    /// The point of the demo: `cancelledTotal` does not move, and
    /// `withdrawnStorms` does. A planner without hysteresis would cancel the
    /// whole speculative tail here and re-request it a moment later.
    public func runFoldStorm() async {
        guard !isRunningScenario, configuration.stages.count >= 2 else { return }
        guard let small = configuration.stages.first,
              let large = configuration.stages.last else { return }
        isRunningScenario = true
        defer { isRunningScenario = false }

        // Start from the largest surface so the next step is a contraction.
        await drive(large, note: "Storm: expand")
        try? await Task.sleep(nanoseconds: 120_000_000)
        await drive(small, note: "Storm: contract (held)")
        try? await Task.sleep(nanoseconds: 120_000_000)
        await drive(large, note: "Storm: reverted")

        selectedStageID = large.id
        let cancelled = snapshot.cancelledTotal
        activityLine = "Fold storm absorbed. Withdrawn: \(snapshot.withdrawnStorms). "
            + "Requests cancelled by the storm: 0 (lifetime total still \(cancelled))."
        await refresh()
    }

    /// Issue → cancel → re-admit → late response.
    ///
    /// Ends by completing a request under the generation it was *issued* at,
    /// after that id has been cancelled and admitted again, and shows the
    /// planner returning ``CompletionVerdict/salvaged(originalGeneration:currentAdmission:)``
    /// instead of dropping the payload and re-requesting it.
    public func runSalvageScenario() async {
        guard !isRunningScenario, configuration.stages.count >= 2 else { return }
        guard let small = configuration.stages.first,
              let large = configuration.stages.last else { return }
        isRunningScenario = true
        defer { isRunningScenario = false }

        // 1. Expand, so the speculative tail is admitted.
        await drive(large, note: "Salvage: expand")
        await refresh()
        let issuedGeneration = snapshot.generation

        // 2. Contract past the hold so the cancellation genuinely commits, and
        //    take the victim from the transition's real `cancelled` list rather
        //    than predicting which item the budget will drop.
        await drive(small, note: "Salvage: contract")
        clock = Saturating.adding(clock, 1_000_000_000)
        let contraction = await planner.tick(
            desired: configuration.catalog(small.viewport), at: clock
        )
        if let contraction { lastTransition = contraction }

        guard let victim = contraction?.cancelled.first else {
            await drive(large, note: "Salvage: restore")
            selectedStageID = large.id
            activityLine = "Salvage: the contraction cancelled nothing at these "
                + "budgets, so there is no late response to salvage."
            await refresh()
            return
        }

        // 3. Expand again, re-admitting the victim under a newer generation.
        await drive(large, note: "Salvage: re-expand")

        // 4. The original response finally lands.
        let verdict = await planner.complete(victim, generation: issuedGeneration)
        selectedStageID = large.id
        switch verdict {
        case .salvaged(let original, let current):
            activityLine = "\(victim) issued at gen \(original), cancelled, "
                + "re-admitted at gen \(current) — response SALVAGED, not re-requested."
        case .accepted:
            activityLine = "\(victim) accepted at the current generation."
        case .acceptedStale:
            activityLine = "\(victim) accepted late; still wanted, no re-request."
        case .discarded:
            activityLine = "\(victim) was cancelled and never re-admitted — payload discarded."
        }
        await refresh()
    }

    /// Completes the highest-priority in-flight request at the current
    /// generation, so the grid visibly drains.
    public func completeNext() async {
        guard !isRunningScenario else { return }
        let next = snapshot.inFlight
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .first?.key
        guard let next else {
            activityLine = "Nothing in flight."
            return
        }
        let verdict = await planner.complete(next, generation: snapshot.generation)
        activityLine = "Completed \(next): \(describe(verdict))."
        await refresh()
    }

    // MARK: - Helpers

    private func drive(_ stage: PlannerDemoConfiguration.Stage, note: String) async {
        advanceClockToRealTime()
        let outcome = await planner.apply(
            viewport: stage.viewport,
            desired: configuration.catalog(stage.viewport),
            at: clock
        )
        absorb(outcome, context: note)
        await refresh()
    }

    private func absorb(_ outcome: PlanOutcome, context: String) {
        if let transition = outcome.transition { lastTransition = transition }
        switch outcome {
        case .unchanged:
            activityLine = "\(context): same display class, budget unchanged."
        case .held(let deadline):
            activityLine = "\(context): contraction held (deadline \(deadline / 1_000_000) ms)."
        case .withdrawn:
            activityLine = "\(context): pending contraction withdrawn — 0 requests cancelled."
        case .replanned(let transition):
            activityLine = "\(context): gen \(transition.generation) — "
                + "keep \(transition.retained.count), "
                + "repri \(transition.reprioritized.count), "
                + "cancel \(transition.cancelled.count), "
                + "admit \(transition.admitted.count)."
        }
    }

    private func describe(_ verdict: CompletionVerdict) -> String {
        switch verdict {
        case .accepted: return "accepted"
        case .acceptedStale: return "accepted (stale generation, still wanted)"
        case .salvaged(let original, let current):
            return "salvaged (issued gen \(original), re-admitted gen \(current))"
        case .discarded: return "discarded"
        }
    }

    private func refresh() async {
        snapshot = await planner.snapshot()
    }

    private func advanceClockToRealTime() {
        let now = DispatchTime.now().uptimeNanoseconds
        // Subtraction guarded: `uptimeNanoseconds` is monotonic, but this class
        // does not own that guarantee, and an unsigned underflow here would be
        // a trap rather than a glitch.
        let delta = now >= lastRealSample ? now - lastRealSample : 0
        lastRealSample = now
        clock = Saturating.adding(clock, delta)
    }
}

#endif
