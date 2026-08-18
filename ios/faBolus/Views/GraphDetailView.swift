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
    // 09.18b-01 Task 2 adds: iob, bolusUnits, basalUnitsPerHour. 09.18b-02 adds: heartRate.
}

// MARK: - ViewModel (rewritten over the faBolus feed, D-05)

/// Rewritten over faBolus's OWN glucose/IOB/bolus feed — the SAME arrays `GlucoseChartView` already
/// renders (`model.glucoseHistory` / `iobHistory` / `bolusMarkers`). It NEVER references Loop's
/// `deviceManager.glucoseStore` / `doseStore` / `loopManager` (D-05). A pure value type: resolving a
/// readout at a scrubbed `Date` is display-only math delegated to `GraphDetailReadout` (faBolusCore).
struct GraphDetailViewModel: Equatable {
    var glucose: [GlucoseReading]
    // 09.18b-01 Task 2 adds: iob, boluses, currentBasalUnitsPerHour.

    /// "A sample counts as at this timestamp" window. Mirrors the app's `GlucoseFreshness` ~6-min
    /// staleness window so a scrub landing between CGM readings (~5-min cadence) still resolves the
    /// adjacent one, while a scrub over a genuine gap renders "—" rather than a far-away number.
    static let tolerance: TimeInterval = 6 * 60

    func readout(at date: Date) -> GraphDetailReadoutModel {
        let g = GraphDetailReadout.nearest(to: date, in: glucose, key: \.date, within: Self.tolerance)
        return GraphDetailReadoutModel(date: date, glucoseMgdl: g?.mgdl)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.timeFormatter.string(from: readout.date))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            row(icon: "drop.fill",
                label: "Glucose",
                value: readout.glucoseMgdl.map { unit.format(mgdl: $0) } ?? "—",
                tint: readout.glucoseMgdl.map { AppTheme.glucoseColor($0) } ?? .secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator).opacity(0.3), lineWidth: 0.5))
        .fixedSize(horizontal: true, vertical: true)
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
