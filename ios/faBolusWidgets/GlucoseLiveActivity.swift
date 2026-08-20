import WidgetKit
import SwiftUI
import ActivityKit
import faBolusCore
import faBolusDesign

// Portions adapted from luka-ios (github.com/kylebshr/luka-ios), MIT License.
// Copyright (c) 2024 Kyle Bashour.
//
// Lifts the Dynamic Island region split (compactLeading/compactTrailing/minimal/expanded) and the
// optional-arrow-view pattern from `LukaWidget/ReadingActivityConfiguration.swift`, rebound to
// faBolus's own `WidgetSnapshot` projection (`FaBolusGlucoseAttributes.ContentState`) and the
// existing `WidgetUI`/`Sparkline` helpers. Stripped: `Defaults`/`Dexcom`/`SmartStackMargins`, the
// offline/debug/restart-intent machinery, and the HDR exposure-adjust tint. See
// 05-REFERENCE-COMPARISON.md §2.
//
// Portions adapted from Loop (github.com/LoopKit/Loop), MIT License.
// Copyright (c) 2015 Nathan Racklyeft. Copyright (c) 2016 LoopKit Authors.
//
// The CarPlay `.small` gating below (reading `@Environment(\.activityFamily)`) adapts Loop's
// `GlucoseLiveActivityConfiguration` `AdaptiveLockScreenView` split pattern — content is
// faBolus-original, not copied, and none of Loop's named color assets / `SwiftCharts` are used
// (05-UI-SPEC.md Registry Safety).

/// The glucose Live Activity + Dynamic Island (D-01). Every region below renders through
/// `LiveActivityComposer.compose(selection:state:region:)` (05-04, D-17a) so the Lock Screen /
/// Dynamic Island / CarPlay layout adapts to ANY 0..N user-selected field subset, with a documented
/// empty-selection fallback — never a fixed field set.
///
/// 09.26-06 (D-08): `faBolusWidgets`' deployment target is unconditionally 18.0 (`project.yml`), the
/// SAME floor as the host app — there is no iOS-17 build of this extension to keep a `@available`
/// split for. `CarPlayGatedView` below (which reads `@Environment(\.activityFamily)`, an iOS-18
/// environment key) and `.supplementalActivityFamilies([.small])` are therefore called
/// UNCONDITIONALLY from this single `Widget` conformer — the previous two-widget split
/// (`GlucoseLiveActivity` iOS-17-floor + a separate `@available(iOS 18.0, *) GlucoseLiveActivityCarPlay`,
/// picked via a bundle-level `if #available`) existed only to work around `Widget.body` having no
/// `@available`-branching result builder for a MIXED-floor extension; with a single 18.0 floor for the
/// whole extension that mixed-floor problem no longer exists, so the split collapsed into one widget.
struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FaBolusGlucoseAttributes.self) { context in
            CarPlayGatedView(context: context)
                .widgetURL(FaBolusDeepLink.open)
        } dynamicIsland: { context in
            glucoseDynamicIslandConfiguration(context: context)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Dynamic Island region tree, factored out so it is written exactly once and shared by every
/// presentation of this single widget (Lock Screen, Dynamic Island, and the CarPlay `.small`
/// supplemental family all resolve through the same `ActivityConfiguration`'s `dynamicIsland` closure).
@MainActor
private func glucoseDynamicIslandConfiguration(
    context: ActivityViewContext<FaBolusGlucoseAttributes>
) -> DynamicIsland {
    DynamicIsland {
        // Phase 09.26-05 (D-06/UI-SPEC "Dynamic Island — expanded") — EACH expanded sub-region
        // branches on `liveActivityStyle`. "classic" (or unrecognized) renders the EXISTING
        // composer-driven tree verbatim; "fullBleed" distributes per the UI-SPEC's 4-slot table
        // (center = BG+arrow, leading = time-since + 1st bottom-row field, trailing = top-right
        // slot + 2nd bottom-row field, bottom = the 44pt plot + compact action row).
        DynamicIslandExpandedRegion(.leading) {
            if context.state.liveActivityStyle == "fullBleed" {
                fullBleedDIExpandedLeading(context: context)
            } else {
                let composed = LiveActivityComposer.compose(
                    selection: context.state.selectedFields, state: context.state, region: .expanded)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(composed.dropFirst().prefix(2)), id: \.id) { field in
                        ComposedFieldView(context: context, field: field, role: .label)
                    }
                }
            }
        }
        DynamicIslandExpandedRegion(.trailing) {
            if context.state.liveActivityStyle == "fullBleed" {
                fullBleedDIExpandedTrailing(context: context)
            } else {
                let composed = LiveActivityComposer.compose(
                    selection: context.state.selectedFields, state: context.state, region: .expanded)
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(Array(composed.dropFirst(3).prefix(2)), id: \.id) { field in
                        ComposedFieldView(context: context, field: field, role: .label)
                    }
                }
            }
        }
        DynamicIslandExpandedRegion(.center) {
            if context.state.liveActivityStyle == "fullBleed" {
                fullBleedDIExpandedCenter(context: context)
            } else {
                let composed = LiveActivityComposer.compose(
                    selection: context.state.selectedFields, state: context.state, region: .expanded)
                if let first = composed.first {
                    ComposedFieldView(context: context, field: first, role: .display)
                }
            }
        }
        DynamicIslandExpandedRegion(.bottom) {
            if context.state.liveActivityStyle == "fullBleed" {
                fullBleedDIExpandedBottom(context: context)
            } else {
                let bottom = LiveActivityComposer.compose(
                    selection: context.state.selectedFields, state: context.state, region: .bottom)
                VStack(spacing: 6) {
                    if bottom.first?.id == "sparkline" {
                        Sparkline(points: context.state.recentPoints).frame(height: 40)
                    }
                    LAActionRow(compact: true)
                }
            }
        }
    } compactLeading: {
        // INVARIANT (D-06/09.26-UI-SPEC "compact leading/trailing + minimal"): these capacity-1
        // regions render byte-identically regardless of `liveActivityStyle` — too small (~20x20pt)
        // for a legible curve, so full-bleed's differentiator (the plot) is reserved for the
        // surfaces with room for it (DI expanded + Lock Screen expanded). Do NOT branch this on
        // style; that would be "fixing" a deliberate design decision, not a bug.
        CompactLeadingView(context: context)
    } compactTrailing: {
        // Style-agnostic — see `compactLeading` invariant comment above.
        CompactTrailingView(context: context)
    } minimal: {
        // Style-agnostic — see `compactLeading` invariant comment above.
        MinimalRegionView(context: context)
    }
    .widgetURL(FaBolusDeepLink.open)
}

