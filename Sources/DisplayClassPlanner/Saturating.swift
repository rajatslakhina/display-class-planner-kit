//
//  Saturating.swift
//  DisplayClassPlanner
//
//  Every arithmetic operation in this package that *could* trap goes through
//  here. Swift's default integer arithmetic traps on overflow, `/` and `%` trap
//  on a zero divisor, `Int.min / -1` traps, and `Int(someDouble)` traps on NaN,
//  on ±infinity, and on any value outside `Int`'s representable range.
//
//  A capacity planner derives its numbers from `CGSize` values that arrive from
//  UIKit/SwiftUI mid-transition, and those are exactly the values that come
//  through as `0`, as `.nan`, or as something absurd during a rotation or a
//  fold. "It can't be NaN in practice" is not a safety argument; it is a
//  prediction about a value we do not own.
//

/// Clamping replacements for the arithmetic that can trap.
///
/// These are deliberately free functions on a caseless enum rather than
/// operators: a reader scanning the planner should be able to see, at the call
/// site, that a bound was applied.
public enum Saturating {

    // MARK: - Int

    /// `a + b`, clamped to `Int.min ... Int.max` instead of trapping.
    @inlinable
    public static func adding(_ a: Int, _ b: Int) -> Int {
        let (result, overflowed) = a.addingReportingOverflow(b)
        guard overflowed else { return result }
        // Overflow direction is decided by the sign of the addend: only a
        // positive `b` can push past `Int.max`.
        return b > 0 ? Int.max : Int.min
    }

    /// `a * b`, clamped to `Int.min ... Int.max` instead of trapping.
    @inlinable
    public static func multiplying(_ a: Int, _ b: Int) -> Int {
        let (result, overflowed) = a.multipliedReportingOverflow(by: b)
        guard overflowed else { return result }
        // Overflow can only happen when both operands are non-zero, so the sign
        // of the true product is the XOR of the operand signs.
        let bothSameSign = (a > 0) == (b > 0)
        return bothSameSign ? Int.max : Int.min
    }

    /// `a / b`, defined for every input.
    ///
    /// - Returns: `fallback` when `b == 0` (division by zero traps), and
    ///   `Int.max` for `Int.min / -1` (whose true quotient is `Int.max + 1`).
    @inlinable
    public static func dividing(_ a: Int, by b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        guard !(a == Int.min && b == -1) else { return Int.max }
        return a / b
    }

    /// `a % b`, defined for every input.
    ///
    /// - Returns: `0` when `b == 0`, and `0` for `Int.min % -1` (mathematically
    ///   `0`, but the hardware instruction traps alongside the division).
    @inlinable
    public static func remainder(_ a: Int, dividingBy b: Int) -> Int {
        guard b != 0 else { return 0 }
        guard !(a == Int.min && b == -1) else { return 0 }
        return a % b
    }

    // MARK: - UInt64 (monotonic timestamps)

    /// `a + b`, clamped to `UInt64.max`.
    ///
    /// Deadlines are computed as `now + hold`. `now` is a monotonic clock
    /// reading the caller supplies; nothing stops it from being near
    /// `UInt64.max` on a synthetic or replayed clock, and a trapping `+` there
    /// would crash a *test harness* long before it crashed a device.
    @inlinable
    public static func adding(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflowed) = a.addingReportingOverflow(b)
        return overflowed ? UInt64.max : result
    }

    // MARK: - Double to Int

    /// `Int(value)` for every `Double`, including the four inputs that trap.
    ///
    /// - `NaN` maps to `0`. There is no defensible numeric answer, and `0` is
    ///   the identity for every budget this package computes — a NaN viewport
    ///   yields an empty plan rather than an arbitrary one.
    /// - `+∞` maps to `Int.max`, `-∞` to `Int.min`.
    /// - Out-of-range finite values clamp to the nearest bound.
    ///
    /// The bounds are derived from `Int.max` / `Int.min` rather than written as
    /// 64-bit literals, because `Int` is 32-bit on watchOS and a hardcoded
    /// `9223372036854775807` would silently stop being a bound there.
    ///
    /// `Double(Int.max)` rounds *up* to `2^63` on a 64-bit platform (`Int.max`
    /// itself is not representable as a `Double`), so the upper comparison is
    /// deliberately `>=`: any value at or above that boundary is out of range.
    @inlinable
    public static func int(clamping value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        guard value.isFinite else { return value > 0 ? Int.max : Int.min }
        if value >= Double(Int.max) { return Int.max }
        // `Double(Int.min)` is exactly `-2^63` on a 64-bit platform, and
        // `Int(-2^63)` is valid, so `<=` and `<` agree here. `<=` is used so the
        // expression reads as "at or past the bound".
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }

    // MARK: - Clamping

    /// `value` constrained to `range`, with no precondition on the caller.
    ///
    /// `Swift.min(Swift.max(...))` is the same thing, but a mis-ordered pair of
    /// bounds silently inverts it. `ClosedRange` cannot be constructed inverted,
    /// so this signature makes the mistake unrepresentable.
    @inlinable
    public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        if value < range.lowerBound { return range.lowerBound }
        if value > range.upperBound { return range.upperBound }
        return value
    }

    /// `value` constrained to `range`, mapping NaN to `range.lowerBound`.
    @inlinable
    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard !value.isNaN else { return range.lowerBound }
        if value < range.lowerBound { return range.lowerBound }
        if value > range.upperBound { return range.upperBound }
        return value
    }
}
