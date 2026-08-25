import XCTest
@testable import DisplayClassPlanner

final class ViewportTests: XCTestCase {

    func testNonFiniteDimensionsBecomeZero() {
        // A CGSize mid-transition really does arrive as NaN. Everything
        // downstream multiplies these, so the trust boundary is here.
        XCTAssertEqual(Viewport(width: .nan, height: 400, columnCount: 1).width, 0)
        XCTAssertEqual(Viewport(width: 400, height: .infinity, columnCount: 1).height, 0)
        XCTAssertEqual(Viewport(width: -.infinity, height: 400, columnCount: 1).width, 0)
    }

    func testNegativeAndZeroDimensionsBecomeZero() {
        XCTAssertEqual(Viewport(width: -800, height: 400, columnCount: 1).width, 0)
        XCTAssertEqual(Viewport(width: 800, height: -1, columnCount: 1).height, 0)
    }

    func testDimensionsAreCappedSoAreaCannotOverflowToInfinity() {
        let huge = Viewport(width: .greatestFiniteMagnitude,
                            height: .greatestFiniteMagnitude,
                            columnCount: 1)
        XCTAssertEqual(huge.width, Viewport.maxDimension)
        XCTAssertEqual(huge.height, Viewport.maxDimension)
        XCTAssertTrue(huge.area.isFinite)
        XCTAssertEqual(huge.area, Viewport.maxDimension * Viewport.maxDimension)
    }

    func testColumnCountIsClampedIntoAUsableRange() {
        XCTAssertEqual(Viewport(width: 100, height: 100, columnCount: 0).columnCount, 1)
        XCTAssertEqual(Viewport(width: 100, height: 100, columnCount: -9).columnCount, 1)
        XCTAssertEqual(Viewport(width: 100, height: 100, columnCount: Int.max).columnCount,
                       Viewport.maxColumnCount)
    }

    func testScaleFallsBackRatherThanBecomingZero() {
        // A zero scale would make backingPixelArea zero and silently zero the
        // decode budget — a blank screen with no error.
        XCTAssertEqual(Viewport(width: 100, height: 100, columnCount: 1, scale: 0).scale, 1)
        XCTAssertEqual(Viewport(width: 100, height: 100, columnCount: 1, scale: .nan).scale, 1)
        XCTAssertEqual(Viewport(width: 100, height: 100, columnCount: 1, scale: -3).scale, 1)
        XCTAssertEqual(Viewport(width: 100, height: 100, columnCount: 1, scale: 99).scale,
                       Viewport.maxScale)
    }

    func testClassificationByArea() {
        // Exactly at the threshold is inclusive, one point below is not.
        XCTAssertEqual(Viewport.classify(area: Viewport.regularAreaThreshold, columnCount: 1),
                       .regular)
        XCTAssertEqual(Viewport.classify(area: Viewport.regularAreaThreshold - 1, columnCount: 1),
                       .compact)
        XCTAssertEqual(Viewport.classify(area: Viewport.expansiveAreaThreshold, columnCount: 1),
                       .expansive)
    }

    func testASecondColumnPromotesASmallSurfaceToRegular() {
        // The property the planner actually cares about: a second pane demands
        // content that was never requested, whatever the area says.
        XCTAssertEqual(Viewport.classify(area: 1_000, columnCount: 2), .regular)
        XCTAssertEqual(Viewport.classify(area: 1_000, columnCount: 3), .expansive)
    }

    func testAnExplicitDisplayClassOverridesTheAreaThresholds() {
        // The customisation seam. Without it the thresholds are a constant a
        // caller can read but never change, and every downstream decision
        // (hysteresis direction, budget tier) is stuck with them.
        let tiny = Viewport(width: 100, height: 100, columnCount: 1, scale: 1)
        XCTAssertEqual(tiny.displayClass, .compact)

        let overridden = Viewport(
            width: 100, height: 100, columnCount: 1, scale: 1, displayClass: .expansive
        )
        XCTAssertEqual(overridden.displayClass, .expansive)
        // Only the classification is overridden; the measurements are not.
        XCTAssertEqual(overridden.area, 10_000)

        // And `nil` means "derive it as usual".
        let derived = Viewport(
            width: 100, height: 100, columnCount: 1, scale: 1, displayClass: nil
        )
        XCTAssertEqual(derived.displayClass, .compact)
        XCTAssertEqual(derived, tiny)
    }

