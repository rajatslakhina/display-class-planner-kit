import XCTest
@testable import DisplayClassPlanner

final class PlanReconcilerTests: XCTestCase {

    private let reconciler = PlanReconciler()

    private func item(
        _ id: String,
        _ priority: WorkPriority,
        index: Int,
        bytes: Int = 100
    ) -> WorkItem {
        WorkItem(id: WorkID(id), priority: priority, index: index, estimatedDecodeBytes: bytes)
    }

    private func budget(depth: Int, bytes: Int) -> CapacityBudget {
        CapacityBudget(prefetchDepth: depth, concurrencyLimit: 4, decodeByteBudget: bytes)
    }

    private var fixture: [WorkItem] {
        [
            item("a", .speculative, index: 0),
            item("b", .visible, index: 5),
            item("c", .adjacent, index: 2),
            item("d", .visible, index: 1),
        ]
    }

    // MARK: - Admission

    func testAdmissionIsPriorityThenIndexOrdered() {
        let admitted = reconciler.admissibleSet(
            from: fixture, budget: budget(depth: 3, bytes: 1_000)
        )
        // visible by index (d=1 then b=5), then adjacent (c), then speculative.
        // Depth 3 cuts "a".
        XCTAssertEqual(admitted.map(\.id.rawValue), ["d", "b", "c"])
    }

    func testAdmissionDoesNotDependOnInputOrder() {
        // The expectation is a hardcoded literal, not a second call to the same
        // function — comparing two calls would pass even if both were wrong.
        let shuffled: [WorkItem] = [
            item("c", .adjacent, index: 2),
            item("a", .speculative, index: 0),
            item("d", .visible, index: 1),
            item("b", .visible, index: 5),
        ]
        let admitted = reconciler.admissibleSet(
            from: shuffled, budget: budget(depth: 3, bytes: 1_000)
        )
        XCTAssertEqual(admitted.map(\.id.rawValue), ["d", "b", "c"])
    }

    func testAdmissionStopsAtTheFirstItemThatDoesNotFit() {
        // Budget fits exactly two 100-byte items.
        let admitted = reconciler.admissibleSet(
            from: fixture, budget: budget(depth: 10, bytes: 250)
        )
        XCTAssertEqual(admitted.map(\.id.rawValue), ["d", "b"])
    }

    func testPackingModeKeepsScanningPastAnItemThatDoesNotFit() {
        let packing = PlanReconciler(
            policy: .init(admitsOversizedHeadItem: true, stopsAtFirstOverflow: false)
        )
        let items = [
            item("d", .visible, index: 1, bytes: 100),
            item("b", .visible, index: 5, bytes: 100),
            item("c", .adjacent, index: 2, bytes: 200),   // 200 + 200 > 250: skipped
            item("a", .speculative, index: 0, bytes: 40), // 200 + 40 = 240: fits
        ]
        let admitted = packing.admissibleSet(from: items, budget: budget(depth: 10, bytes: 250))
        XCTAssertEqual(admitted.map(\.id.rawValue), ["d", "b", "a"])
    }

    func testOversizedHeadItemIsAdmittedSoTheHeroCellIsNeverBlank() {
        let oversized = [item("huge", .visible, index: 0, bytes: 5_000)]
        let admitted = reconciler.admissibleSet(
            from: oversized, budget: budget(depth: 10, bytes: 100)
        )
        XCTAssertEqual(admitted.map(\.id.rawValue), ["huge"])
    }

    func testOversizedHeadItemCanBeRefusedWhenTheCallerPrefersTheBlank() {
        let strict = PlanReconciler(policy: .init(admitsOversizedHeadItem: false))
        let oversized = [item("huge", .visible, index: 0, bytes: 5_000)]
        XCTAssertTrue(
            strict.admissibleSet(from: oversized, budget: budget(depth: 10, bytes: 100)).isEmpty
        )
    }

    func testDuplicateIdsCollapseToTheMoreUrgentCopy() {
        // A caller assembling `desired` from two sections can legitimately
        // produce the same asset twice. Admitting both would make the
        // "no duplicate instruction" invariant unsatisfiable.
        let duplicated = [
            item("x", .speculative, index: 9),
            item("x", .visible, index: 9),
            item("y", .adjacent, index: 1),
        ]
        let admitted = reconciler.admissibleSet(
            from: duplicated, budget: budget(depth: 10, bytes: 10_000)
        )
        XCTAssertEqual(admitted.map(\.id.rawValue), ["x", "y"])
        XCTAssertEqual(admitted.first?.priority, .visible)
    }

    func testZeroDepthBudgetAdmitsNothing() {
        XCTAssertTrue(
            reconciler.admissibleSet(from: fixture, budget: budget(depth: 0, bytes: 10_000)).isEmpty
        )
    }

    func testEmptyDesiredSetAdmitsNothing() {
        XCTAssertTrue(
            reconciler.admissibleSet(from: [], budget: budget(depth: 10, bytes: 10_000)).isEmpty
        )
    }

