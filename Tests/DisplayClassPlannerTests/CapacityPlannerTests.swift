import XCTest
@testable import DisplayClassPlanner

/// A budget that depends only on the display class, so every expectation in
/// this file is a number written by hand rather than one the policy computed.
private struct FixedBudgetPolicy: BudgetPolicy {
    let compact: CapacityBudget
    let regular: CapacityBudget
    let expansive: CapacityBudget

    func budget(for viewport: Viewport) -> CapacityBudget {
        switch viewport.displayClass {
        case .compact: return compact
        case .regular: return regular
        case .expansive: return expansive
        }
    }
}

final class CapacityPlannerTests: XCTestCase {

    private let compact = Viewport(width: 400, height: 800, columnCount: 1, scale: 3)
    private let regular = Viewport(width: 760, height: 820, columnCount: 2, scale: 3)
    private let hold: UInt64 = 400_000_000

    private let policy = FixedBudgetPolicy(
        compact: CapacityBudget(prefetchDepth: 2, concurrencyLimit: 2, decodeByteBudget: 10_000),
        regular: CapacityBudget(prefetchDepth: 5, concurrencyLimit: 4, decodeByteBudget: 10_000),
        expansive: CapacityBudget(prefetchDepth: 6, concurrencyLimit: 6, decodeByteBudget: 10_000)
    )

    /// Six items: 0-1 visible, 2-3 adjacent, 4-5 speculative. 100 bytes each,
    /// so `prefetchDepth` is always the binding constraint.
    private var catalog: [WorkItem] {
        (0..<6).map { index in
            let priority: WorkPriority
            switch index {
            case 0, 1: priority = .visible
            case 2, 3: priority = .adjacent
            default: priority = .speculative
            }
            return WorkItem(
                id: WorkID("asset-\(index)"),
                priority: priority,
                index: index,
                estimatedDecodeBytes: 100
            )
        }
    }

    private func makePlanner(at viewport: Viewport) -> CapacityPlanner {
        CapacityPlanner(viewport: viewport, budgetPolicy: policy)
    }

    // MARK: - Seeding