    func testEqualityComparesTheSurfaceNotHowItsClassWasDecided() {
        // Synthesized `==` would compare the private `explicitDisplayClass`,
        // so a viewport that *derived* `.compact` would not equal one that was
        // *told* `.compact` — despite every public property, `displayClass`
        // included, being identical. `Viewport` is embedded in three Hashable
        // types, so that distinction would leak into Sets and dictionary keys.
        let derived = Viewport(width: 100, height: 100, columnCount: 1, scale: 1)
        let told = Viewport(
            width: 100, height: 100, columnCount: 1, scale: 1, displayClass: .compact
        )
        XCTAssertEqual(derived.displayClass, told.displayClass)
        XCTAssertEqual(derived, told)
        XCTAssertEqual(derived.hashValue, told.hashValue)
        XCTAssertEqual(Set([derived, told]).count, 1)

        // A genuinely different classification is still a different viewport.
        let overridden = Viewport(
            width: 100, height: 100, columnCount: 1, scale: 1, displayClass: .expansive
        )
        XCTAssertNotEqual(derived, overridden)
        XCTAssertEqual(Set([derived, told, overridden]).count, 2)

        // And the measurements still matter.
        XCTAssertNotEqual(
            derived,
            Viewport(width: 101, height: 100, columnCount: 1, scale: 1)
        )
    }

    func testDescriptionRendersWithoutTrappingOnHostileDimensions() {
        // `description` formats the dimensions as Ints. `Int(Double)` traps on
        // NaN and on out-of-range values, and this is the one place in the
        // package where a debug string could take down the app that printed it.
        XCTAssertFalse(Viewport(width: .nan, height: .nan, columnCount: 1).description.isEmpty)
        let huge = Viewport(
            width: .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude,
            columnCount: 9,
            scale: 99
        )
        XCTAssertEqual(huge.description, "Viewport(100000x100000 cols:8 @4.0x -> .expansive)")
        XCTAssertEqual(
            Viewport(width: 420, height: 900, columnCount: 1, scale: 3).description,
            "Viewport(420x900 cols:1 @3.0x -> .compact)"
        )
    }

    func testZeroViewportIsCompactAndHasNoArea() {
        XCTAssertEqual(Viewport.zero.area, 0)
        XCTAssertEqual(Viewport.zero.displayClass, .compact)
        XCTAssertEqual(Viewport.zero.columnCount, 1)
    }
}

final class BudgetPolicyTests: XCTestCase {

    private let policy = AreaProportionalBudgetPolicy()

    func testBudgetForAnExactlyOneCellSurface() {
        // 100x144 = 14 400 pt² = exactly one default cell, scale 1.
        //   visibleCells    = 14400 / 14400            = 1
        //   prefetchDepth   = 1 * 2                    = 2
        //   concurrency     = 2 / 4 = 0, floored to    = 1
        //   backingPixels   = 14400 * 1 * 1            = 14 400
        //   resident        = 14400 * 3                = 43 200
        //   decodeBytes     = 43200 * 4                = 172 800
        let budget = policy.budget(
            for: Viewport(width: 100, height: 144, columnCount: 1, scale: 1)
        )
        XCTAssertEqual(budget.prefetchDepth, 2)
        XCTAssertEqual(budget.concurrencyLimit, 1)
        XCTAssertEqual(budget.decodeByteBudget, 172_800)
    }

    func testUnmeasuredSurfaceAdmitsNothingButKeepsALiveSlot() {
        let budget = policy.budget(for: .zero)
        XCTAssertEqual(budget.prefetchDepth, 0)
        XCTAssertEqual(budget.decodeByteBudget, 0)
        // Floor of 1: a zero-slot pipeline admits work and never runs it, which
        // presents as a permanently blank surface rather than a crash.
        XCTAssertEqual(budget.concurrencyLimit, 1)
    }

