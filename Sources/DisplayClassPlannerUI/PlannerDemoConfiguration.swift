//
//  PlannerDemoConfiguration.swift
//  DisplayClassPlannerUI
//
//  The whole module is compiled out where SwiftUI is unavailable, so the
//  package still builds and tests on Linux CI with the core module intact.
//

#if canImport(SwiftUI)

import DisplayClassPlanner

/// Everything the demo surface needs that the *host app* should own.
///
/// The library ships defaults so the view is usable standalone, but the numbers
/// here — how big a cell is, how many columns each display class gets, what the
/// catalogue contains — are product decisions. Passing them in keeps them out
/// of the library, and gives the host app a real reason to depend on
/// `DisplayClassPlanner` directly rather than only on the UI module.
public struct PlannerDemoConfiguration: Sendable {

    /// The viewports the demo can switch between, in ascending capacity order.
    public let stages: [Stage]

    /// Budget policy handed to the planner.
    public let budgetPolicy: any BudgetPolicy

    /// Hysteresis policy handed to the planner.
    public let debouncePolicy: TransitionDebouncer.Policy

    /// Produces the work the surface wants at a given viewport.
    ///
    /// `@Sendable` because the planner is an actor and this may be evaluated
    /// off the main actor.
    public let catalog: @Sendable (Viewport) -> [WorkItem]

    public struct Stage: Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public let viewport: Viewport

        public init(id: String, title: String, viewport: Viewport) {
            self.id = id
            self.title = title
            self.viewport = viewport
        }
    }

    public init(
        stages: [Stage],
        budgetPolicy: any BudgetPolicy = AreaProportionalBudgetPolicy(),
        debouncePolicy: TransitionDebouncer.Policy = .default,
        catalog: @escaping @Sendable (Viewport) -> [WorkItem]
    ) {
        // An empty stage list would render a control with nothing in it and a
        // planner that can never be driven. Fall back rather than ship a dead
        // screen.
        self.stages = stages.isEmpty ? PlannerDemoConfiguration.defaultStages : stages
        self.budgetPolicy = budgetPolicy
        self.debouncePolicy = debouncePolicy
        self.catalog = catalog
    }

    // MARK: - Defaults

    /// Three surfaces spanning the three display classes.
    ///
    /// The dimensions are *illustrative point sizes chosen to land in each
    /// class* under `Viewport`'s default thresholds — they are not Apple
    /// hardware specifications and are not claimed to be.
    public static let defaultStages: [Stage] = [
        Stage(
            id: "cover",
            title: "Cover",
            viewport: Viewport(width: 420, height: 900, columnCount: 1, scale: 3)
        ),
        Stage(
            id: "inner",
            title: "Inner",
            viewport: Viewport(width: 760, height: 820, columnCount: 2, scale: 3)
        ),
        Stage(
            id: "external",
            title: "External",
            viewport: Viewport(width: 1180, height: 900, columnCount: 3, scale: 2)
        ),
    ]

    /// A catalogue of `count` synthetic media items whose priorities depend on
    /// the viewport, which is the property that makes an unfold a *capacity*
    /// event rather than a layout one: the same content list yields more
    /// `.visible` work on a bigger surface.
    public static func syntheticCatalog(
        count: Int = 48,
        cellArea: Double = 14_400,
        bytesPerCell: Int = 900_000
    ) -> @Sendable (Viewport) -> [WorkItem] {
        // Clamp once, here, so the returned closure does no defensive work in
        // what may be a hot path.
        let safeCount = Saturating.clamp(count, to: 0...CapacityBudget.maxPrefetchDepth)
        let safeCellArea = cellArea.isFinite && cellArea > 0 ? cellArea : 14_400
        let safeBytes = Swift.max(0, bytesPerCell)

        return { viewport in
            guard safeCount > 0 else { return [] }
            // How many cells this surface can actually show at once.
            let onScreen = Saturating.clamp(
                Saturating.int(clamping: viewport.area / safeCellArea),
                to: 0...safeCount
            )
            let adjacentEnd = Saturating.clamp(
                Saturating.multiplying(onScreen, 2), to: 0...safeCount
            )

            var items: [WorkItem] = []
            items.reserveCapacity(safeCount)
            for index in 0..<safeCount {
                let priority: WorkPriority
                if index < onScreen {
                    priority = .visible
                } else if index < adjacentEnd {
                    priority = .adjacent
                } else {
                    priority = .speculative
                }
                items.append(
                    WorkItem(
                        id: WorkID("asset-\(index)"),
                        priority: priority,
                        index: index,
                        estimatedDecodeBytes: safeBytes
                    )
                )
            }
            return items
        }
    }

    /// A ready-to-use configuration, so `CapacityPlannerView()` renders
    /// something meaningful with no arguments.
    public static let `default` = PlannerDemoConfiguration(
        stages: defaultStages,
        catalog: syntheticCatalog()
    )
}

#endif
