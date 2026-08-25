import XCTest
@testable import DisplayClassPlanner

/// Fold storms are a table of integers here, not a sequence of `Task.sleep`
/// calls, because `TransitionDebouncer` takes an explicit `now`.
final class TransitionDebouncerTests: XCTestCase {

    private let compact = Viewport(width: 400, height: 800, columnCount: 1, scale: 3)
    private let regular = Viewport(width: 760, height: 820, columnCount: 2, scale: 3)
    private let expansive = Viewport(width: 1180, height: 900, columnCount: 3, scale: 2)

    private let hold: UInt64 = 400_000_000

    func testFixturesLandInTheDisplayClassesTheseTestsAssume() {
        XCTAssertEqual(compact.displayClass, .compact)
        XCTAssertEqual(regular.displayClass, .regular)
        XCTAssertEqual(expansive.displayClass, .expansive)
    }

    // MARK: - Asymmetry

    func testExpansionAppliesImmediately() {
        var debouncer = TransitionDebouncer(committed: compact)
        XCTAssertEqual(debouncer.observe(regular, at: 1_000), .applyNow(regular))
        XCTAssertEqual(debouncer.committed, regular)
        XCTAssertNil(debouncer.pending)
    }

    func testContractionIsHeld() {
        var debouncer = TransitionDebouncer(committed: regular)
        XCTAssertEqual(
            debouncer.observe(compact, at: 1_000),
            .hold(compact, until: 1_000 + hold)
        )
        // Nothing has been committed yet: the pane going away still has content.
        XCTAssertEqual(debouncer.committed, regular)
        XCTAssertEqual(debouncer.nextDeadline, 1_000 + hold)
    }

    func testHoldCommitsOnlyOnceItsDeadlineArrives() {
        var debouncer = TransitionDebouncer(committed: regular)
        _ = debouncer.observe(compact, at: 1_000)
        XCTAssertNil(debouncer.tick(at: 1_000 + hold - 1))
        XCTAssertEqual(debouncer.tick(at: 1_000 + hold), compact)
        XCTAssertEqual(debouncer.committed, compact)
        // And the pending slot is drained, so a second tick does nothing.
        XCTAssertNil(debouncer.tick(at: 1_000 + hold + 1))
    }

    // MARK: - Storm behaviour

    func testRepeatedObservationsDoNotPushTheDeadlineOut() {
        // The classic debounce-starvation bug: a surface emitting size changes
        // at display refresh rate during a drag extends the deadline on every
        // frame and never commits. The deadline is set once, by the first
        // observation of that target class.
        var debouncer = TransitionDebouncer(committed: regular)
        let firstDeadline = 1_000 + hold
        XCTAssertEqual(debouncer.observe(compact, at: 1_000), .hold(compact, until: firstDeadline))

        for frame in stride(from: UInt64(1_016), through: 300_000_000, by: 16_000_000) {
            XCTAssertEqual(
                debouncer.observe(compact, at: frame),
                .hold(compact, until: firstDeadline),
                "deadline moved at frame \(frame)"
            )
        }
        XCTAssertEqual(debouncer.tick(at: firstDeadline), compact)
    }

    func testAReversalWithdrawsThePendingChangeAndCancelsNothing() {
        var debouncer = TransitionDebouncer(committed: regular)
        _ = debouncer.observe(compact, at: 1_000)
        XCTAssertEqual(debouncer.observe(regular, at: 100_000_000), .withdrawn)
        XCTAssertNil(debouncer.pending)
        XCTAssertEqual(debouncer.withdrawnCount, 1)
        // Nothing is due later either — the storm cost zero requests.
        XCTAssertNil(debouncer.tick(at: 1_000 + hold))
        XCTAssertEqual(debouncer.committed.displayClass, .regular)
    }

    func testRepeatedStormsAccumulateAWithdrawalCount() {
        var debouncer = TransitionDebouncer(committed: regular)
        var clock: UInt64 = 0
        for _ in 0..<5 {
            _ = debouncer.observe(compact, at: clock)
            clock += 50_000_000
            _ = debouncer.observe(regular, at: clock)
            clock += 50_000_000
        }
        // The metric that justifies the hysteresis existing: if this stays at
        // zero in production, the hold is pure latency.
        XCTAssertEqual(debouncer.withdrawnCount, 5)
        XCTAssertNil(debouncer.pending)
    }

    func testAnExpansionDuringAHoldSupersedesIt() {
        var debouncer = TransitionDebouncer(committed: regular)
        _ = debouncer.observe(compact, at: 1_000)
        // Going *up* from the committed class is an expansion and applies now,
        // discarding the pending contraction.
        XCTAssertEqual(debouncer.observe(expansive, at: 2_000), .applyNow(expansive))
        XCTAssertNil(debouncer.pending)
        XCTAssertEqual(debouncer.committed, expansive)
    }

    func testSameClassWithDifferentDimensionsIsAdoptedWithoutAHold() {
        var debouncer = TransitionDebouncer(committed: regular)
        let widerRegular = Viewport(width: 800, height: 820, columnCount: 2, scale: 3)
        XCTAssertEqual(debouncer.observe(widerRegular, at: 1_000), .ignore)
        // Adopted, so a budget derived from it tracks the new width.
        XCTAssertEqual(debouncer.committed, widerRegular)
        XCTAssertNil(debouncer.pending)
    }

    // MARK: - Arithmetic edges

    func testDeadlineSaturatesInsteadOfWrappingNearTheClockCeiling() {
        var debouncer = TransitionDebouncer(committed: regular)
        let decision = debouncer.observe(compact, at: UInt64.max - 1)
        // A wrapping `+` would produce a deadline in the past and commit the
        // contraction instantly; a trapping `+` would crash the harness.
        XCTAssertEqual(decision, .hold(compact, until: UInt64.max))
        XCTAssertNil(debouncer.tick(at: UInt64.max - 1))
        XCTAssertEqual(debouncer.tick(at: UInt64.max), compact)
    }

    func testANonMonotonicClockDelaysButDoesNotCrash() {
        var debouncer = TransitionDebouncer(committed: regular)
        _ = debouncer.observe(compact, at: 1_000_000_000)
        // Clock goes backwards. The deadline is still in the future relative to
        // the rewound reading, so nothing commits — a delay, not a trap.
        XCTAssertNil(debouncer.tick(at: 0))
        XCTAssertEqual(debouncer.tick(at: 1_400_000_000), compact)
    }

    func testImmediatePolicyDisablesHysteresisEntirely() {
        var debouncer = TransitionDebouncer(committed: regular, policy: .immediate)
        XCTAssertEqual(debouncer.observe(compact, at: 1_000), .applyNow(compact))
        XCTAssertEqual(debouncer.committed, compact)
        XCTAssertNil(debouncer.pending)
    }

    func testZeroViewportContractsFromAnyClass() {
        var debouncer = TransitionDebouncer(committed: expansive, policy: .immediate)
        XCTAssertEqual(debouncer.observe(.zero, at: 0), .applyNow(.zero))
        XCTAssertEqual(debouncer.committed.displayClass, .compact)
    }
}