    func testNaNSurfaceProducesAnEmptyBudgetRatherThanGarbage() {
        let budget = policy.budget(
            for: Viewport(width: .nan, height: .nan, columnCount: 1)
        )
        XCTAssertEqual(budget.prefetchDepth, 0)
        XCTAssertEqual(budget.decodeByteBudget, 0)
    }

    func testAbsurdSurfaceClampsToTheHardCeilings() {
        let budget = policy.budget(
            for: Viewport(width: .greatestFiniteMagnitude,
                          height: .greatestFiniteMagnitude,
                          columnCount: 1,
                          scale: 4)
        )
        // This is what makes "no unbounded growth" structural: the in-flight
        // table only grows through admission, and admission stops here.
        XCTAssertEqual(budget.prefetchDepth, CapacityBudget.maxPrefetchDepth)
        XCTAssertEqual(budget.concurrencyLimit, CapacityBudget.maxConcurrencyLimit)
        if Int.bitWidth >= 64 {
            //   area      = 1e10, backingPixels = 1e10 * 16 = 1.6e11
            //   resident  = 1.6e11 * 3                      = 4.8e11
            //   bytes     = 4.8e11 * 4                      = 1.92e12
            XCTAssertEqual(budget.decodeByteBudget, 1_920_000_000_000)
        }
    }

    func testDegeneratePolicyInputsAreRepairedAtConstruction() {
        // A zero averageCellArea would be a division by zero on the hot path.
        let repaired = AreaProportionalBudgetPolicy(
            averageCellArea: 0,
            prefetchMultiplier: -5,
            itemsPerConcurrencySlot: 0,
            residentScreenfuls: .nan,
            bytesPerPixel: 0
        )
        XCTAssertEqual(repaired.averageCellArea, 14_400)
        XCTAssertEqual(repaired.prefetchMultiplier, 0)
        XCTAssertEqual(repaired.itemsPerConcurrencySlot, 1)
        XCTAssertEqual(repaired.residentScreenfuls, 0)
        XCTAssertEqual(repaired.bytesPerPixel, 1)

        // And the repaired policy still produces a usable budget.
        let budget = repaired.budget(for: Viewport(width: 400, height: 400, columnCount: 1))
        XCTAssertEqual(budget.prefetchDepth, 0)   // multiplier was clamped to 0
        XCTAssertEqual(budget.concurrencyLimit, 1)
        XCTAssertEqual(budget.decodeByteBudget, 0)
    }

    func testBudgetInitClampsEveryField() {
        let budget = CapacityBudget(
            prefetchDepth: Int.max,
            concurrencyLimit: -4,
            decodeByteBudget: -1
        )
        XCTAssertEqual(budget.prefetchDepth, CapacityBudget.maxPrefetchDepth)
        XCTAssertEqual(budget.concurrencyLimit, 1)
        XCTAssertEqual(budget.decodeByteBudget, 0)
    }

    func testUnfoldingGenuinelyRaisesTheBudget() {
        // The whole premise: the same content list, a bigger surface, more work.
        let cover = policy.budget(for: Viewport(width: 420, height: 900, columnCount: 1, scale: 3))
        let inner = policy.budget(for: Viewport(width: 760, height: 820, columnCount: 2, scale: 3))
        XCTAssertGreaterThan(inner.prefetchDepth, cover.prefetchDepth)
        XCTAssertGreaterThan(inner.decodeByteBudget, cover.decodeByteBudget)
        //   cover: 420*900 = 378 000 -> 378000/14400 = 26.25 -> *2 = 52.5 -> 52
        //   inner: 760*820 = 623 200 -> 623200/14400 = 43.27 -> *2 = 86.5 -> 86
        XCTAssertEqual(cover.prefetchDepth, 52)
        XCTAssertEqual(inner.prefetchDepth, 86)
    }
}
