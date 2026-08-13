import WidgetKit
import SwiftUI

// FaBolus widgets: Lock Screen (accessory) + Home Screen views of pump state read from the
// App Group, plus a tap-to-bolus shortcut that deep-links into the app's confirm flow. Widgets
// can't drive Bluetooth, so they show the last value the app published, with an age.
@main
struct FaBolusWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseWidget()   // BG + trend (Lock Screen + Home Screen small)
        StatusWidget()    // Overview (Home Screen medium)
        BolusWidget()     // Tap-to-bolus shortcut (deep-links into the app)
        QuickBolusWidget() // Preset bolus with a 1-2-3 confirm (delivers via the app)
        // Phase 5 (D-01) — Lock Screen + Dynamic Island glucose Live Activity. Registered
        // UNCONDITIONALLY: this is the iOS-17-floor widget (D-11) and every SDK version this app
        // supports has it.
        GlucoseLiveActivity()
        // Phase 5 (D-10, 05-04) — the CarPlay `.small` supplemental presentation, additively
        // registered when the SDK/OS supports it. `WidgetBundleBuilder` only provides `buildOptional`
        // (a single-branch `if #available(...)` check via `buildLimitedAvailability`) — there is NO
        // `buildEither`, so `if #available {} else {}` does not compile (confirmed: "closure
        // containing control flow statement cannot be used with result builder 'WidgetBundleBuilder'"),
        // and `if #unavailable(...)` used as the sole/negating branch triggers an internal compiler
        // crash in this toolchain ("failed to produce diagnostic for expression") rather than a clean
        // rejection — reported upstream is out of scope here; the additive single-branch form below is
        // the only shape that compiles. `GlucoseLiveActivityCarPlay` shares the IDENTICAL Dynamic
        // Island region tree and its Lock-Screen closure falls back to the SAME
        // `LockScreenLiveActivityView` off-CarPlay, so registering both configurations for
        // `FaBolusGlucoseAttributes` on iOS 18+ renders identically everywhere except the
        // CarPlay-only `.small` presentation this one adds — see the Task-4 checkpoint for on-device
        // confirmation that iOS resolves the dual registration as expected (05-RESEARCH.md §
        // Environment Availability: CarPlay/dual-config behavior can't be verified off-device).
        if #available(iOS 18.0, *) {
            GlucoseLiveActivityCarPlay()
        }
    }
}

// MARK: - Timeline

struct FaBolusEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

/// Reads the latest published snapshot from the App Group. WidgetKit reloads when the app calls
/// `reloadAllTimelines()`; the `.after` policy is a fallback so a stale widget still ages out.
struct FaBolusProvider: TimelineProvider {
    func placeholder(in context: Context) -> FaBolusEntry {
        FaBolusEntry(date: Date(), snap: .placeholder)
    }
    func getSnapshot(in context: Context, completion: @escaping (FaBolusEntry) -> Void) {
        completion(current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FaBolusEntry>) -> Void) {
        let snap = WidgetStore.load() ?? .placeholder
        let now = Date()
        // P10 (group A) — extra entries at the stale/hide crossings so the widgets grey/hide at the
        // right moment. A widget renders ahead of time, so each view keys off its ENTRY's date (not
        // wall-clock); without crossing entries a fresh entry never re-rendered into its stale/hidden
        // state until the next app reload. Mirrors the Mac provider.
        var dates: [Date] = [now]
        if let d = snap.glucoseDate {
            let stale = d.addingTimeInterval(snap.staleAfterSec ?? 6 * 60)
            if stale > now { dates.append(stale) }
            if let hide = snap.hideAfterSec {
                let hideAt = d.addingTimeInterval(max(hide, snap.staleAfterSec ?? 6 * 60))
                if hideAt > now { dates.append(hideAt) }
            }
        }
        let fallback = now.addingTimeInterval(15 * 60)
        dates.append(fallback)
        let entries = Set(dates).sorted().map { FaBolusEntry(date: $0, snap: snap) }
        completion(Timeline(entries: entries, policy: .after(fallback)))
    }
    private func current() -> FaBolusEntry {
        FaBolusEntry(date: Date(), snap: WidgetStore.load() ?? .placeholder)
    }
}