// MARK: - DI-expanded full-bleed distribution (Phase 09.26-05, D-06/D-16/D-17)

/// `.center` (09.26-UI-SPEC "Dynamic Island — expanded" table): the BG numeral + trend arrow ONLY —
/// no time-since caption or band here (those live in `.leading`/aren't shown at this scale; DI has
/// no room for a second stacked line under `.center` the way the Lock Screen's top-left block does).
/// Zone-colored, greys/drops the arrow when stale via the SAME `context.glucoseColor`/`context.arrow`
/// extension every other presentation reuses verbatim (D-04 — no second staleness rule).
@MainActor
@ViewBuilder
private func fullBleedDIExpandedCenter(
    context: ActivityViewContext<FaBolusGlucoseAttributes>
) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(context.glucoseText)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(context.glucoseColor)
        if !context.arrow.isEmpty {
            Text(context.arrow)
                .font(.title3)
                .foregroundStyle(context.glucoseColor)
        }
    }
}

/// `.leading` (capacity 2): 1) the time-since-CGM caption (D-16, relocated here — DI's `.center` has
/// no room for a second stacked line, unlike the Lock Screen's "directly below the BG" placement);
/// 2) the first full-bleed customizable bottom-row field (`composeFullBleedBottomRowFields`, shared
/// with the Lock Screen bottom row).
@MainActor
@ViewBuilder
private func fullBleedDIExpandedLeading(
    context: ActivityViewContext<FaBolusGlucoseAttributes>
) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        if let d = context.state.glucoseDate {
            // Phase 09.26 (UAT fix, Defect 5) — see `GlucoseNumeralView`'s own call site below for
            // the full rationale; `Text(_, style: .relative)` showed "0 sec" for a fresh reading.
            Text(LAMetrics.friendlyAge(date: d, now: Date())).font(.caption2)
                .foregroundStyle(context.isStale ? .orange : .secondary)
        }
        if let field = composeFullBleedBottomRowFields(context: context).first {
            ComposedFieldView(context: context, field: field, role: .label)
        }
    }
}

/// Phase 09.26 (WR-01 review fix) — the top-right slot's staleness tint, applied at BOTH render
/// call sites (Lock Screen `fullBleedTopTrailingOverlay` and Dynamic Island
/// `fullBleedDIExpandedTrailing`) so the corner never contradicts the greyed-out BG numeral/arrow/
/// IOB chip beside it on the same card. Mirrors `WidgetUI.iobChip`'s own `iobStale` tint exactly for
/// the `"iob"`/`"iobDelta"` fields (the only ones carrying their own dedicated staleness flag), and
/// falls back to the card-wide `context.isStale` → `.secondary` treatment (mirroring the
/// arrow/band-indicator greying) for every other field/composite. This makes `LAMetrics
/// .topRightText`'s doc comment ("the caller applies tint via the same `iobStale` flag") true.
private func topRightTint(
    field: String, state: FaBolusGlucoseAttributes.ContentState, isStale: Bool
) -> Color {
    if (field == "iob" || field == "iobDelta") && state.iobStale {
        return AppTheme.low
    }
    return isStale ? .secondary : .primary
}

