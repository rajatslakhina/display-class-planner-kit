//
//  Viewport.swift
//  DisplayClassPlanner
//

/// The coarse capacity tier a surface is currently running at.
///
/// This is *not* `UIUserInterfaceSizeClass`. A size class answers "how should
/// this lay out"; a display class answers "how much work is this surface
/// entitled to have in flight". A single-column phone and a two-column inner
/// display can share a size class and still differ by a factor of two in the
/// number of images they will demand in the next second.
public enum DisplayClass: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Cover display, single column. Smallest capacity tier.
    case compact = 0
    /// Inner display or a regular-width window. A detail pane exists.
    case regular = 1
    /// External display or a desktop-class window. Multiple panes.
    case expansive = 2

    public static func < (lhs: DisplayClass, rhs: DisplayClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A sanitized description of the surface a plan is being made for.
///
/// Every stored property is normalised in `init`, so a `Viewport` value is
/// always safe to do arithmetic on. This is the package's single trust
/// boundary: callers hand in raw `CGSize`-derived doubles, and everything
/// downstream may assume finiteness and bounds.
public struct Viewport: Sendable, Hashable, CustomStringConvertible {

    /// Largest dimension, in points, that any real surface can have.
    ///
    /// The bound exists so `area` (a product of two dimensions) is provably
    /// finite: `maxDimension²` is `10¹⁰`, which is nowhere near `Double`'s
    /// range, so `width * height` can never produce an infinity that would then
    /// need clamping again downstream.
    public static let maxDimension: Double = 100_000

    /// Largest number of columns a surface may declare.
    ///
    /// Bounded because `columnCount` multiplies into the prefetch depth, and an
    /// unbounded multiplier is an unbounded work queue.
    public static let maxColumnCount = 8

    /// Largest backing-store scale factor honoured. Apple devices ship 1x-3x;
    /// the extra headroom costs nothing and the cap keeps `scale²` bounded.
    public static let maxScale: Double = 4

    public let width: Double
    public let height: Double
    public let columnCount: Int
    public let scale: Double

    /// The thresholds that separate one `DisplayClass` from the next, in
    /// points² of content area.
    ///
    /// These are **this package's defaults, not Apple hardware specifications.**
    /// They are chosen so a single-column phone-sized surface lands in
    /// `.compact` and a near-square two-pane surface lands in `.regular`. Supply
    /// your own values through `Viewport.classify(area:columnCount:)`'s callers
    /// — or reclassify entirely — to match your real device matrix.
    public static let regularAreaThreshold: Double = 380_000
    public static let expansiveAreaThreshold: Double = 900_000

    /// Creates a viewport, normalising every input.
    ///
    /// - Non-finite or non-positive dimensions become `0`.
    /// - Dimensions above ``maxDimension`` are clamped down.
    /// - `columnCount` is clamped to `1 ... maxColumnCount`; a zero-column
    ///   surface is not a thing, and admitting it would make the column
    ///   multiplier zero and starve the plan.
    /// - `scale` is clamped to `(0, maxScale]`, falling back to `1` for
    ///   non-finite or non-positive input.
    public init(width: Double, height: Double, columnCount: Int, scale: Double = 2) {
        self.width = Viewport.sanitizeDimension(width)
        self.height = Viewport.sanitizeDimension(height)
        self.columnCount = Saturating.clamp(columnCount, to: 1...Viewport.maxColumnCount)
        let sanitizedScale = Saturating.clamp(scale, to: 0...Viewport.maxScale)
        self.scale = sanitizedScale > 0 ? sanitizedScale : 1
    }

    private static func sanitizeDimension(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return Swift.min(value, Viewport.maxDimension)
    }

    /// Content area in points². Provably finite and non-negative.
    public var area: Double { width * height }

    /// Pixel area of the backing store, in device pixels.
    public var backingPixelArea: Double { area * scale * scale }

    /// The capacity tier this viewport falls into.
    public var displayClass: DisplayClass {
        Viewport.classify(area: area, columnCount: columnCount)
    }

    /// Pure classification, exposed so tests and custom policies can reuse it.
    public static func classify(area: Double, columnCount: Int) -> DisplayClass {
        // A surface with a second column is at minimum `.regular` regardless of
        // area: the second pane is a real demand for content the caller never
        // requested, and that is the property the planner cares about.
        let byArea: DisplayClass
        if area >= expansiveAreaThreshold {
            byArea = .expansive
        } else if area >= regularAreaThreshold {
            byArea = .regular
        } else {
            byArea = .compact
        }
        let byColumns: DisplayClass = columnCount >= 3 ? .expansive
            : (columnCount >= 2 ? .regular : .compact)
        return Swift.max(byArea, byColumns)
    }

    /// A zero-area, single-column viewport. What a surface looks like before it
    /// has been measured, and what a NaN-bearing `CGSize` normalises to.
    public static let zero = Viewport(width: 0, height: 0, columnCount: 1, scale: 1)

    public var description: String {
        // `Int(_: Double)` even here: the dimensions are provably finite and
        // in range by the time they are stored, but "every conversion in this
        // package goes through Saturating" is only a useful rule if it has no
        // exceptions a reader has to remember.
        let w = Saturating.int(clamping: width.rounded())
        let h = Saturating.int(clamping: height.rounded())
        return "Viewport(\(w)x\(h) cols:\(columnCount) @\(scale)x -> .\(displayClass))"
    }
}