// MARK: - Shared UI helpers

enum WidgetUI {
    static func glucoseColor(_ category: Int) -> Color {
        switch category {
        case 0: return .red        // low
        case 1: return .green      // in range
        case 2: return .yellow     // high
        case 3: return .orange     // urgent high
        default: return .gray      // unknown
        }
    }
    static func glucoseText(_ snap: WidgetSnapshot) -> String { snap.displayGlucose }
    /// True when the reading is older than 6 minutes (hide the number).
    static func isStale(_ snap: WidgetSnapshot) -> Bool { snap.isGlucoseStale }

    // P10 (group A) — `now`-parameterized variants honoring the phone's PUBLISHED freshness policy,
    // evaluated at the widget entry's date (a widget renders ahead of time, so wall-clock `Date()` is
    // prep time, not display time). These mirror the Mac widget's helpers.
    /// Color at `now`: greyed once stale, else by glucose range.
    static func glucoseColor(_ snap: WidgetSnapshot, now: Date) -> Color {
        snap.isStale(asOf: now) ? .gray : glucoseColor(snap.rangeCategory)
    }
    /// Glucose number at `now`: the value while fresh/stale, "--" once hidden past the policy.
    static func glucoseText(_ snap: WidgetSnapshot, now: Date) -> String {
        if snap.isHidden(asOf: now) { return "--" }
        guard let g = snap.glucose, g > 0 else { return "--" }
        return "\(g)"
    }
    /// Stale at `now` (de-emphasize + drop the trend arrow), per the published policy.
    static func isStale(_ snap: WidgetSnapshot, now: Date) -> Bool { snap.isStale(asOf: now) }

    // MARK: - Phase 5 pump-chip vocabulary (D-17/D-17a, 05-02)
    //
    // The extension links neither the app target nor faBolusCore, so it can't import `AppTheme`
    // (`ios/faBolus/Design/AppTheme.swift`) — these are literal RGB MIRRORS of the same tokens
    // (`insulin`/`low`/`inRange`), not a re-import, per 05-UI-SPEC.md's "Pump-field chip tint
    // vocabulary" and the plan's own instruction to use plain SwiftUI colors here (NOT app-side
    // `AppTheme`). `FaBolusWidgetBundle.swift` compiles ONLY into the `faBolusWidgets` extension
    // target (unlike `WidgetShared.swift`, which is shared with the app), so a cross-target
    // drift-guard test isn't reachable from the app test target the way `WidgetGlucoseThresholds`
    // is pinned — keep these in sync with `AppTheme` by inspection if that palette ever changes.
    static let insulinTint = Color(red: 0.36, green: 0.42, blue: 0.90)   // == AppTheme.insulin
    static let lowTint = Color(red: 0.90, green: 0.25, blue: 0.22)       // == AppTheme.low
    static let inRangeTint = Color(red: 0.30, green: 0.78, blue: 0.36)   // == AppTheme.inRange

    /// A single pump-field chip: SF Symbol + tint + formatted value, MIRRORING
    /// `StatusPillsView.pillFor`'s iconography/formatting verbatim so the ambient surface and the
    /// phone HUD agree on what each glyph/color means.
    struct PumpChip {
        let icon: String
        let tint: Color
        let value: String
    }

    /// IOB chip — `drop.fill`, greys to `lowTint` when `iobStale` (mirrors
    /// `StatusPillsView.pillFor("iob")`'s `CalcInputFreshness`-driven grey exactly, via the
    /// APP-COMPUTED flag carried on `ContentState` — no local freshness re-derivation).
    static func iobChip(_ state: FaBolusGlucoseAttributes.ContentState) -> PumpChip {
        PumpChip(icon: "drop.fill", tint: state.iobStale ? lowTint : insulinTint,
                 value: String(format: "%.2f U", state.iobUnits))
    }

    /// Reservoir chip — `cross.vial.fill`, dateless: greys off the `pumpLinkStale` cluster flag.
    static func reservoirChip(_ state: FaBolusGlucoseAttributes.ContentState) -> PumpChip {
        PumpChip(icon: "cross.vial.fill", tint: state.pumpLinkStale ? .gray : .teal,
                 value: String(format: "%.0f U", state.reservoirUnits))
    }