/// `.trailing` (capacity 2): 1) the top-right selectable slot's content (D-05/D-15) — the SAME
/// `LAMetrics.topRightText` derivation the Lock Screen top-right overlay uses; 2) the second
/// full-bleed customizable bottom-row field.
@MainActor
@ViewBuilder
private func fullBleedDIExpandedTrailing(
    context: ActivityViewContext<FaBolusGlucoseAttributes>
) -> some View {
    VStack(alignment: .trailing, spacing: 8) {
        if let text = LAMetrics.topRightText(field: context.state.topRightField, state: context.state, now: Date()) {
            Text(text)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(topRightTint(
                    field: context.state.topRightField, state: context.state, isStale: context.isStale))
        }
        if let field = composeFullBleedBottomRowFields(context: context).dropFirst().first {
            ComposedFieldView(context: context, field: field, role: .label)
        }
    }
}

/// `.bottom`: `FullBleedGlucosePlot` at the expanded-island width, 44pt tall (up from Classic's
/// fixed 40pt `Sparkline`) — passed the SAME parameter surface (chrome toggles, plot range, floor/
/// ceiling) the Lock Screen full-bleed body passes, so a Settings change is visible on EVERY
/// full-bleed presentation, not just the Lock Screen — plus the optional Bolus-shortcut pill beneath
/// it.
///
/// Phase 09.26-07 (D-22): when `showBolusShortcut` is on, the compact `LABolusShortcutPill` renders
/// beneath the plot, matching the Lock Screen full-bleed body. Phase 09.26 (UAT fix, Defect 7 —
/// owner directive): the always-available `LAActionRow` (Snooze/Refresh) that used to render
/// alongside the pill is REMOVED — the pill (when on) is this region's only interactive control; an
/// ambient glucose card has no reason to surface Snooze/Refresh.
@MainActor
@ViewBuilder
private func fullBleedDIExpandedBottom(
    context: ActivityViewContext<FaBolusGlucoseAttributes>
) -> some View {
    VStack(spacing: 6) {
        FullBleedGlucosePlot(
            points: context.state.recentPoints,
            floorMgdl: context.state.plotFloorMgdl,
            ceilingMgdl: context.state.plotCeilingMgdl,
            currentGlucose: context.state.glucose,
            isStale: context.isStale,
            plotRangeHours: context.state.plotRangeHours,
            showXAxisLine: context.state.showXAxisLine,
            showYAxisLine: context.state.showYAxisLine,
            showXAxisTicks: context.state.showXAxisTicks,
            showYAxisTicks: context.state.showYAxisTicks,
            showRangeLines: context.state.showRangeLines)
            .frame(height: 44)
        if context.state.showBolusShortcut {
            LABolusShortcutPill(compact: true)
        }
    }
}