    func testFirstApplySeedsAPlanEvenAtTheConstructionViewport() async {
        // A planner that has never planned has no budget, so this must not be
        // a no-op — otherwise the surface renders empty until something
        // resizes it.
        let planner = makePlanner(at: compact)
        let outcome = await planner.apply(viewport: compact, desired: catalog, at: 0)
        guard case .replanned(let transition) = outcome else {
            return XCTFail("expected a seeded plan, got \(outcome)")
        }
        XCTAssertEqual(transition.generation, 1)
        XCTAssertEqual(transition.admitted.map(\.id.rawValue), ["asset-0", "asset-1"])
        XCTAssertTrue(transition.retained.isEmpty)
        XCTAssertTrue(transition.cancelled.isEmpty)

        let snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.inFlight.count, 2)
        XCTAssertEqual(snapshot.generation, 1)
    }

    func testASecondIdenticalApplyIsANoOp() async {
        let planner = makePlanner(at: compact)
        _ = await planner.apply(viewport: compact, desired: catalog, at: 0)
        let second = await planner.apply(viewport: compact, desired: catalog, at: 1_000)
        XCTAssertEqual(second, .unchanged)
        // Crucially, the generation did NOT move: bumping it on every
        // observation would invalidate every in-flight response for nothing.
        let snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.generation, 1)
    }

    // MARK: - Expansion and contraction

    func testExpansionAdmitsWithoutDisturbingWhatIsAlreadyRunning() async {
        let planner = makePlanner(at: compact)
        _ = await planner.apply(viewport: compact, desired: catalog, at: 0)

        let outcome = await planner.apply(viewport: regular, desired: catalog, at: 1_000)
        guard case .replanned(let transition) = outcome else {
            return XCTFail("expected a replan, got \(outcome)")
        }
        XCTAssertEqual(transition.generation, 2)
        // The two already-running items keep running. This is the property:
        // an expansion must not cancel and re-issue what it already has.
        XCTAssertEqual(transition.retained.map(\.rawValue), ["asset-0", "asset-1"])
        XCTAssertEqual(
            transition.admitted.map(\.id.rawValue),
            ["asset-2", "asset-3", "asset-4"]
        )
        XCTAssertTrue(transition.cancelled.isEmpty)
        XCTAssertTrue(transition.validate().isEmpty)
    }

    func testContractionIsHeldAndOnlyCommitsAfterTheDeadline() async {
        let planner = makePlanner(at: regular)
        _ = await planner.apply(viewport: regular, desired: catalog, at: 0)

        let held = await planner.apply(viewport: compact, desired: catalog, at: 1_000)
        XCTAssertEqual(held, .held(until: 1_000 + hold))
        // Nothing cancelled yet.
        var snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.inFlight.count, 5)
        XCTAssertEqual(snapshot.cancelledTotal, 0)

        let tooEarly = await planner.tick(desired: catalog, at: 1_000 + hold - 1)
        XCTAssertNil(tooEarly)

        guard let committed = await planner.tick(desired: catalog, at: 1_000 + hold) else {
            return XCTFail("expected the hold to elapse")
        }
        XCTAssertEqual(committed.cancelled.count, 3)
        XCTAssertEqual(committed.retained.map(\.rawValue), ["asset-0", "asset-1"])
        snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.inFlight.count, 2)
        XCTAssertEqual(snapshot.cancelledTotal, 3)
    }

    func testAFoldStormCancelsNothing() async {
        let planner = makePlanner(at: regular)
        _ = await planner.apply(viewport: regular, desired: catalog, at: 0)

        // Contract, then revert before the hold elapses. Five times.
        var clock: UInt64 = 1_000
        for _ in 0..<5 {
            _ = await planner.apply(viewport: compact, desired: catalog, at: clock)
            clock += 100_000_000
            let reverted = await planner.apply(viewport: regular, desired: catalog, at: clock)
            guard case .withdrawn = reverted else {
                return XCTFail("expected the storm to be withdrawn, got \(reverted)")
            }
            clock += 100_000_000
        }

        let snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.withdrawnStorms, 5)
        // The whole point: a planner without hysteresis would have cancelled
        // and re-requested the speculative tail five times over.
        XCTAssertEqual(snapshot.cancelledTotal, 0)
        XCTAssertEqual(snapshot.inFlight.count, 5)
        XCTAssertEqual(snapshot.generation, 1)
    }

    // MARK: - Generation fencing

    func testCompletionAtTheCurrentGenerationIsAccepted() async {
        let planner = makePlanner(at: compact)
        _ = await planner.apply(viewport: compact, desired: catalog, at: 0)
        let verdict = await planner.complete(WorkID("asset-0"), generation: 1)
        XCTAssertEqual(verdict, .accepted)
        let snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.inFlight.count, 1)
    }

    func testALateCompletionForStillWantedWorkIsKeptNotRefetched() async {
        let planner = makePlanner(at: compact)
        _ = await planner.apply(viewport: compact, desired: catalog, at: 0)
        // Expand: asset-0 is retained, so its admission generation stays at 1
        // while the planner moves to generation 2.
        _ = await planner.apply(viewport: regular, desired: catalog, at: 1_000)
        let verdict = await planner.complete(WorkID("asset-0"), generation: 1)
        XCTAssertEqual(verdict, .acceptedStale)
    }

    func testCompletionForCancelledWorkIsDiscarded() async {
        let planner = makePlanner(at: regular)
        _ = await planner.apply(viewport: regular, desired: catalog, at: 0)
        _ = await planner.apply(viewport: compact, desired: catalog, at: 1_000)
        guard let contraction = await planner.tick(desired: catalog, at: 1_000 + hold) else {
            return XCTFail("expected the hold to elapse")
        }
        guard let dropped = contraction.cancelled.first else {
            return XCTFail("expected the contraction to cancel something")
        }
        let verdict = await planner.complete(dropped, generation: 1)
        XCTAssertEqual(verdict, .discarded)
    }

    func testAResponseIssuedBeforeACancelIsSalvagedWhenTheIdIsReadmitted() async {
        // The storm payoff, end to end:
        //   gen 1  expand   -> asset-4 admitted, request issued
        //   gen 2  contract -> asset-4 cancelled
        //   gen 3  expand   -> asset-4 admitted again
        //   the gen-1 response finally lands
        // A naive planner drops that payload and issues the same request a
        // second time. This one keeps it.
        let planner = makePlanner(at: regular)
        _ = await planner.apply(viewport: regular, desired: catalog, at: 0)
        let victim = WorkID("asset-4")

        _ = await planner.apply(viewport: compact, desired: catalog, at: 1_000)
        guard let contraction = await planner.tick(desired: catalog, at: 1_000 + hold) else {
            return XCTFail("expected the hold to elapse")
        }
        XCTAssertTrue(contraction.cancelled.contains(victim))

        let reexpand = await planner.apply(
            viewport: regular, desired: catalog, at: 2_000 + hold
        )
        guard case .replanned(let readmission) = reexpand else {
            return XCTFail("expected a replan, got \(reexpand)")
        }
        XCTAssertTrue(readmission.admitted.contains { $0.id == victim })

        let verdict = await planner.complete(victim, generation: 1)
        XCTAssertEqual(verdict, .salvaged(originalGeneration: 1, currentAdmission: 3))

        let snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.salvagedResponses, 1)
    }

    func testCompletingAnIdThatWasNeverAdmittedIsDiscarded() async {
        let planner = makePlanner(at: compact)
        _ = await planner.apply(viewport: compact, desired: catalog, at: 0)
        let verdict = await planner.complete(WorkID("never-seen"), generation: 1)
        XCTAssertEqual(verdict, .discarded)
    }

    func testCompletingTheSameIdTwiceDoesNotDoubleCount() async {
        let planner = makePlanner(at: compact)
        _ = await planner.apply(viewport: compact, desired: catalog, at: 0)
        let first = await planner.complete(WorkID("asset-0"), generation: 1)
        XCTAssertEqual(first, .accepted)
        // Second delivery of the same response: the id is gone from the table.
        let second = await planner.complete(WorkID("asset-0"), generation: 1)
        XCTAssertEqual(second, .discarded)
        let snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.inFlight.count, 1)
    }

    // MARK: - Abandoning work that will never deliver

    func testAbandonFreesTheSlotSoTheIdCanBeAdmittedAgain() async {
        // Without `abandon`, a request that errors out sits in the in-flight
        // table forever: every later reconcile finds it running and buckets it
        // as `retained`, so it is never cancelled and never re-issued. This is
        // the leak the package exists to prevent, reached via the happy path.
        let planner = makePlanner(at: compact)
        _ = await planner.apply(viewport: compact, desired: catalog, at: 0)
        let dead = WorkID("asset-0")

        let freed = await planner.abandon(dead)
        XCTAssertTrue(freed)
        var snapshot = await planner.snapshot()
        XCTAssertFalse(snapshot.inFlight.keys.contains(dead))

        // The next re-plan must offer it again rather than assume it running.
        _ = await planner.apply(viewport: regular, desired: catalog, at: 1_000)
        snapshot = await planner.snapshot()
        XCTAssertTrue(
            snapshot.inFlight.keys.contains(dead),
            "an abandoned id must become eligible for admission again"
        )
    }

    func testAbandoningSomethingNotInFlightReportsFalseAndChangesNothing() async {
        let planner = makePlanner(at: compact)
        _ = await planner.apply(viewport: compact, desired: catalog, at: 0)
        let before = await planner.snapshot()
        let freed = await planner.abandon(WorkID("never-started"))
        XCTAssertFalse(freed)
        let after = await planner.snapshot()
        XCTAssertEqual(before.inFlight, after.inFlight)
    }

    // MARK: - The pending viewport is reachable during a hold

    func testPendingViewportIsExposedWhileAContractionIsHeld() async {
        // `tick(desired:)` asks the caller for the work it wants — and during a
        // hold the right answer is "what the PENDING surface wants". A caller
        // that cannot see the pending viewport plans the contraction against
        // the pre-contraction one and gets the priorities wrong.
        let planner = makePlanner(at: regular)
        _ = await planner.apply(viewport: regular, desired: catalog, at: 0)
        let seeded = await planner.snapshot()
        XCTAssertNil(seeded.pendingViewport)

        _ = await planner.apply(viewport: compact, desired: catalog, at: 1_000)
        let held = await planner.snapshot()
        XCTAssertEqual(held.pendingViewport, compact)
        XCTAssertEqual(held.committed, regular, "committed must not move during a hold")
        XCTAssertEqual(held.pendingDeadline, 1_000 + hold)

        _ = await planner.tick(desired: catalog, at: 1_000 + hold)
        let settled = await planner.snapshot()
        XCTAssertNil(settled.pendingViewport)
        XCTAssertEqual(settled.committed, compact)
    }

    // MARK: - Bounds

    func testEventLogIsABoundedRing() async {
        let planner = makePlanner(at: compact)
        var clock: UInt64 = 0
        // Alternate expansions and immediate-committed contractions to generate
        // far more events than the ring can hold.
        for _ in 0..<200 {
            _ = await planner.apply(viewport: regular, desired: catalog, at: clock)
            clock += 1_000
            _ = await planner.apply(viewport: compact, desired: catalog, at: clock)
            clock += hold
            _ = await planner.tick(desired: catalog, at: clock)
            clock += 1_000
        }
        let snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.events.count, CapacityPlanner.maxEventLogSize)
    }

    func testInFlightNeverExceedsThePrefetchDepth() async {
        let tiny = FixedBudgetPolicy(
            compact: CapacityBudget(prefetchDepth: 1, concurrencyLimit: 1, decodeByteBudget: 10_000),
            regular: CapacityBudget(prefetchDepth: 3, concurrencyLimit: 2, decodeByteBudget: 10_000),
            expansive: CapacityBudget(prefetchDepth: 3, concurrencyLimit: 2, decodeByteBudget: 10_000)
        )
        let planner = CapacityPlanner(viewport: regular, budgetPolicy: tiny)
        // A catalogue far larger than any budget.
        let large = (0..<500).map { index in
            WorkItem(
                id: WorkID("asset-\(index)"),
                priority: .visible,
                index: index,
                estimatedDecodeBytes: 1
            )
        }
        _ = await planner.apply(viewport: regular, desired: large, at: 0)
        let snapshot = await planner.snapshot()
        XCTAssertEqual(snapshot.inFlight.count, 3)
    }

    // MARK: - Concurrency

    func testConcurrentCommitsGetUniqueContiguousGenerations() async {
        // 120 real concurrent writers against one actor.
        //
        // The assertion is deliberately NOT a bound the implementation
        // satisfies by construction. Every commit — from `apply` or from
        // `tick`, on any task — must receive its own generation, and the set of
        // generations handed out must be exactly `1...n` with no gaps and no
        // duplicates. A duplicate means two commits observed the same
        // pre-state and one of them diffed against a plan that no longer
        // existed; a gap means a generation was burned without producing a
        // transition. Both are the reentrancy bug this actor's
        // no-suspension-point design exists to rule out, and neither is
        // detectable from a subset/count check.
        let planner = makePlanner(at: compact)
        let items = catalog
        let compactViewport = compact
        let regularViewport = regular

        let observed = await withTaskGroup(of: [UInt64].self) { group -> [UInt64] in
            for iteration in 0..<120 {
                group.addTask {
                    var generations: [UInt64] = []
                    let clock = UInt64(iteration) * 10_000_000
                    if iteration.isMultiple(of: 3) {
                        let outcome = await planner.apply(
                            viewport: regularViewport, desired: items, at: clock
                        )
                        if let t = outcome.transition { generations.append(t.generation) }
                    } else if iteration.isMultiple(of: 2) {
                        let outcome = await planner.apply(
                            viewport: compactViewport, desired: items, at: clock
                        )
                        if let t = outcome.transition { generations.append(t.generation) }
                    } else {
                        _ = await planner.complete(
                            WorkID("asset-\(iteration % 6)"), generation: UInt64(iteration % 4)
                        )
                    }
                    if let t = await planner.tick(desired: items, at: clock) {
                        generations.append(t.generation)
                    }
                    return generations
                }
            }
            var all: [UInt64] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }

        let snapshot = await planner.snapshot()

        // `guard` rather than `XCTAssertFalse`: an empty result would make the
        // range below invalid, and a test that traps is not a failing test.
        guard !observed.isEmpty else {
            return XCTFail("no commit happened at all — the test proved nothing")
        }
        XCTAssertEqual(
            Set(observed).count, observed.count,
            "two commits shared a generation: \(observed.sorted())"
        )
        XCTAssertEqual(
            observed.sorted(), Array(1...UInt64(observed.count)),
            "generations were not contiguous from 1: \(observed.sorted())"
        )
        // The actor's own counter must agree with what the callers were told.
        XCTAssertEqual(snapshot.generation, UInt64(observed.count))

        // And the structural bounds still hold.
        let catalogIDs = Set(items.map(\.id))
        XCTAssertTrue(Set(snapshot.inFlight.keys).isSubset(of: catalogIDs))
        XCTAssertLessThanOrEqual(snapshot.inFlight.count, 5)
        XCTAssertLessThanOrEqual(snapshot.events.count, CapacityPlanner.maxEventLogSize)
    }
}
