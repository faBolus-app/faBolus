import SwiftUI
import faBolusCore
import faBolusDesign

/// modern status ring around the current glucose reading + trend. The ring color reflects
/// connection/activity state (NOT closed-loop status — FaBolus doesn't automate).
struct StatusRingView: View {
    let snapshot: PumpSnapshot
    /// Set only when the live glucose is coming from a failover source (not the pump) — shows a
    /// small "via <source>" badge so the user knows where the number is from and why. `nil` = pump
    /// feed is live, so nothing extra is drawn (keeps the ring clean in the common case).
    var failover: (name: String, reason: String)?

    // Dynamic Type: the big glucose number and the ring frame scale with the user's text-size
    // setting (up to the accessibility sizes), instead of a fixed 44 pt / 180 pt that clips or looks
    // tiny for low-vision users. `relativeTo: .largeTitle` ties both to the same scale curve.
    @ScaledMetric(relativeTo: .largeTitle) private var glucoseFontSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 180

    /// The display-unit funnel this ring's glucose number + caption route through.
    private var unit: GlucoseUnit { AppSettings.shared.glucoseDisplayUnit }
    private var unitLabel: String { "mg/dL" }
    /// Gates the on-screen unit caption only — VoiceOver always speaks the unit.
    private var showUnitLabel: Bool { AppSettings.shared.showGlucoseUnitLabels }

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.ringColor(snapshot.connection).opacity(0.25), lineWidth: 10)
            Circle()
                .trim(from: 0, to: snapshot.connection == .disconnected ? 0.05 : 1)
                .stroke(
                    AppTheme.ringColor(snapshot.connection),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: snapshot.connection)

            // Re-evaluate age so a reading can turn stale even if no new sample arrives.
            TimelineView(.periodic(from: .now, by: 20)) { context in
                content(now: context.date)
            }
        }
        .frame(width: ringSize, height: ringSize)
    }

    /// Stale is shown greyed with age — never as the current in-range/high/low value.
    @ViewBuilder private func content(now: Date) -> some View {
        let present = GlucoseFreshness.presentation(of: snapshot.glucoseDate, now: now)
        let stale = present == .stale
        VStack(spacing: 2) {
            if let g = snapshot.glucose, present != .hidden {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(unit.format(mgdl: g))
                        .font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .foregroundStyle(AppTheme.glucoseColor(g, stale: stale))
                    Text(snapshot.trend).font(.title2)
                        .foregroundStyle(stale ? AppTheme.stale : .primary)
                }
                if showUnitLabel {
                    Text(unitLabel).font(.caption2).foregroundStyle(.secondary)
                }
                if let d = snapshot.glucoseDate {
                    Text(GlucoseFreshness.ageLabel(for: d, now: now))
                        .font(.caption2)
                        .fontWeight(stale ? .semibold : .regular)
                        .foregroundStyle(stale ? AppTheme.low : .secondary)
                }
            } else {
                // No reading, or past the hide delay → no value.
                Text("—").font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                // Labels off: placeholder is "—", never the unit and never blank.
                Text(snapshot.glucose == nil ? (showUnitLabel ? unitLabel : "—") : "no recent CGM")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(snapshot.connection.rawValue)
                .font(.caption).foregroundStyle(.secondary)
            // Named disconnect reason (Bluetooth off, …) instead of a bare "Disconnected".
            // Remotes never set this; only the phone that owns the pump link.
            if let detail = snapshot.connectionDetail {
                Text(Self.humanized(detail))
                    .font(.caption2).foregroundStyle(AppTheme.low)
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            if let f = failover {
                // Failover source only (pump feed stale/missing). One line; full reason is the hint.
                Label("via \(f.name)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2).foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: 140)
                    .help(f.reason)
                    .accessibilityHint(f.reason)
            }
        }
        // One VoiceOver element. `.ignore` (not `.combine`) so the spoken sentence can inject
        // "stale" — otherwise that cue is only the grey color.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel(now: now))
        .accessibilityHint(failover?.reason ?? "")
    }

    /// The spoken description of the ring, mirroring what's drawn. Includes "stale" whenever the
    /// reading is de-emphasized so a VoiceOver user gets the same "not current" cue the grey color gives.
    private func a11yLabel(now: Date) -> String {
        let present = GlucoseFreshness.presentation(of: snapshot.glucoseDate, now: now)
        var parts: [String] = []
        if let g = snapshot.glucose, present != .hidden {
            parts.append("Glucose \(unit.format(mgdl: g)) \(unitLabel)")
            parts.append(snapshot.trend)
            // Speak the band word on a live reading so the band isn't color-only.
            if present == .fresh { parts.append(GlucoseRange.classify(g).shortLabel) }
            if present == .stale { parts.append("stale") }
            if let d = snapshot.glucoseDate { parts.append(GlucoseFreshness.ageLabel(for: d, now: now)) }
        } else {
            parts.append(snapshot.glucose == nil ? "Glucose unavailable" : "No recent CGM")
        }
        parts.append(snapshot.connection.rawValue)
        if let detail = snapshot.connectionDetail { parts.append(Self.humanized(detail)) }
        if let f = failover { parts.append("via \(f.name)") }
        return parts.joined(separator: ", ")
    }

    /// Maps the one raw `domain#code` fallback from `applyClientError`. Curated sentences
    /// ("Bluetooth is off", …) pass through unchanged.
    /// Not `private`: the drift guard pins this exact production mapping instead of a hand-kept copy.
    static func humanized(_ detail: String) -> String {
        detail.range(of: #"^\S+#-?\d+\s"#, options: .regularExpression) != nil
            ? "Connection error — try reconnecting"
            : detail
    }
}
