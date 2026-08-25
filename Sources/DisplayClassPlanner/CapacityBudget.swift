//
//  CapacityBudget.swift
//  DisplayClassPlanner
//

/// How much concurrent work a surface is entitled to at its current size.
public struct CapacityBudget: Sendable, Hashable, CustomStringConvertible {

    /// Hard ceiling on admitted work, independent of viewport size.
    ///
    /// The in-flight table is keyed by `WorkID` and only grows through
    /// admission, so this constant is what makes "no unbounded growth" a
    /// structural property rather than an assumption about screen sizes.
    public static let maxPrefetchDepth = 512

    /// Hard ceiling on simultaneous requests. Above this, a mobile network
    /// stack spends more time in head-of-line contention than it gains in
    /// parallelism, and every extra slot is another response to decode during
    /// a scroll.
    public static let maxConcurrencyLimit = 24

    /// Number of items the surface may have admitted at once.
    public let prefetchDepth: Int

    /// Number of those that may be executing simultaneously.
    public let concurrencyLimit: Int

    /// Decoded bytes the surface may keep resident.
    public let decodeByteBudget: Int

    /// Creates a budget, clamping every field into a survivable range.
    ///
    /// `concurrencyLimit` has a floor of `1`, not `0`: a zero-slot pipeline
    /// admits work and then never runs it, which presents as a permanently
    /// blank surface rather than as a crash — the worst kind of bug to
    /// diagnose from a crash-free session recording.
    public init(prefetchDepth: Int, concurrencyLimit: Int, decodeByteBudget: Int) {
        self.prefetchDepth = Saturating.clamp(
            prefetchDepth, to: 0...CapacityBudget.maxPrefetchDepth
        )
        self.concurrencyLimit = Saturating.clamp(
            concurrencyLimit, to: 1...CapacityBudget.maxConcurrencyLimit
        )
        self.decodeByteBudget = Swift.max(0, decodeByteBudget)
    }

    /// The budget of a surface that has not been measured yet: admit nothing,
    /// but keep one live slot so the first real plan has somewhere to go.
    public static let empty = CapacityBudget(
        prefetchDepth: 0, concurrencyLimit: 1, decodeByteBudget: 0
    )

    public var description: String {
        "CapacityBudget(depth:\(prefetchDepth) "
            + "concurrency:\(concurrencyLimit) "
            + "decode:\(decodeByteBudget / 1024)KiB)"
    }
}

/// Converts a measured surface into a work budget.
///
/// The seam exists because the right numbers are product decisions, not library
/// decisions. A photo grid and a text-first feed at identical pixel dimensions
/// should not get identical decode budgets, and the planner has no business
/// guessing which one it is embedded in.
public protocol BudgetPolicy: Sendable {
    func budget(for viewport: Viewport) -> CapacityBudget
}

/// The default policy: budgets scale with content area, with every intermediate
/// computed through ``Saturating``.
///
/// **Why area and not "is it a phone".** Device checks stop working the moment
/// the same process can be at two sizes in one session — Split View, Stage
/// Manager, an external display, a fold. Area is the quantity that actually
/// changed, so it is the quantity the budget is derived from.
public struct AreaProportionalBudgetPolicy: BudgetPolicy {

    /// Points² one typical content cell occupies. Used to estimate how many
    /// cells the surface can show at once.
    public let averageCellArea: Double

    /// Multiple of the visible cell count to keep admitted. `2` means "one
    /// screenful visible, one screenful ready".
    public let prefetchMultiplier: Double

    /// Number of items per concurrency slot. Higher means a deeper queue behind
    /// fewer live requests.
    public let itemsPerConcurrencySlot: Int

    /// How many full backing stores' worth of decoded pixels may stay resident.
    public let residentScreenfuls: Double

    /// Bytes per pixel of the decoded representation. `4` for 8-bit RGBA.
    public let bytesPerPixel: Int

    public init(
        averageCellArea: Double = 14_400,      // a 120x120 pt cell
        prefetchMultiplier: Double = 2,
        itemsPerConcurrencySlot: Int = 4,
        residentScreenfuls: Double = 3,
        bytesPerPixel: Int = 4
    ) {
        // Guard the divisors and multipliers at construction so the hot path
        // never has to. A zero `averageCellArea` would be a division by zero;
        // a negative `prefetchMultiplier` would invert the budget.
        self.averageCellArea = averageCellArea.isFinite && averageCellArea > 0
            ? averageCellArea : 14_400
        self.prefetchMultiplier = Saturating.clamp(prefetchMultiplier, to: 0...64)
        self.itemsPerConcurrencySlot = Swift.max(1, itemsPerConcurrencySlot)
        self.residentScreenfuls = Saturating.clamp(residentScreenfuls, to: 0...64)
        self.bytesPerPixel = Saturating.clamp(bytesPerPixel, to: 1...16)
    }

    public func budget(for viewport: Viewport) -> CapacityBudget {
        // `viewport.area` is finite and >= 0 by construction (see Viewport),
        // and `averageCellArea` is > 0 by construction above, so this division
        // is defined for every reachable input.
        let visibleCells = viewport.area / averageCellArea
        let depthDouble = visibleCells * prefetchMultiplier
        let depth = Saturating.int(clamping: depthDouble)

        let concurrency = Saturating.dividing(
            depth, by: itemsPerConcurrencySlot, fallback: 1
        )

        // backingPixelArea is bounded by maxDimension² * maxScale², so this
        // product is finite; `Saturating.int` handles the range.
        let residentPixels = viewport.backingPixelArea * residentScreenfuls
        let decodeBytes = Saturating.multiplying(
            Saturating.int(clamping: residentPixels), bytesPerPixel
        )

        return CapacityBudget(
            prefetchDepth: depth,
            concurrencyLimit: concurrency,
            decodeByteBudget: decodeBytes
        )
    }
}