/// The full-bleed bottom row's composed fields (D-13, 09.26-UI-SPEC.md "Bottom row") — shared by the
/// Lock Screen bottom row AND the DI-expanded `.leading`/`.trailing` full-bleed slots above (09.26-05).
/// The SAME `LiveActivityComposer.compose(...)` the Classic style uses, minus the structural
/// "glucose"/"sparkline"/"minimal" pseudo-ids (BG is top-left/center, the curve is the background —
/// always shown, not optional composed fields in full-bleed) and minus whatever id is currently bound
/// to the top-right slot (dedupe — never show the same fact twice).
///
/// Phase 09.26 (WR-02 review fix): when `topRightField == "iobDelta"` (the default,
/// `LATopRightFieldVocabulary.defaultId`), the top-right slot is a COMPOSITE that actually renders
/// BOTH the `"iob"` and `"delta"` component facts (`LAMetrics.topRightText`'s `"iobDelta"` case) —
/// excluding only the literal string `"iobDelta"` from the bottom row (which is never a real field
/// id a `selectedFields` selection can carry) left `"iob"` un-deduped, so a completely untouched
/// fresh install (default `topRightField` "iobDelta" + default `selectedFields` including "iob")
/// rendered the SAME IOB fact twice: once in the top-right corner, once as a bottom-row chip. The
/// dedupe set now names the composite's actual rendered components, not just the composite's own id.
private func composeFullBleedBottomRowFields(
    context: ActivityViewContext<FaBolusGlucoseAttributes>
) -> [LAField] {
    let composed = LiveActivityComposer.compose(
        selection: context.state.selectedFields, state: context.state, region: .lockScreen)
    let topRightComponents: Set<String> = context.state.topRightField == "iobDelta"
        ? ["iob", "delta"] : [context.state.topRightField]
    return composed.filter {
        $0.id != "glucose" && $0.id != "sparkline" && $0.id != "minimal"
            && !topRightComponents.contains($0.id)
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
    /// widget uses. Phase 09.1 (D-03) — the audit CRITICAL LA site: classifies via
    /// `faBolusCore.GlucoseRange.classify` and colors via `faBolusDesign.AppTheme
    /// .glucoseColor(_:stale:)`, byte-identical to the deleted `WidgetUI.glucoseColor` switch (an
    /// unknown/missing reading greys exactly as before).
    var glucoseColor: Color {
        guard let g = state.glucose else { return .gray }
        return AppTheme.glucoseColor(g, stale: isStale)
    }
    /// CR-01 (09.29 review): restored ONLY to feed the VoiceOver zone word that the deleted
    /// `BandIndicator(...)` used to speak via its own `.accessibilityLabel(shortLabel)` — no visual
    /// glyph is reintroduced. `nil` when there is no reading to classify (mirrors `glucoseColor`'s
    /// grey-on-missing fallback).
    var glucoseBand: GlucoseRange? {
        state.glucose.map(GlucoseRange.classify)
    }
    /// C8 — never synthesized. "" whenever `isStale`, else the state's carried arrow verbatim
    /// (the state itself already suppressed it at publish time; this re-applies the SAME rule at
    /// render time, since staleness can advance past `staleDate` without a new publish).
    var arrow: String { isStale ? "" : state.trendArrow }
}

// MARK: - Adaptive field rendering (D-17a, 05-04)

/// Renders one field resolved by `LiveActivityComposer.compose(...)`. The three synthetic pseudo-ids
/// ("glucose"/"sparkline"/"minimal") get their own dedicated view; every other id resolves through
/// `WidgetUI.chip(for:_:)`. `role` controls typography per 05-UI-SPEC.md (`.display` = the 34pt Lock
/// Screen/DI-expanded-center numeral, `.label` = the 15pt chip row, `.heading` = the 16pt compact/
/// minimal/CarPlay-small single-field regions, which never show a text label — icon + value only).
private struct ComposedFieldView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    let field: LAField
    var role: FieldRole = .heading

    enum FieldRole { case display, heading, label }

    var body: some View {
        switch field.id {
        case "glucose":
            GlucoseNumeralView(context: context, role: role)
        case "sparkline":
            Sparkline(points: context.state.recentPoints).frame(height: 40)
        case "minimal":
            if role == .heading {
                Image(systemName: "drop.fill").foregroundStyle(.secondary)
            } else {
                MinimalFallbackView(context: context)
            }
        default:
            if let chip = WidgetUI.chip(for: field.id, context.state) {
                if role == .heading {
                    // Compact/minimal DI regions + CarPlay `.small`: glyph + value only, no field
                    // label (05-UI-SPEC.md typography contract — labels appear ONLY on the Lock
                    // Screen banner).
                    HStack(spacing: 4) {
                        Image(systemName: chip.icon).foregroundStyle(chip.tint)
                        Text(chip.value)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(chip.tint)
                    }
                } else {
                    PumpChipView(chip: chip, ageDate: field.id == "iob" && context.state.iobStale ? context.state.iobDate : nil)
                }
            }
        }
    }
}

