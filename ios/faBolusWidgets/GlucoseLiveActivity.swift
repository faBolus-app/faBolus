import WidgetKit
import SwiftUI
import ActivityKit

// Portions adapted from luka-ios (github.com/kylebshr/luka-ios), MIT License.
// Copyright (c) 2024 Kyle Bashour.
//
// Lifts the Dynamic Island region split (compactLeading/compactTrailing/minimal/expanded) and the
// optional-arrow-view pattern from `LukaWidget/ReadingActivityConfiguration.swift`, rebound to
// faBolus's own `WidgetSnapshot` projection (`FaBolusGlucoseAttributes.ContentState`) and the
// existing `WidgetUI`/`Sparkline` helpers. Stripped: `Defaults`/`Dexcom`/`SmartStackMargins`, the
// offline/debug/restart-intent machinery, and the HDR exposure-adjust tint — none apply here (this
// tracer slice is glucose-only, no CarPlay/badge/interactivity yet). See 05-REFERENCE-COMPARISON.md §2.

/// The glucose Live Activity + Dynamic Island (D-01) — glucose-only tracer slice (05-01). Pump
/// fields, per-field toggles, CarPlay, the badge, and interactivity expand out from this proven
/// slice in later plans (05-02..05-05).
struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FaBolusGlucoseAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .widgetURL(FaBolusDeepLink.open)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedGlucoseView(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedArrowView(context: context)
                }
                DynamicIslandExpandedRegion(.center) {
                    ExpandedAgeView(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Sparkline(points: context.state.recentPoints).frame(height: 40)
                }
            } compactLeading: {
                CompactGlucoseView(context: context)
            } compactTrailing: {
                CompactArrowView(context: context)
            } minimal: {
                CompactGlucoseView(context: context)
            }
            .widgetURL(FaBolusDeepLink.open)
        }
    }
}

/// Convenience readers shared by every region below — ALL derive staleness from `context.isStale`
/// (OS-enforced via the manager's `staleDate = glucoseDate + staleAfter`, D-06/D-07), never from a
/// recomputed local policy, and ALWAYS route the number through the Phase-4 mmol funnel (D-09).
private extension ActivityViewContext<FaBolusGlucoseAttributes> {
    var unit: WidgetGlucoseUnit { WidgetGlucoseUnit(wireToken: state.displayUnitToken) }
    /// The glucose number, or "--" when unknown/non-positive — never a raw mg/dL literal (D-09).
    var glucoseText: String {
        guard let g = state.glucose, g > 0 else { return "--" }
        return unit.format(mgdl: g)
    }
    /// Greyed whenever OS-enforced `isStale`, else colored by the same clinical range every other
    /// widget uses (`WidgetSnapshot.rangeCategory` + `WidgetUI.glucoseColor`).
    var glucoseColor: Color {
        isStale ? .gray : WidgetUI.glucoseColor(WidgetSnapshot.rangeCategory(state.glucose))
    }
    /// C8 — never synthesized. "" whenever `isStale`, else the state's carried arrow verbatim
    /// (the state itself already suppressed it at publish time; this re-applies the SAME rule at
    /// render time, since staleness can advance past `staleDate` without a new publish).
    var arrow: String { isStale ? "" : state.trendArrow }
}

// MARK: - Lock Screen

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(context.glucoseText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(context.glucoseColor)
                    Text(context.arrow).font(.title3).foregroundStyle(context.glucoseColor)
                }
                // The SAMPLE age (native relative style — 05-RESEARCH.md Pitfall #4/D-07), orange
                // once stale, so an old reading is never mistaken for current (C7).
                if let d = context.state.glucoseDate {
                    Text(d, style: .relative).font(.caption2)
                        .foregroundStyle(context.isStale ? .orange : .secondary)
                } else {
                    Text(context.unit.unitLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Sparkline(points: context.state.recentPoints).frame(width: 90, height: 34)
        }
        .padding(16)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Dynamic Island compact/minimal

private struct CompactGlucoseView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        Text(context.glucoseText)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(context.glucoseColor)
    }
}

private struct CompactArrowView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        // Optional/empty view when there's no arrow — mirrors luka's optional-image approach so
        // "no trend" renders as no glyph at all, never a synthesized flat one (C8).
        if !context.arrow.isEmpty {
            Text(context.arrow)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(context.glucoseColor)
        }
    }
}

// MARK: - Dynamic Island expanded

private struct ExpandedGlucoseView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        Text(context.glucoseText)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(context.glucoseColor)
    }
}

private struct ExpandedArrowView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        if !context.arrow.isEmpty {
            Text(context.arrow)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(context.glucoseColor)
        }
    }
}

private struct ExpandedAgeView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        if let d = context.state.glucoseDate {
            Text(d, style: .relative).font(.caption2)
                .foregroundStyle(context.isStale ? .orange : .secondary)
        }
    }
}
