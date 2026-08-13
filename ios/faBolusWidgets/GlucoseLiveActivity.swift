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
                // Phase 5 pump surfaces (D-17, 05-02) — IOB stacked below glucose in `.leading`,
                // Control-IQ stacked below the arrow in `.trailing` (plan's discretion: "basal OR
                // Control-IQ" — Control-IQ chosen as the stronger faBolus-differentiator summary).
                // `.center`/`.bottom` are untouched — glucose age + Sparkline stay the tracer's own.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        ExpandedGlucoseView(context: context)
                        PumpChipView(chip: WidgetUI.iobChip(context.state))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        ExpandedArrowView(context: context)
                        PumpChipView(chip: WidgetUI.controlIQChip(context.state))
                    }
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
        VStack(alignment: .leading, spacing: 8) {
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

            // Phase 5 pump surfaces (D-17, 05-02) — fixed HUD-priority chip row (per-field user
            // toggles + adaptive 0..N composition arrive in 05-04). IOB carries its OWN op-109 age
            // when stale; basal/Control-IQ are dateless and grey as a cluster off `pumpLinkStale`,
            // with a single "Synced N ago" caption for the whole cluster rather than a per-chip age
            // (there is no per-field stamp to show).
            HStack(spacing: 8) {
                PumpChipView(chip: WidgetUI.iobChip(context.state), ageDate: context.state.iobStale ? context.state.iobDate : nil)
                PumpChipView(chip: WidgetUI.basalChip(context.state))
                PumpChipView(chip: WidgetUI.controlIQChip(context.state))
            }
            if context.state.pumpLinkStale {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    // `.relative` already renders "N ago" for a past date (e.g. "2 hours ago") —
                    // never a manually-concatenated "ago" suffix, matching every other age caption
                    // in this file/`StatusWidget.swift`/`GlucoseWidget.swift`.
                    (Text("Synced ") + Text(context.state.updatedAt, style: .relative))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// A pump-field chip (icon + value), with an optional age caption below it when the field carries
/// its OWN staleness stamp (IOB only — the dateless fields render the cluster-wide "Synced N ago"
/// caption instead, at the call site). Mirrors `StatusPillsView.pill`'s icon+value composition,
/// simplified to the Label-role single line (05-UI-SPEC.md typography contract).
private struct PumpChipView: View {
    let chip: WidgetUI.PumpChip
    var ageDate: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: chip.icon).foregroundStyle(chip.tint)
                    .accessibilityHidden(true)
                Text(chip.value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(chip.tint)
            }
            if let d = ageDate {
                Text(d, style: .relative).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ageDate != nil ? "\(chip.value), stale" : chip.value)
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