    func testEnormousEstimatesDoNotOverflowTheRunningTotal() {
        let items = [
            item("p", .visible, index: 0, bytes: Int.max),
            item("q", .visible, index: 1, bytes: Int.max),
        ]
        // The running total would trap on `+` without saturation. Head item is
        // admitted by the documented exemption; the second does not fit.
        let admitted = reconciler.admissibleSet(
            from: items, budget: budget(depth: 10, bytes: 1_000)
        )
        XCTAssertEqual(admitted.map(\.id.rawValue), ["p"])
    }

    func testNegativeByteEstimatesCannotRefundBudgetDuringAdmission() {
        // A negative estimate would let an item hand budget *back* to the
        // admission loop, letting everything behind it in. The clamp lives in
        // WorkItem.init, but the behaviour that matters is in the loop, so this
        // asserts through `admissibleSet` rather than through the initialiser.
        let items = [
            item("a", .visible, index: 0, bytes: 200),
            item("refund", .visible, index: 1, bytes: -10_000), // clamps to 0
            item("b", .visible, index: 2, bytes: 200),
            item("c", .visible, index: 3, bytes: 200),
        ]
        // Budget of 400 fits "a" (200) + "refund" (0) + "b" (400). "c" would
        // reach 600 and is refused. If the -10 000 were honoured, the running
        // total after "refund" would be -9 800 and every item would fit.
        let admitted = reconciler.admissibleSet(
            from: items, budget: budget(depth: 10, bytes: 400)
        )
        XCTAssertEqual(admitted.map(\.id.rawValue), ["a", "refund", "b"])
    }

    // MARK: - Reconciliation

    func testReconcileBucketsEveryIdExactlyOnce() {
        let inFlight: [WorkID: WorkPriority] = [
            WorkID("d"): .visible,        // still wanted, same priority -> retained
            WorkID("c"): .speculative,    // still wanted, new priority  -> reprioritized
            WorkID("x"): .adjacent,       // not wanted at all           -> cancelled
        ]
        let desired = [
            item("d", .visible, index: 1),
            item("b", .visible, index: 5),   // not running -> admitted
            item("c", .adjacent, index: 2),
        ]
        let transition = reconciler.reconcile(
            inFlight: inFlight,
            desired: desired,
            viewport: Viewport(width: 400, height: 400, columnCount: 1),
            budget: budget(depth: 5, bytes: 10_000),
            generation: 7
        )

        XCTAssertEqual(transition.generation, 7)
        XCTAssertEqual(transition.retained.map(\.rawValue), ["d"])
        XCTAssertEqual(transition.admitted.map(\.id.rawValue), ["b"])
        XCTAssertEqual(
            transition.reprioritized,
            [.init(id: WorkID("c"), from: .speculative, to: .adjacent)]
        )
        XCTAssertEqual(transition.cancelled.map(\.rawValue), ["x"])
        XCTAssertEqual(transition.resultingInFlightCount, 3)
        XCTAssertTrue(transition.validate().isEmpty)
    }

    func testAContractionNeverCancelsAndReadmitsTheSameIdentity() {
        // The headline invariant. Start with everything in flight at the large
        // budget, then reconcile against a much smaller one.
        var inFlight: [WorkID: WorkPriority] = [:]
        var desired: [WorkItem] = []
        for index in 0..<40 {
            let workItem = item("asset-\(index)", index < 10 ? .visible : .speculative, index: index)
            desired.append(workItem)
            inFlight[workItem.id] = workItem.priority
        }

        let contracted = reconciler.reconcile(
            inFlight: inFlight,
            desired: desired,
            viewport: Viewport(width: 300, height: 300, columnCount: 1),
            budget: budget(depth: 12, bytes: 10_000),
            generation: 2
        )

        XCTAssertEqual(contracted.retained.count, 12)
        XCTAssertTrue(contracted.admitted.isEmpty, "nothing new should be started by a contraction")
        XCTAssertEqual(contracted.cancelled.count, 28)
        let kept = Set(contracted.retained + contracted.admitted.map(\.id))
        XCTAssertTrue(Set(contracted.cancelled).isDisjoint(with: kept))
        XCTAssertTrue(contracted.validate().isEmpty)
    }

    func testCancelledListIsSortedRatherThanDictionaryOrdered() {
        // `Dictionary.keys` has no defined order; an unsorted cancel list makes
        // replay tests useless and makes a diff between two runs meaningless.
        let inFlight: [WorkID: WorkPriority] = [
            WorkID("zz"): .visible,
            WorkID("aa"): .visible,
            WorkID("mm"): .visible,
        ]
        let transition = reconciler.reconcile(
            inFlight: inFlight,
            desired: [],
            viewport: .zero,
            budget: budget(depth: 5, bytes: 10_000),
            generation: 1
        )
        XCTAssertEqual(transition.cancelled.map(\.rawValue), ["aa", "mm", "zz"])
    }

