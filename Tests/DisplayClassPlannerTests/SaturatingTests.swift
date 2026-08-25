import XCTest
@testable import DisplayClassPlanner

/// Each of these inputs makes the corresponding *built-in* Swift operator trap.
/// The assertions are exact values, not ranges: a helper that returned `0` for
/// everything would pass a range check and fail every test here.
final class SaturatingTests: XCTestCase {

    // MARK: - Int(Double)

    func testIntClampingHandlesNaN() {
        // `Int(Double.nan)` traps.
        XCTAssertEqual(Saturating.int(clamping: Double.nan), 0)
        XCTAssertEqual(Saturating.int(clamping: -Double.nan), 0)
    }

    func testIntClampingHandlesInfinities() {
        // `Int(Double.infinity)` traps.
        XCTAssertEqual(Saturating.int(clamping: .infinity), Int.max)
        XCTAssertEqual(Saturating.int(clamping: -.infinity), Int.min)
    }

    func testIntClampingHandlesOutOfRangeFiniteValues() {
        // `Int(1e300)` traps: finite, but far outside Int.
        XCTAssertEqual(Saturating.int(clamping: 1e300), Int.max)
        XCTAssertEqual(Saturating.int(clamping: -1e300), Int.min)
    }

    func testIntClampingIsExactAtTheBoundary() {
        // `Double(Int.max)` rounds up to 2^63, which is NOT representable as an
        // Int — `Int(Double(Int.max))` traps on a 64-bit platform. The helper
        // must recognise the boundary rather than hand it to `Int.init`.
        XCTAssertEqual(Saturating.int(clamping: Double(Int.max)), Int.max)
        XCTAssertEqual(Saturating.int(clamping: Double(Int.min)), Int.min)
    }

    func testIntClampingTruncatesTowardZeroInRange() {
        XCTAssertEqual(Saturating.int(clamping: 3.99), 3)
        XCTAssertEqual(Saturating.int(clamping: -3.99), -3)
        XCTAssertEqual(Saturating.int(clamping: 0), 0)
    }

    // MARK: - Addition and multiplication

    func testAddingSaturatesInsteadOfTrapping() {
        XCTAssertEqual(Saturating.adding(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.adding(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.adding(Int.max, Int.max), Int.max)
        XCTAssertEqual(Saturating.adding(Int.min, Int.min), Int.min)
        // Non-overflowing arithmetic must still be arithmetic.
        XCTAssertEqual(Saturating.adding(7, 5), 12)
        XCTAssertEqual(Saturating.adding(Int.max, -1), Int.max - 1)
    }

    func testMultiplyingSaturatesToTheCorrectEnd() {
        XCTAssertEqual(Saturating.multiplying(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiplying(Int.max, -2), Int.min)
        XCTAssertEqual(Saturating.multiplying(Int.min, 2), Int.min)
        // Int.min * -1 overflows; the true product is Int.max + 1.
        XCTAssertEqual(Saturating.multiplying(Int.min, -1), Int.max)
        XCTAssertEqual(Saturating.multiplying(-6, -7), 42)
        XCTAssertEqual(Saturating.multiplying(0, Int.max), 0)
    }

    func testUnsignedAddingSaturates() {
        XCTAssertEqual(Saturating.adding(UInt64.max, 1), UInt64.max)
        XCTAssertEqual(Saturating.adding(UInt64.max - 5, 100), UInt64.max)
        XCTAssertEqual(Saturating.adding(UInt64(10), 32), 42)
    }

    func testUnsignedSubtractingClampsAtZeroInsteadOfTrapping() {
        // `0 - 1` on UInt64 traps. This is `now - lastSample` when a clock
        // reading comes back lower than the previous one.
        XCTAssertEqual(Saturating.subtracting(UInt64(0), 1), 0)
        XCTAssertEqual(Saturating.subtracting(UInt64(5), 9), 0)
        XCTAssertEqual(Saturating.subtracting(UInt64(9), 5), 4)
        XCTAssertEqual(Saturating.subtracting(UInt64.max, 0), UInt64.max)
        XCTAssertEqual(Saturating.subtracting(UInt64(7), 7), 0)
    }

    // MARK: - Division

    func testDividingByZeroReturnsFallbackInsteadOfTrapping() {
        XCTAssertEqual(Saturating.dividing(10, by: 0), 0)
        XCTAssertEqual(Saturating.dividing(10, by: 0, fallback: 99), 99)
    }

    func testIntMinDividedByNegativeOneDoesNotTrap() {
        // The one division that overflows: |Int.min| is not representable.
        XCTAssertEqual(Saturating.dividing(Int.min, by: -1), Int.max)
    }

    func testDividingIsOtherwiseOrdinaryIntegerDivision() {
        XCTAssertEqual(Saturating.dividing(7, by: 2), 3)
        XCTAssertEqual(Saturating.dividing(-7, by: 2), -3)
    }

    // MARK: - Clamping

    func testClampInt() {
        XCTAssertEqual(Saturating.clamp(-5, to: 0...10), 0)
        XCTAssertEqual(Saturating.clamp(50, to: 0...10), 10)
        XCTAssertEqual(Saturating.clamp(4, to: 0...10), 4)
    }

    func testClampDoubleMapsNaNToLowerBound() {
        XCTAssertEqual(Saturating.clamp(Double.nan, to: 1...9), 1)
        XCTAssertEqual(Saturating.clamp(.infinity, to: 1...9), 9)
        XCTAssertEqual(Saturating.clamp(-.infinity, to: 1...9), 1)
        XCTAssertEqual(Saturating.clamp(5.5, to: 1...9), 5.5)
    }
}