/// The glucose numeral + trend arrow, sized per `role` (Display 34pt vs. Heading 16pt,
/// 05-UI-SPEC.md Typography). Includes the sample-age caption below it ONLY at `.display` role —
/// the compact/minimal regions have no room for a second line.
private struct GlucoseNumeralView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var role: ComposedFieldView.FieldRole = .heading

    /// CR-01 (09.29 review): the spoken value+trend(+band) sentence, mirroring
    /// `StatusRingView.a11yLabel` — speaks the band word for a live (non-stale) reading only, the
    /// same gating the deleted `BandIndicator(...)` call site used for its visual glyph, so VoiceOver
    /// never depends on zone color alone.
    private var numeralA11yLabel: String {
        let band = context.isStale ? nil : context.glucoseBand
        return band.map { "\(context.glucoseText), \(context.arrow), \($0.shortLabel)" }
            ?? "\(context.glucoseText), \(context.arrow)"
    }

    var body: some View {
        VStack(alignment: role == .display ? .leading : .center, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(context.glucoseText)
                    .font(.system(size: role == .display ? 34 : 16, weight: .bold, design: .rounded))
                    .foregroundStyle(context.glucoseColor)
                if !context.arrow.isEmpty {
                    Text(context.arrow)
                        .font(role == .display ? .title3 : .system(size: 16, weight: .bold))
                        .foregroundStyle(context.glucoseColor)
                }
            }
            // CR-01: combine the value+arrow into one spoken element carrying the band word back
            // (the deleted BandIndicator was the only VoiceOver source for it on every region this
            // view backs); the sample-age caption below (`.display` only) stays a separate element.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(numeralA11yLabel)
            if role == .display {
                if let d = context.state.glucoseDate {
                    // Phase 09.26 (UAT fix, Defect 5) — `Text(_, style: .relative)` renders a live-
                    // ticking numeric duration ("0 sec", "1 min") and never emits "now"; for a
                    // just-arrived reading it showed the confusing "0 sec". `LAMetrics.friendlyAge`
                    // is a static "now"/"Nm"/"Nh" string instead — it doesn't auto-tick between LA
                    // re-publishes, an acceptable trade-off given the re-publish cadence.
                    Text(LAMetrics.friendlyAge(date: d, now: Date())).font(.caption2)
                        .foregroundStyle(context.isStale ? .orange : .secondary)
                } else if context.state.showUnitLabel {
                    // Owner-requested toggle: this fallback caption (no reading yet, so no age to
                    // show) is the only persistent unit-label text this Live Activity renders — gate
                    // it on the flag; when off, no caption is shown here at all.
                    Text(context.unit.unitLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The documented empty-selection fallback (05-UI-SPEC.md Copywriting Contract): a minimal faBolus
/// glyph + the connection line — "Synced {age} ago" / "Disconnected" — never a blank card.
private struct MinimalFallbackView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "drop.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            if context.state.connected {
                (Text("Synced ") + Text(context.state.updatedAt, style: .relative))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Disconnected").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - D-18 interactive row (05-05) — Open Bolus only

/// The single safe, NON-DOSING `LiveActivityIntent` button this ambient glucose card offers
/// (05-UI-SPEC.md Interaction Contract). `compact` trims to an icon-only glyph for the Dynamic
/// Island's tight `.bottom` region; the Lock Screen banner has room for the full label.
///
/// Phase 09.26 (UAT fix, Defect 7 — owner directive): "Snooze" (`LASnoozeAlertIntent`) and "Refresh"
/// (`LAReconnectIntent`) are REMOVED from this row entirely — an ambient glucose Live Activity has
/// no business surfacing either action, in NEITHER the full-bleed NOR the Classic style. The two
/// intents themselves stay defined in `Shared/LiveActivityIntents.swift` (no other consumers break),
/// and the separate notification-category "Snooze 2h"/"Clear" system
/// (`NotificationCoordinator.swift`) is UNRELATED and untouched — only this row's button set changed.
///
/// Phase 09.26-07 (D-22/de-dup) — `showOpenBolus` (default `true`) gates the "Open Bolus" button.
/// EVERY Classic call site is byte-identical (they never pass this parameter, so it stays `true`);
/// full-bleed no longer calls this view at all — the `LABolusShortcutPill` is its sole control.
private struct LAActionRow: View {
    var compact: Bool = false
    var showOpenBolus: Bool = true

    var body: some View {
        Group {
            if compact {
                buttons.labelStyle(.iconOnly)
            } else {
                buttons.labelStyle(.titleAndIcon)
            }
        }
        .font(compact ? .caption2 : .caption)
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    @ViewBuilder private var buttons: some View {
        if showOpenBolus {
            HStack(spacing: compact ? 14 : 20) {
                Button(intent: LAOpenBolusIntent()) {
                    Label("Open Bolus", systemImage: "arrow.up.forward.app.fill")
                }
            }
        }
    }
}

/// D-22 — the optional nav-only "Bolus" shortcut pill. Reuses the EXISTING `LAOpenBolusIntent`
/// verbatim (open-only, zero `@Parameter`, `openAppWhenRun=true`) — introduces NO new
/// `LiveActivityIntent` conformer. Styled as a DISTINCT tinted/filled action pill (`.borderedProminent`
/// + accent tint) so it reads differently from the passive `PumpChipView` info chips it sits beside.
/// `compact` trims to an icon-only glyph for the Dynamic Island's tighter `.bottom` region — mirrors
/// `LAActionRow`'s own `compact` icon-only/titleAndIcon split.
private struct LABolusShortcutPill: View {
    var compact: Bool = false

    var body: some View {
        Group {
            if compact {
                label.labelStyle(.iconOnly)
            } else {
                label.labelStyle(.titleAndIcon)
            }
        }
        .font(compact ? .caption2 : .caption)
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
        .accessibilityLabel("Bolus")
        .accessibilityHint("Opens the bolus entry screen. No dose is sent from here.")
    }

    private var label: some View {
        Button(intent: LAOpenBolusIntent()) {
            Label("Bolus", systemImage: "syringe")
        }
    }
}

// MARK: - Lock Screen (+ CarPlay fallback surface)

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    /// Phase 09.26-05 (D-06 "Always-on") — drives the flat-scrim swap below; `FullBleedGlucosePlot`
    /// reads this SAME environment key independently for its own fill/chrome flattening.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Phase 09.26-01 tracer (D-11/D-21) — the additive style branch. "classic" (or any
    /// unrecognized/legacy token, decode-defaulted to "fullBleed" upstream but re-checked here
    /// defensively) renders the EXISTING body verbatim, extracted below as `classicBody` so the
    /// diff stays a wrapper, not a rewrite of the Classic layout (09.26-01-PLAN.md verification:
    /// "Classic style renders byte-identically"). Full-bleed only takes over once there is at least
    /// one glucose fact to plot — the no-reading `isMinimalFallback` state stays SHARED and unchanged
    /// between styles (D-11: "no curve is drawn without at least one fact").
    var body: some View {
        if context.state.liveActivityStyle == "fullBleed" && hasGlucoseReading {
            fullBleedBody
        } else {
            classicBody
        }
    }

    private var hasGlucoseReading: Bool {
        let composed = LiveActivityComposer.compose(
            selection: context.state.selectedFields, state: context.state, region: .lockScreen)
        return composed.first?.id == "glucose"
    }

    // MARK: - Full-bleed (D-11/D-16/D-17, Phase 09.26-01 tracer)

    /// Phase 09.26 (UAT fix, Defect 1/3 — the layout-collapse root cause): a Lock Screen Live
    /// Activity is content-height self-sizing. The plot previously had NO explicit height, so the
    /// outer `ZStack` collapsed to the overlay `VStack`'s own natural height, which in turn collapsed
    /// its `Spacer(minLength: 0)` — the "pin the bottom row to the bottom" intent silently failed and
    /// the chips/basal-chip floated mid-widget over the curve. Giving the plot an explicit height and
    /// compositing the overlays onto it via `.overlay(alignment:)` (below) — instead of sharing a
    /// self-sizing `VStack` + `Spacer` with the plot — makes top-left/top-right/bottom independently
    /// anchored regardless of content height. This exact value is a judgment call (09.26-UI-SPEC.md
    /// specifies a fixed height only for the DI's 44pt plot, not the Lock Screen's) — chosen to
    /// comfortably fit the top overlay block + curve + bottom row without overlap; re-verify on-device.
    private static let fullBleedPlotHeight: CGFloat = 190

    /// Z-order back→front (09.26-UI-SPEC.md "Lock Screen Expanded", as amended by the UAT fix above):
    /// a darkening backing (Defect 6), `FullBleedGlucosePlot` filling the sized content area, then the
    /// top-left BG overlay, the top-right selectable slot, and the bottom customizable-fields row —
    /// all independently anchored onto the sized plot. Phase 09.26 (UAT fix, Defect 7 — owner
    /// directive): the always-available action row (Snooze/Refresh) is REMOVED here — the optional
    /// Bolus-shortcut pill (when on) is this card's only interactive control.
    @ViewBuilder private var fullBleedBody: some View {
        ZStack {
            // Defect 6 (UAT fix) — a darkening backing as the BOTTOM-MOST layer so the curve + BG/
            // chip overlays stay legible over ANY Lock Screen wallpaper; `.containerBackground(.fill
            // .tertiary, for: .widget)` below is a translucent system fill that alone let a photo
            // wallpaper bleed through (the "muddy fill" defect).
            Rectangle().fill(Color.black.opacity(0.35))
            FullBleedGlucosePlot(
                points: context.state.recentPoints,
                floorMgdl: context.state.plotFloorMgdl,
                ceilingMgdl: context.state.plotCeilingMgdl,
                currentGlucose: context.state.glucose,
                isStale: context.isStale,
                plotRangeHours: context.state.plotRangeHours,
                showXAxisLine: context.state.showXAxisLine,
                showYAxisLine: context.state.showYAxisLine,
                showXAxisTicks: context.state.showXAxisTicks,
                showYAxisTicks: context.state.showYAxisTicks,
                showRangeLines: context.state.showRangeLines)
        }
        .frame(height: Self.fullBleedPlotHeight)
        .overlay(alignment: .topLeading) { fullBleedTopLeadingOverlay }
        // Top-right overlay (D-05/D-15) — a SEPARATE overlay alignment from the top-left block,
        // since the two are independently sized.
        .overlay(alignment: .topTrailing) { fullBleedTopTrailingOverlay }
        // Bottom row (D-13, 09.26-UI-SPEC.md "Bottom row") — the retained customizable
        // field-selection composer. Phase 09.26-07 (D-22): when the optional Bolus-shortcut pill is
        // on, it takes the LEFTMOST slot of this SAME row and the customizable chips offset (shift
        // right); when off, the chips use the full row exactly as before.
        .overlay(alignment: .bottomLeading) { fullBleedBottomRow }
        .padding(16)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var fullBleedBottomRow: some View {
        if context.state.showBolusShortcut || !fullBleedBottomRowFields.isEmpty {
            HStack(spacing: 8) {
                if context.state.showBolusShortcut {
                    LABolusShortcutPill()
                }
                ForEach(fullBleedBottomRowFields, id: \.id) { f in
                    if let chip = WidgetUI.chip(for: f.id, context.state) {
                        PumpChipView(chip: chip, ageDate: f.id == "iob" && context.state.iobStale ? context.state.iobDate : nil)
                    }
                }
            }
        }
    }

    /// The full-bleed bottom row's composed fields (D-13, 09.26-UI-SPEC.md "Bottom row") — the SAME
    /// `LiveActivityComposer.compose(...)` the Classic style uses, minus the structural "glucose"/
    /// "sparkline" pseudo-ids (BG is top-left, the curve is the background — always shown, not
    /// optional composed fields in full-bleed) and minus whatever id is currently bound to the
    /// top-right slot (dedupe — never show the same fact twice). Empty selection yields an empty
    /// bottom row (NOT the card-wide "minimal" fallback — BG + curve already occupy the card, so
    /// "minimal" is filtered defensively too, though by construction of `hasGlucoseReading` gating
    /// entry into `fullBleedBody` it can't actually appear here alongside other fields).
    private var fullBleedBottomRowFields: [LAField] {
        composeFullBleedBottomRowFields(context: context)
    }

    /// Phase 09.26 (UAT fix, Defect 4): `.thinMaterial` cannot sample/blur the Lock Screen wallpaper
    /// (a Live Activity composites separately from it), so over a photo it degraded to a flat
    /// opaque-ish grey plate — a harsh "grey blob" rather than a subtle scrim. Unify on a flat dark
    /// tint for BOTH states (the always-on branch already used one, at a lower opacity since AOD's
    /// palette is already reduced) rather than reintroducing a second scrim style. Used by BOTH
    /// full-bleed scrims below — never a third scrim style introduced elsewhere.
    private var scrimStyle: AnyShapeStyle {
        AnyShapeStyle(Color.black.opacity(isLuminanceReduced ? 0.15 : 0.25))
    }

    /// Top-left overlay (D-16): the BG numeral + trend arrow, with the time-since-CGM caption
    /// directly below it — `GlucoseNumeralView(role: .display)` already renders exactly this
    /// (angled Unicode arrow + friendly-age caption), reused verbatim rather than re-derived. A flat
    /// dark `scrimStyle` scrim (Defect 4 UAT fix) keeps the block legible over the busy curve.
    private var fullBleedTopLeadingOverlay: some View {
        GlucoseNumeralView(context: context, role: .display)
            .padding(8)
            .background(scrimStyle, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Top-right overlay (D-05/D-15, 09.26-UI-SPEC.md "Top-right overlay") — the user-selectable
    /// slot, default "IOB + trend delta". Renders NOTHING (no scrim either) when
    /// `LAMetrics.topRightText` returns `nil` (`topRightField == "none"`), giving that corner back
    /// to the plain curve. The small `.secondary` "ellipsis" glyph in the scrim's corner is a purely
    /// visual "this is configurable" affordance — NOT a separate tap target (the whole card already
    /// opens the app via `.widgetURL`).
    @ViewBuilder private var fullBleedTopTrailingOverlay: some View {
        if let text = LAMetrics.topRightText(field: context.state.topRightField, state: context.state, now: Date()) {
            Text(text)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(topRightTint(
                    field: context.state.topRightField, state: context.state, isStale: context.isStale))
                .padding(8)
                .padding(.trailing, 6)   // extra room so the corner glyph never overlaps the text
                .background(scrimStyle, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .accessibilityHidden(true)
                }
                // Single combined VoiceOver element (09.26-UI-SPEC.md Accessibility) — the decorative
                // ellipsis glyph above is separately hidden so only the slot's own text is announced.
                .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Classic (D-21, unchanged)

    @ViewBuilder private var classicBody: some View {
        let composed = LiveActivityComposer.compose(
            selection: context.state.selectedFields, state: context.state, region: .lockScreen)
        let hasGlucose = composed.first?.id == "glucose"
        let isMinimalFallback = composed.first?.id == "minimal"
        let chipFields = composed.filter { $0.id != "glucose" && $0.id != "minimal" }

        VStack(alignment: .leading, spacing: 8) {
            if isMinimalFallback {
                MinimalFallbackView(context: context)
            } else {
                if hasGlucose {
                    HStack(spacing: 14) {
                        GlucoseNumeralView(context: context, role: .display)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Sparkline(points: context.state.recentPoints).frame(width: 90, height: 34)
                    }
                }
                if !chipFields.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(chipFields, id: \.id) { f in
                            if let chip = WidgetUI.chip(for: f.id, context.state) {
                                PumpChipView(chip: chip, ageDate: f.id == "iob" && context.state.iobStale ? context.state.iobDate : nil)
                            }
                        }
                    }
                }
                // The dateless pump cluster's shared "Synced N ago" caption — only when at least one
                // dateless (non-"connection") chip is actually showing, so it never appears alongside
                // an explicit "connection" chip that already says the same thing.
                if context.state.pumpLinkStale && chipFields.contains(where: { $0.id != "connection" }) {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                        (Text("Synced ") + Text(context.state.updatedAt, style: .relative))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            // D-18 (05-05) — always available regardless of the field-selection/empty-selection state
            // above. Phase 09.26 (UAT fix, Defect 7): now Open-Bolus only — Snooze/Refresh removed.
            LAActionRow()
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

// MARK: - Dynamic Island compact/minimal (D-17a: adaptive, capacity-1 regions)

private struct CompactLeadingView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        let field = LiveActivityComposer.compose(
            selection: context.state.selectedFields, state: context.state, region: .compactLeading
        ).first ?? LAField(id: "minimal")
        ComposedFieldView(context: context, field: field, role: .heading)
    }
}

/// The second-priority selected field, glyph-only when it's a pump chip (05-UI-SPEC.md: "a single
/// glyph-only pump-status icon... to stay legible" — the compact-trailing slot is too tiny for a
/// value alongside compact-leading's numeral).
///
/// Phase 09.26 (UAT fix, Defect 8): `compactLeading` and `compactTrailing` are BOTH capacity-1
/// regions with no drop-first/offset between them (`LiveActivityComposer.compose`), so both resolve
/// to the SAME top-priority field — "glucose" by default. `compactLeading`'s
/// `GlucoseNumeralView(.heading)` already renders value+arrow inline, so this view's own former
/// `case "glucose": Text(context.arrow)` re-rendered the SAME trend arrow a second time in the same
/// compact pill (visible as a double arrow in the Mac menu-bar LA pill and the iOS Dynamic Island
/// compact pill, both styles). Render nothing for the glucose case instead.
private struct CompactTrailingView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        let field = LiveActivityComposer.compose(
            selection: context.state.selectedFields, state: context.state, region: .compactTrailing
        ).first
        switch field?.id {
        case "glucose", nil, "minimal", "sparkline":
            EmptyView()
        default:
            if let id = field?.id, let chip = WidgetUI.chip(for: id, context.state) {
                Image(systemName: chip.icon).foregroundStyle(chip.tint).font(.system(size: 16, weight: .bold))
            }
        }
    }
}

private struct MinimalRegionView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        let field = LiveActivityComposer.compose(
            selection: context.state.selectedFields, state: context.state, region: .minimal
        ).first ?? LAField(id: "minimal")
        ComposedFieldView(context: context, field: field, role: .heading)
    }
}

// MARK: - CarPlay `.small` (D-10) — adapts Loop's AdaptiveLockScreenView split
//
// 09.26-06 (D-08): `@Environment(\.activityFamily)` is an iOS-18 API, but `faBolusWidgets`' floor is
// unconditionally 18.0 (project.yml), so it — and `CarPlaySmallView` below — need no `@available`
// gate: every build of this extension already meets the requirement. `GlucoseLiveActivity` is now
// this view's ONLY caller (the previous separate `@available(iOS 18.0, *)` CarPlay widget conformer
// was removed as part of the same reconciliation).

/// `GlucoseLiveActivity`'s Lock-Screen closure — reads `@Environment(\.activityFamily)` to branch
/// between the CarPlay `.small` layout and the SAME full Lock Screen content every other family
/// (Lock Screen, Dynamic Island's own presentation) renders.
private struct CarPlayGatedView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    @Environment(\.activityFamily) private var activityFamily
    var body: some View {
        switch activityFamily {
        case .small:
            CarPlaySmallView(context: context)
        default:
            LockScreenLiveActivityView(context: context)
        }
    }
}

/// The CarPlay `.small` glanceable field — a single highest-priority selected field, plain padding
/// (NO `SmartStackMargins`, NO Loop named color assets — 05-UI-SPEC.md Registry Safety caveat).
/// Display-only: no CarPlay entitlement, no CarPlay app (D-10).
private struct CarPlaySmallView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        let field = LiveActivityComposer.compose(
            selection: context.state.selectedFields, state: context.state, region: .carPlaySmall
        ).first ?? LAField(id: "minimal")
        HStack {
            ComposedFieldView(context: context, field: field, role: .heading)
        }
        .padding(8)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
