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
// The iOS-18 CarPlay `.small` gating below (`@available(iOS 18.0, *)` branch reading
// `@Environment(\.activityFamily)`) adapts Loop's `GlucoseLiveActivityConfiguration`
// `AdaptiveLockScreenView` availability-branch pattern — content is faBolus-original, not copied,
// and none of Loop's named color assets / `SwiftCharts` are used (05-UI-SPEC.md Registry Safety).

/// The glucose Live Activity + Dynamic Island (D-01). Every region below renders through
/// `LiveActivityComposer.compose(selection:state:region:)` (05-04, D-17a) so the Lock Screen /
/// Dynamic Island / CarPlay layout adapts to ANY 0..N user-selected field subset, with a documented
/// empty-selection fallback — never a fixed field set.
///
/// `Widget.body` has no `@available`-branching result builder (unlike `View`/`WidgetBundle`), so an
/// iOS-18-only `.supplementalActivityFamilies` call cannot live in a conditional branch of ONE
/// widget's `body` — the CarPlay `.small` presentation instead ships as a SEPARATE `Widget` conformer
/// (`GlucoseLiveActivityCarPlay`, `@available(iOS 18.0, *)`), and `FaBolusWidgetBundle` picks exactly
/// one of the two via `if #available` at the BUNDLE level, which `WidgetBundleBuilder` DOES support.
/// Both widgets share the identical Dynamic Island region tree (`glucoseDynamicIslandConfiguration`)
/// so there is no duplicated region logic between the iOS-17 floor and the iOS-18 CarPlay variant.
struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FaBolusGlucoseAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .widgetURL(FaBolusDeepLink.open)
        } dynamicIsland: { context in
            glucoseDynamicIslandConfiguration(context: context)
        }
    }
}

