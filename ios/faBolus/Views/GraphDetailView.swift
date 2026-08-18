import SwiftUI
import faBolusCore
import faBolusDesign

/// Phase 09.18b (D-05/D-06) — the scrubbable-readout ViewModel + card that `GlucoseChartView`'s
/// `.chartOverlay` scrubber drives. This is the phase TRACER's iOS end: a compact card showing the
/// values at a scrubbed timestamp, fed by a ViewModel REWRITTEN over faBolus's OWN in-memory feed
/// (never Loop's closed-loop stores, D-05).
///
/// This plan (09.18b-01) renders the GLUCOSE row only; 09.18b-01 Task 2 expands the readout to
/// IOB / bolus / basal, and 09.18b-02 slots in an HR row — the model + card are shaped so those rows
/// drop in without a redesign.

// MARK: - Resolved readout snapshot

/// The values resolved at one scrubbed instant. Each optional is `nil` when no sample is within
/// tolerance of the scrub point → that row renders an em dash (never a fabricated number). COB /
/// override / AutoPreset are DROPPED entirely (no faBolus data source, D-06). HR is deliberately absent
/// this plan.
struct GraphDetailReadoutModel: Equatable {
    let date: Date
    let glucoseMgdl: Int?
    let iob: Double?
    let bolusUnits: Double?
    /// The current KNOWN basal rate (a single scalar from the pump snapshot) — faBolus has no
    /// per-timestamp basal history, so this is not resolved against the scrub `Date`; it is the same
    /// current rate at every scrub point. `nil` when the snapshot has none (→ "—"); never a fabricated
    /// schedule. 09.18b-02 adds: heartRate.
    let basalUnitsPerHour: Double?

    private static let a11yTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// The single VoiceOver announcement string for the card (UI-SPEC §1 accessibility backstop): "At
    /// {time}: glucose {v}, IOB {v}, bolus {v}, basal {v}", with a missing value spoken as "no reading"
    /// rather than the visual em dash (which VoiceOver would read as a bare "dash"). Reused verbatim by
    /// the chart's `.accessibilityAdjustableAction` value so a sighted read and a VoiceOver read never
    /// drift. HR is appended here by 09.18b-02.
    func accessibilityDescription(unit: GlucoseUnit) -> String {
        let unitWord = unit == .mmol ? "mmol/L" : "mg/dL"
        let glucose = glucoseMgdl.map { "\(unit.format(mgdl: $0)) \(unitWord)" } ?? "no reading"
        let iobText = iob.map { formatUnits($0) } ?? "no value"
        let bolusText = bolusUnits.map { formatUnits($0) } ?? "no value"
        let basalText = basalUnitsPerHour.map { "\(formatUnits($0)) per hour" } ?? "no value"
        return "At \(Self.a11yTimeFormatter.string(from: date)): glucose \(glucose), "
            + "IOB \(iobText), bolus \(bolusText), basal \(basalText)"
    }
}

// MARK: - ViewModel (rewritten over the faBolus feed, D-05)

/// Rewritten over faBolus's OWN glucose/IOB/bolus feed — the SAME arrays `GlucoseChartView` already
/// renders (`model.glucoseHistory` / `iobHistory` / `bolusMarkers`). It NEVER references Loop's
/// `deviceManager.glucoseStore` / `doseStore` / `loopManager` (D-05). A pure value type: resolving a
/// readout at a scrubbed `Date` is display-only math delegated to `GraphDetailReadout` (faBolusCore).
struct GraphDetailViewModel: Equatable {
    var glucose: [GlucoseReading]
    var iob: [IOBSample] = []
    var boluses: [BolusMarker] = []
    /// The pump snapshot's CURRENT basal rate (units/hr), or `nil` when unknown. faBolus has no
    /// per-timestamp basal history, so this scalar is surfaced as-is at every scrub point (never a
    /// synthesized schedule, D-06).
    var currentBasalUnitsPerHour: Double? = nil

    /// "A sample counts as at this timestamp" window. Mirrors the app's `GlucoseFreshness` ~6-min
    /// staleness window so a scrub landing between CGM readings (~5-min cadence) still resolves the
    /// adjacent one, while a scrub over a genuine gap renders "—" rather than a far-away number.
    static let tolerance: TimeInterval = 6 * 60
    /// Boluses are sparse events, so a wider window than the glucose cadence is honest here — a bolus
    /// up to 10 min from the scrub point is still "the bolus around this time"; beyond that → "—".
    static let bolusTolerance: TimeInterval = 10 * 60

    func readout(at date: Date) -> GraphDetailReadoutModel {
        GraphDetailReadoutModel(
            date: date,
            glucoseMgdl: GraphDetailReadout.glucoseMgdl(at: date, in: glucose, within: Self.tolerance),
            iob: GraphDetailReadout.iob(at: date, in: iob, within: Self.tolerance),
            bolusUnits: GraphDetailReadout.bolusUnits(at: date, in: boluses, within: Self.bolusTolerance),
            basalUnitsPerHour: currentBasalUnitsPerHour)
    }
}

// MARK: - Readout card

/// The compact card the scrubber floats near the top of the 160px chart frame. Re-skinned from the
/// LoopPowerPack GraphDetailView layout onto faBolus tokens (`AppTheme`, system-grouped surfaces,
/// `.monospacedDigit()`), NOT a port of Loop's store-coupled view.
struct GraphDetailCard: View {
    let readout: GraphDetailReadoutModel
    /// The user's display-unit funnel (D-10) — the glucose value routes through the SAME
    /// `GlucoseUnit.format` every other glucose display uses, never a second conversion.
    var unit: GlucoseUnit = AppSettings.shared.glucoseDisplayUnit

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// The em dash a missing value renders — a shown row is never blank and never a fabricated number.
    private static let emDash = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.timeFormatter.string(from: readout.date))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Rows shown: glucose / IOB / bolus / basal (D-06). COB / override / AutoPreset are DROPPED
            // (no faBolus data source). HR is added in 09.18b-02 — this row list is left open for it.
            row(icon: "drop.fill",
                label: "Glucose",
                value: readout.glucoseMgdl.map { unit.format(mgdl: $0) } ?? Self.emDash,
                tint: readout.glucoseMgdl.map { AppTheme.glucoseColor($0) } ?? .secondary)
            row(icon: "syringe",
                label: "IOB",
                value: readout.iob.map { formatUnits($0) } ?? Self.emDash,
                tint: readout.iob != nil ? AppTheme.insulin : .secondary)
            row(icon: "chart.bar.fill",
                label: "Bolus",
                value: readout.bolusUnits.map { formatUnits($0) } ?? Self.emDash,
                tint: readout.bolusUnits != nil ? AppTheme.insulin : .secondary)
            row(icon: "waveform.path",
                label: "Basal",
                value: readout.basalUnitsPerHour.map { "\(formatUnits($0))/hr" } ?? Self.emDash,
                tint: .secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator).opacity(0.3), lineWidth: 0.5))
        // Dynamic Type: cap the readable width and let rows WRAP/grow vertically rather than clip
        // horizontally at XXL (UI-SPEC §1 — "rows stack, never clips"). No horizontal fixedSize.
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // VoiceOver: the whole card is one element announcing the scrubbed time + every shown value.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(readout.accessibilityDescription(unit: unit))
    }

    /// One readout row: leading SF Symbol + `.caption` `.secondary` label, trailing `.body`
    /// `.monospacedDigit()` value tinted per its semantic token.
    private func row(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }
}