    func testNoopTransitionIsReportedAsSuch() {
        let inFlight: [WorkID: WorkPriority] = [WorkID("d"): .visible]
        let transition = reconciler.reconcile(
            inFlight: inFlight,
            desired: [item("d", .visible, index: 1)],
            viewport: .zero,
            budget: budget(depth: 5, bytes: 10_000),
            generation: 3
        )
        XCTAssertTrue(transition.isNoop)
        XCTAssertEqual(transition.retained.map(\.rawValue), ["d"])
    }

    func testATransitionThatActuallyChangesSomethingIsNotANoop() {
        // Without this, `isNoop { true }` passes the whole suite.
        let admitting = reconciler.reconcile(
            inFlight: [:],
            desired: [item("d", .visible, index: 1)],
            viewport: .zero,
            budget: budget(depth: 5, bytes: 10_000),
            generation: 4
        )
        XCTAssertFalse(admitting.isNoop, "admitting work is not a no-op")

        let cancelling = reconciler.reconcile(
            inFlight: [WorkID("gone"): .visible],
            desired: [],
            viewport: .zero,
            budget: budget(depth: 5, bytes: 10_000),
            generation: 5
        )
        XCTAssertFalse(cancelling.isNoop, "cancelling work is not a no-op")

        let repriotizing = reconciler.reconcile(
            inFlight: [WorkID("d"): .speculative],
            desired: [item("d", .visible, index: 1)],
            viewport: .zero,
            budget: budget(depth: 5, bytes: 10_000),
            generation: 6
        )
        XCTAssertFalse(repriotizing.isNoop, "a priority change is not a no-op")
    }

    // MARK: - Property test over pseudo-random scenarios

    func testReconcilerNeverProducesAnInvalidTransition() {
        // A deterministic generator, so a failure is reproducible from the seed
        // printed in the assertion message.
        var rng = SplitMix64(seed: 0xD15C_1A55)
        let reconcilers = [
            PlanReconciler(policy: .init(admitsOversizedHeadItem: true, stopsAtFirstOverflow: true)),
            PlanReconciler(policy: .init(admitsOversizedHeadItem: true, stopsAtFirstOverflow: false)),
            PlanReconciler(policy: .init(admitsOversizedHeadItem: false, stopsAtFirstOverflow: true)),
        ]

        for iteration in 0..<400 {
            let catalogSize = Int(rng.next(upperBound: 60))
            var desired: [WorkItem] = []
            for index in 0..<catalogSize {
                // Deliberately allow duplicate ids across the catalogue.
                let id = "asset-\(rng.next(upperBound: UInt64(max(catalogSize, 1))))"
                let priority = WorkPriority(rawValue: Int(rng.next(upperBound: 3))) ?? .speculative
                desired.append(
                    WorkItem(
                        id: WorkID(id),
                        priority: priority,
                        index: index,
                        estimatedDecodeBytes: Int(rng.next(upperBound: 900))
                    )
                )
            }

            var inFlight: [WorkID: WorkPriority] = [:]
            for candidate in desired where rng.next(upperBound: 2) == 0 {
                inFlight[candidate.id] =
                    WorkPriority(rawValue: Int(rng.next(upperBound: 3))) ?? .visible
            }
            // Plus some ids that are running but no longer in the catalogue.
            for extra in 0..<Int(rng.next(upperBound: 5)) {
                inFlight[WorkID("orphan-\(extra)")] = .speculative
            }

            let budget = CapacityBudget(
                prefetchDepth: Int(rng.next(upperBound: 40)),
                concurrencyLimit: Int(rng.next(upperBound: 30)),
                decodeByteBudget: Int(rng.next(upperBound: 6_000))
            )
            let index = Int(rng.next(upperBound: UInt64(reconcilers.count)))
            guard index < reconcilers.count else { continue }
            let subject = reconcilers[index]

            let transition = subject.reconcile(
                inFlight: inFlight,
                desired: desired,
                viewport: .zero,
                budget: budget,
                generation: UInt64(iteration)
            )
            // The in-flight set is passed deliberately. Without it `validate`
            // can only detect contradictions, and this whole property test
            // would pass against a `reconcile` that returned an empty
            // transition for every input.
            let violations = transition.validate(
                inFlight: Set(inFlight.keys),
                allowOversizedHeadItem: subject.policy.admitsOversizedHeadItem
            )
            XCTAssertTrue(
                violations.isEmpty,
                "iteration \(iteration) produced \(violations.map(\.description))"
            )
        }
    }
}

/// Deterministic PRNG so property-test failures are reproducible.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// - Returns: a value in `0 ..< upperBound`, or `0` when `upperBound` is 0.
    mutating func next(upperBound: UInt64) -> UInt64 {
        guard upperBound > 0 else { return 0 }
        return next() % upperBound
    }
}