/// CarPlay `.small` presentation (iOS 18+, D-10) — identical Lock Screen + Dynamic Island content to
/// `GlucoseLiveActivity` above, plus `.supplementalActivityFamilies([.small])` so the SAME Activity
/// additionally renders on CarPlay. `.medium` is NOT built (D-10: `.small` ONLY for v1). Display-only
/// — no CarPlay entitlement, no CarPlay app.
@available(iOS 18.0, *)
struct GlucoseLiveActivityCarPlay: Widget {
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

/// The Dynamic Island region tree, factored out so it is written exactly once and shared by both
/// `GlucoseLiveActivity` (iOS 17 floor) and `GlucoseLiveActivityCarPlay` (iOS 18+) — see the type
/// doc comment above for why this can't be a single `if #available` branch inside one widget's body.
@MainActor
private func glucoseDynamicIslandConfiguration(
    context: ActivityViewContext<FaBolusGlucoseAttributes>
) -> DynamicIsland {
    DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
            let composed = LiveActivityComposer.compose(
                selection: context.state.selectedFields, state: context.state, region: .expanded)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(composed.dropFirst().prefix(2)), id: \.id) { field in
                    ComposedFieldView(context: context, field: field, role: .label)
                }
            }
        }
        DynamicIslandExpandedRegion(.trailing) {
            let composed = LiveActivityComposer.compose(
                selection: context.state.selectedFields, state: context.state, region: .expanded)
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(Array(composed.dropFirst(3).prefix(2)), id: \.id) { field in
                    ComposedFieldView(context: context, field: field, role: .label)
                }
            }
        }
        DynamicIslandExpandedRegion(.center) {
            let composed = LiveActivityComposer.compose(
                selection: context.state.selectedFields, state: context.state, region: .expanded)
            if let first = composed.first {
                ComposedFieldView(context: context, field: first, role: .display)
            }
        }
        DynamicIslandExpandedRegion(.bottom) {
            let bottom = LiveActivityComposer.compose(
                selection: context.state.selectedFields, state: context.state, region: .bottom)
            VStack(spacing: 6) {
                if bottom.first?.id == "sparkline" {
                    Sparkline(points: context.state.recentPoints).frame(height: 40)
                }
                LAActionRow(context: context, compact: true)
            }
        }
    } compactLeading: {
        CompactLeadingView(context: context)
    } compactTrailing: {
        CompactTrailingView(context: context)
    } minimal: {
        MinimalRegionView(context: context)
    }
    .widgetURL(FaBolusDeepLink.open)
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
    /// The classified band (Phase 09.1, Task 2) for the redundant icon+word non-color channel — `nil`
    /// when there is no reading to classify (mirrors `glucoseColor`'s grey-on-missing fallback).
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
///
/// Phase 09.1 (D-04) — every presentation this view backs (Lock Screen banner + DI expanded-center
/// at `.display`, DI compact-leading/minimal/CarPlay-small at `.heading`) also carries the
/// `BandIndicator` non-color channel: `.display` (roomy) shows icon+word, `.heading` (space-
/// constrained) shows icon-only (UI-SPEC #3/#4). Only rendered for a fresh reading — the number is
/// already greyed when stale, so there is no band color to duplicate (mirrors `StatusRingView`).
private struct GlucoseNumeralView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var role: ComposedFieldView.FieldRole = .heading

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
            if !context.isStale, let band = context.glucoseBand {
                BandIndicator(band: band, showWord: role == .display)
                    .font(role == .display ? .caption2 : .system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            if role == .display {
                if let d = context.state.glucoseDate {
                    Text(d, style: .relative).font(.caption2)
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

// MARK: - D-18 interactive row (05-05) — Open Bolus / (conditional) Snooze / Refresh

/// The three safe, NON-DOSING `LiveActivityIntent` buttons (05-UI-SPEC.md Interaction Contract).
/// "Snooze" is shown ONLY when `context.state.hasSnoozeEligibleAlert` is true — an app-computed flag
/// (never re-derived here) that is false whenever the only active alert is a non-snoozeable `.alarm`
/// (`PumpAlertKind.isAutoRuleEligible`). `compact` trims to icon-only glyphs for the Dynamic Island's
/// tight `.bottom` region; the Lock Screen banner has room for the full label.
private struct LAActionRow: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var compact: Bool = false

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
        HStack(spacing: compact ? 14 : 20) {
            Button(intent: LAOpenBolusIntent()) {
                Label("Open Bolus", systemImage: "arrow.up.forward.app.fill")
            }
            if context.state.hasSnoozeEligibleAlert {
                Button(intent: LASnoozeAlertIntent()) {
                    Label("Snooze", systemImage: "bell.slash.fill")
                }
            }
            Button(intent: LAReconnectIntent()) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}

// MARK: - Lock Screen (+ CarPlay fallback surface)

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>

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

    /// Z-order back→front (09.26-UI-SPEC.md "Lock Screen Expanded"): system material background,
    /// `FullBleedGlucosePlot` filling the content area, then the top-left BG overlay + the always-
    /// available action row. Chrome (axis lines/ticks/range-lines), the top-right selectable slot,
    /// and the bottom customizable-fields row are later plans — this tracer proves the vertical
    /// slice end-to-end, not the full per-presentation layout.
    @ViewBuilder private var fullBleedBody: some View {
        ZStack(alignment: .topLeading) {
            FullBleedGlucosePlot(
                points: context.state.recentPoints,
                floorMgdl: context.state.plotFloorMgdl,
                ceilingMgdl: context.state.plotCeilingMgdl,
                currentGlucose: context.state.glucose,
                isStale: context.isStale)
            VStack(alignment: .leading, spacing: 0) {
                fullBleedTopLeadingOverlay
                Spacer(minLength: 0)
                // D-18 (05-05) — always available, unchanged from Classic.
                LAActionRow(context: context)
            }
        }
        // Top-right overlay (D-05/D-15) — a SEPARATE overlay alignment from the outer ZStack's
        // `.topLeading`, since the top-left block above and this one are independently sized.
        .overlay(alignment: .topTrailing) { fullBleedTopTrailingOverlay }
        .padding(16)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// Top-left overlay (D-16): the BG numeral + trend arrow, with the time-since-CGM caption
    /// directly below it — `GlucoseNumeralView(role: .display)` already renders exactly this
    /// (angled Unicode arrow + relative-age caption), reused verbatim rather than re-derived. A
    /// `.thinMaterial` scrim keeps the block legible over the busy curve.
    private var fullBleedTopLeadingOverlay: some View {
        GlucoseNumeralView(context: context, role: .display)
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
                .padding(8)
                .padding(.trailing, 6)   // extra room so the corner glyph never overlaps the text
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
            // above (05-UI-SPEC.md Interaction Contract: Open Bolus/Refresh "Always available").
            LAActionRow(context: context)
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
/// value alongside compact-leading's numeral). Renders the arrow specifically when the composed
/// field IS glucose (mirrors the tracer's original compactLeading=value/compactTrailing=arrow pair).
private struct CompactTrailingView: View {
    let context: ActivityViewContext<FaBolusGlucoseAttributes>
    var body: some View {
        let field = LiveActivityComposer.compose(
            selection: context.state.selectedFields, state: context.state, region: .compactTrailing
        ).first
        switch field?.id {
        case "glucose":
            if !context.arrow.isEmpty {
                Text(context.arrow)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(context.glucoseColor)
            }
        case nil, "minimal", "sparkline":
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

// MARK: - CarPlay `.small` (iOS 18+, D-10) — adapts Loop's AdaptiveLockScreenView split

/// The `GlucoseLiveActivityCarPlay` widget's Lock-Screen closure — reads `@Environment
/// (\.activityFamily)` (iOS-18-only) to branch between the CarPlay `.small` layout and the SAME
/// full Lock Screen content `GlucoseLiveActivity` (the iOS-17-floor widget) renders. `GlucoseLiveActivity`
/// itself never sees this type — only the `@available(iOS 18.0, *)`-gated CarPlay widget does, so the
/// iOS-17-only build path never references the iOS-18-only `activityFamily` environment key.
@available(iOS 18.0, *)
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
@available(iOS 18.0, *)
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
