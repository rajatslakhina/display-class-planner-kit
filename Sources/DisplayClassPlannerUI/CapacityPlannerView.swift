//
//  CapacityPlannerView.swift
//  DisplayClassPlannerUI
//

#if canImport(SwiftUI)

import SwiftUI
import DisplayClassPlanner

/// The demo surface: switch display class, watch the plan diff.
///
/// Everything rendered here comes from a single ``PlannerSnapshot`` taken
/// inside the actor, so the generation, the budget and the in-flight grid on
/// screen are always values that were true at the same instant.
public struct CapacityPlannerView: View {

    @State private var model: CapacityPlannerViewModel

    public init(configuration: PlannerDemoConfiguration = .default) {
        _model = State(initialValue: CapacityPlannerViewModel(configuration: configuration))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headline
                    stagePicker
                    budgetPanel
                    scenarioButtons
                    transitionPanel
                    grid
                    eventLog
                }
                .padding(20)
            }
            .navigationTitle("Display-Class Planner")
            .background(Color(white: 0.97))
        }
        .task { await model.run() }
    }

    // MARK: - Sections

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("An unfold is a capacity event, not a layout event.")
                .font(.headline)
            Text(model.activityLine)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SURFACE").font(.caption2).foregroundStyle(.secondary)
            Picker("Surface", selection: pickerBinding) {
                ForEach(model.stages) { stage in
                    Text(stage.title).tag(stage.id)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunningScenario)

            Text(model.snapshot.committed.description)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var pickerBinding: Binding<String> {
        Binding(
            get: { model.selectedStageID },
            set: { newValue in Task { await model.select(stageID: newValue) } }
        )
    }

    private var budgetPanel: some View {
        let budget = model.snapshot.budget
        let snapshot = model.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            Text("BUDGET · GENERATION \(snapshot.generation)")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                metric("depth", "\(budget.prefetchDepth)")
                metric("live", "\(budget.concurrencyLimit)")
                metric("decode", "\(budget.decodeByteBudget / 1_048_576) MiB")
                metric("in flight", "\(snapshot.inFlight.count)")
            }
            HStack(spacing: 10) {
                metric("storms absorbed", "\(snapshot.withdrawnStorms)")
                metric("salvaged", "\(snapshot.salvagedResponses)")
                metric("cancelled", "\(snapshot.cancelledTotal)")
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var scenarioButtons: some View {
        VStack(spacing: 8) {
            Button("Run fold storm (contract, then revert)") {
                Task { await model.runFoldStorm() }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

            Button("Run salvage scenario (issue → cancel → re-admit → late response)") {
                Task { await model.runSalvageScenario() }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            Button("Complete highest-priority request") {
                Task { await model.completeNext() }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .disabled(model.isRunningScenario)
    }

    @ViewBuilder
    private var transitionPanel: some View {
        if let transition = model.lastTransition {
            VStack(alignment: .leading, spacing: 8) {
                Text("LAST TRANSITION · GEN \(transition.generation)")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    metric("retained", "\(transition.retained.count)")
                    metric("repriorit.", "\(transition.reprioritized.count)")
                    metric("cancelled", "\(transition.cancelled.count)")
                    metric("admitted", "\(transition.admitted.count)")
                }
                let violations = transition.validate()
                Text(
                    violations.isEmpty
                        ? "Invariants hold: nothing cancelled was also kept."
                        : "INVARIANT VIOLATIONS: \(violations.map(\.description).joined(separator: "; "))"
                )
                .font(.caption2)
                .foregroundStyle(violations.isEmpty ? .green : .red)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var grid: some View {
        let rows = model.catalogRows
        return VStack(alignment: .leading, spacing: 8) {
            Text("CATALOG (\(rows.filter(\.isInFlight).count)/\(rows.count) IN FLIGHT)")
                .font(.caption2).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No catalogue items at this surface size.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 34), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(rows) { row in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color(for: row))
                            .frame(height: 34)
                            .overlay(
                                Text("\(row.item.index)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(row.isInFlight ? .white : .secondary)
                            )
                    }
                }
            }
            legend
        }
    }

    private func color(for row: CapacityPlannerViewModel.CatalogRow) -> Color {
        guard let priority = row.inFlightPriority else { return Color(white: 0.9) }
        switch priority {
        case .visible: return .blue
        case .adjacent: return .teal
        case .speculative: return .gray
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendChip(.blue, "visible")
            legendChip(.teal, "adjacent")
            legendChip(.gray, "speculative")
            legendChip(Color(white: 0.9), "not admitted")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendChip(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    @ViewBuilder
    private var eventLog: some View {
        let events = model.snapshot.events
        VStack(alignment: .leading, spacing: 6) {
            Text("PLANNER LOG (LAST \(min(events.count, 12)))")
                .font(.caption2).foregroundStyle(.secondary)
            if events.isEmpty {
                Text("Nothing yet.").font(.caption2).foregroundStyle(.secondary)
            } else {
                // `suffix` is bounds-safe for any count, including 0.
                ForEach(Array(events.suffix(12).enumerated()), id: \.offset) { entry in
                    Text("g\(entry.element.generation) \(entry.element.kind.rawValue) — \(entry.element.detail)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

#Preview {
    CapacityPlannerView()
}

#endif