    /// Battery chip — level-matched `battery.*` glyph, dateless: greys off `pumpLinkStale`.
    static func batteryChip(_ state: FaBolusGlucoseAttributes.ContentState) -> PumpChip {
        let icon: String
        switch state.batteryPercent {
        case ...5: icon = "battery.0"
        case ...37: icon = "battery.25"
        case ...62: icon = "battery.50"
        case ...87: icon = "battery.75"
        default: icon = "battery.100"
        }
        let tint = state.pumpLinkStale ? Color.gray : (state.batteryPercent <= 20 ? lowTint : .green)
        return PumpChip(icon: icon, tint: tint, value: "\(state.batteryPercent)%")
    }

    /// Basal/suspended chip — `waveform.path.ecg` (running) or `pause.circle.fill` (suspended),
    /// dateless: greys off `pumpLinkStale`. Suspension itself is ALWAYS shown as the salient
    /// `lowTint`, never greyed further (mirrors `StatusPillsView.pillFor("basal")`). Value is the
    /// EFFECTIVE U/hr, never an invented temp-rate percent.
    static func basalChip(_ state: FaBolusGlucoseAttributes.ContentState) -> PumpChip {
        if state.deliverySuspended {
            return PumpChip(icon: "pause.circle.fill", tint: lowTint, value: "Suspended")
        }
        return PumpChip(icon: "waveform.path.ecg", tint: state.pumpLinkStale ? .gray : insulinTint,
                        value: String(format: "%.2f U/hr", state.basalRateUnitsPerHour))
    }

    /// Control-IQ chip — mode-matched glyph (`moon.zzz.fill` sleep / `figure.run` exercise /
    /// `checkmark.circle.fill` on), dateless: greys off `pumpLinkStale`. Mirrors
    /// `StatusPillsView.controlIQIcon`/`controlIQValue` exactly.
    static func controlIQChip(_ state: FaBolusGlucoseAttributes.ContentState) -> PumpChip {
        let icon: String
        switch state.controlIQMode {
        case 1: icon = "moon.zzz.fill"
        case 2: icon = "figure.run"
        default: icon = "checkmark.circle.fill"
        }
        let value: String
        if !state.controlIQEnabled {
            value = "Off"
        } else {
            switch state.controlIQMode {
            case 1: value = "Sleep"
            case 2: value = "Exercise"
            default: value = "On"
            }
        }
        let tint = state.pumpLinkStale ? Color.gray : (state.controlIQEnabled ? inRangeTint : .gray)
        return PumpChip(icon: icon, tint: tint, value: value)
    }

    /// Connection chip — `antenna.radiowaves.left.and.right` (up) / `wifi.slash` (down), 05-UI-SPEC.md
    /// Color table. Selected explicitly via the "connection" field id; `LiveActivityComposer.compose`
    /// only ever surfaces it when the pump link is down or stale (05-04, D-17a), so by construction
    /// this never renders while claiming "all fine".
    static func connectionChip(_ state: FaBolusGlucoseAttributes.ContentState) -> PumpChip {
        if !state.connected {
            return PumpChip(icon: "wifi.slash", tint: lowTint, value: "Disconnected")
        }
        return PumpChip(icon: "antenna.radiowaves.left.and.right", tint: .gray, value: "Synced")
    }

    /// Resolves a `LAField.id` (05-04, D-17a) to its chip, or `nil` for the special "glucose"/
    /// "sparkline"/"minimal" pseudo-ids, which the view renders through their own dedicated views.
    static func chip(for id: String, _ state: FaBolusGlucoseAttributes.ContentState) -> PumpChip? {
        switch id {
        case "iob": return iobChip(state)
        case "reservoir": return reservoirChip(state)
        case "battery": return batteryChip(state)
        case "basal": return basalChip(state)
        case "controlIQ": return controlIQChip(state)
        case "connection": return connectionChip(state)
        default: return nil
        }
    }
}
