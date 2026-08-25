import XCTest
@testable import DisplayClassPlanner

/// The README claims `PlanTransition.validate()` catches the bugs this package
/// exists to prevent. A checker that returns `[]` for everything would make
/// every other test in this suite pass while catching nothing, so each test
/// here hands it a **deliberately broken transition** and asserts that the
/// specific violation is reported.
///
/// The positive control at the top is not optional: without it, a checker that
/// reported violations unconditionally would also pass this file.
final class InvariantCheckerTests: XCTestCase {

    private let budget = CapacityBudget(
        prefetchDepth: 10, concurrencyLimit: 4, decodeByteBudget: 1_000
    )

    private func item(_ id: String, bytes: Int = 100) -> WorkItem {
        WorkItem(id: WorkID(id), priority: .visible, index: 0, estimatedDecodeBytes: bytes)
    }

    private func transition(
        retained: [String] = [],
        reprioritized: [PlanTransition.Reprioritization] = [],
        cancelled: [String] = [],
        admitted: [WorkItem] = [],
        budget: CapacityBudget? = nil
    ) -> PlanTransition {
        PlanTransition(
            generation: 1,
            budget: budget ?? self.budget,
            viewport: .zero,
            retained: retained.map(WorkID.init),
            reprioritized: reprioritized,
            cancelled: cancelled.map(WorkID.init),
            admitted: admitted
        )
    }

    // MARK: - Positive control

    func testAWellFormedTransitionReportsNothing() {
        let clean = transition(
            retained: ["a"],
            reprioritized: [.init(id: WorkID("b"), from: .speculative, to: .visible)],
            cancelled: ["c"],
            admitted: [item("d")]
        )
        XCTAssertEqual(clean.validate(), [])
    }

    // MARK: - Broken transitions

    func testCancellingAndRetainingTheSameIdIsCaught() {
        // The duplicated-fetch bug: tear down a request, immediately re-issue
        // the identical one.
        let broken = transition(retained: ["a"], cancelled: ["a"])
        XCTAssertEqual(broken.validate(), [.cancelledAndKept(WorkID("a"))])
    }

    func testCancellingAndAdmittingTheSameIdIsCaught() {
        let broken = transition(cancelled: ["a"], admitted: [item("a")])
        XCTAssertEqual(broken.validate(), [.cancelledAndKept(WorkID("a"))])
    }

    func testCancellingAndReprioritizingTheSameIdIsCaught() {
        let broken = transition(
            reprioritized: [.init(id: WorkID("a"), from: .visible, to: .adjacent)],
            cancelled: ["a"]
        )
        XCTAssertEqual(broken.validate(), [.cancelledAndKept(WorkID("a"))])
    }

    func testTheSameIdInTwoKeepBucketsIsCaught() {
        // Two contradictory instructions for one request.
        let broken = transition(retained: ["a"], admitted: [item("a")])
        XCTAssertEqual(broken.validate(), [.duplicateInstruction(WorkID("a"))])
    }

    func testADuplicateCancelIsCaught() {
        let broken = transition(cancelled: ["a", "a"])
        XCTAssertEqual(broken.validate(), [.duplicateInstruction(WorkID("a"))])
    }

    func testADegenerateReprioritizationIsCaught() {
        // Harmless at runtime, but it means the reconciler mis-bucketed
        // something that belonged in `retained`.
        let broken = transition(
            reprioritized: [.init(id: WorkID("a"), from: .visible, to: .visible)]
        )
        XCTAssertEqual(broken.validate(), [.degenerateReprioritization(WorkID("a"))])
    }

    func testOverAdmittingBeyondThePrefetchDepthIsCaught() {
        let tight = CapacityBudget(prefetchDepth: 1, concurrencyLimit: 1, decodeByteBudget: 1_000)
        let broken = transition(
            retained: ["a"], admitted: [item("b")], budget: tight
        )
        XCTAssertEqual(broken.validate(), [.overAdmitted(count: 2, limit: 1)])
    }

    func testExceedingTheDecodeBudgetWithMoreThanOneItemIsCaught() {
        let broken = transition(
            admitted: [item("a", bytes: 600), item("b", bytes: 600)]
        )
        XCTAssertEqual(broken.validate(), [.overDecodeBudget(bytes: 1_200, limit: 1_000)])
    }

    func testASingleOversizedItemIsExcusedOrNotDependingOnThePolicyFlag() {
        // Same transition, two contracts — so the exemption is a real, tested
        // branch rather than a sentence in a doc comment.
        let oversizedHead = transition(admitted: [item("a", bytes: 9_999)])
        XCTAssertEqual(oversizedHead.validate(allowOversizedHeadItem: true), [])
        XCTAssertEqual(
            oversizedHead.validate(allowOversizedHeadItem: false),
            [.overDecodeBudget(bytes: 9_999, limit: 1_000)]
        )
    }

    func testRetainedWorkDoesNotRechargeTheDecodeBudget() {
        // Retained work already holds its bytes; charging it again would make
        // every contraction look like a budget violation.
        let contraction = transition(
            retained: ["a", "b", "c"],
            cancelled: ["d"],
            admitted: []
        )
        XCTAssertEqual(contraction.validate(), [])
    }

    func testMultipleViolationsAreAllReportedInADeterministicOrder() {
        let tight = CapacityBudget(prefetchDepth: 1, concurrencyLimit: 1, decodeByteBudget: 10)
        let broken = PlanTransition(
            generation: 1,
            budget: tight,
            viewport: .zero,
            retained: [WorkID("z")],
            reprioritized: [.init(id: WorkID("y"), from: .visible, to: .visible)],
            cancelled: [WorkID("z"), WorkID("a")],
            admitted: [item("a", bytes: 50), item("b", bytes: 50)]
        )
        // Conflicts first (sorted), then duplicates, then degenerate
        // reprioritizations, then the two budget checks — a stable order, so a
        // failure message is diffable between runs.
        XCTAssertEqual(
            broken.validate(),
            [
                .cancelledAndKept(WorkID("a")),
                .cancelledAndKept(WorkID("z")),
                .degenerateReprioritization(WorkID("y")),
                .overAdmitted(count: 4, limit: 1),
                .overDecodeBudget(bytes: 100, limit: 10),
            ]
        )
    }

    // MARK: - Descriptions

    func testViolationDescriptionsNameTheOffendingId() {
        // These strings surface in the demo app's UI and in CI failure output,
        // so an empty or generic description is a real defect.
        let description = PlanTransition.InvariantViolation
            .cancelledAndKept(WorkID("asset-7")).description
        XCTAssertTrue(description.contains("asset-7"))
        XCTAssertTrue(description.contains("cancel"))
    }
}
