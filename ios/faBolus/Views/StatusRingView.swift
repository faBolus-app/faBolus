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
    var failover: (name: String, reason: String)? = nil

    // N12 (Dynamic Type): the big glucose number and the ring frame scale with the user's text-size
    // setting (up to the accessibility sizes), instead of a fixed 44 pt / 180 pt that clips or looks
    // tiny for low-vision users. `relativeTo: .largeTitle` ties both to the same scale curve.
    @ScaledMetric(relativeTo: .largeTitle) private var glucoseFontSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 180

    /// Phase 04-01 (D-10): the display-unit funnel this ring's glucose number + caption route
    /// through. mg/dL mode renders byte-identical to before this phase.
    private var unit: GlucoseUnit { AppSettings.shared.glucoseDisplayUnit }
    private var unitLabel: String { unit == .mmol ? "mmol/L" : "mg/dL" }
    /// Owner-requested toggle: gates ONLY the persistent unit CAPTION drawn below the glucose number
    /// (and its no-reading placeholder) — never the VoiceOver `a11yLabel` below, which always speaks
    /// the unit regardless of this flag.
    private var showUnitLabel: Bool { AppSettings.shared.showGlucoseUnitLabels }

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.ringColor(snapshot.connection).opacity(0.25), lineWidth: 10)
            Circle()
                .trim(from: 0, to: snapshot.connection == .disconnected ? 0.05 : 1)
                .stroke(AppTheme.ringColor(snapshot.connection),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: snapshot.connection)

            // Re-evaluate age/staleness on a timer so a fresh reading visibly ages and turns stale
            // even when no new data arrives.
            TimelineView(.periodic(from: .now, by: 20)) { context in
                content(now: context.date)
            }
        }
        .frame(width: ringSize, height: ringSize)
    }

    /// A stale reading is shown but de-emphasized (gray) with its age called out — "old is worse
    /// than nothing", so it's never presented as the current in-range/high/low value.
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
                // No reading, or past the "hide" delay → show no value.
                Text("—").font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                // Owner-requested toggle: with labels hidden, the "no reading yet" placeholder can't
                // fall back to the (now-gated) unit caption — show a neutral em dash instead, never
                // the unit and never a blank string.
                Text(snapshot.glucose == nil ? (showUnitLabel ? unitLabel : "—") : "no recent CGM")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(snapshot.connection.rawValue)
                .font(.caption).foregroundStyle(.secondary)
            // P12 (app-boundary state): when the link is down for a specific reason (Bluetooth off,
            // permission denied, …) say so, instead of a bare "Disconnected". nil on remotes (asSnapshot
            // never sets it), so this line only appears on the phone that owns the pump link.
            if let detail = snapshot.connectionDetail {
                Text(Self.humanized(detail))
                    .font(.caption2).foregroundStyle(AppTheme.low)
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            if let f = failover {
                // Only shown while a failover source is supplying the live value (pump feed stale/
                // missing). Kept to one line and bounded well inside the 180pt ring so no source name
                // overruns; the full reason is on the accessibility hint.
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
        // N12 (VoiceOver): the whole ring reads as ONE element — "Glucose 124 mg/dL, ↑, 2 min ago,
        // Connected" — rather than five separate swipe stops. `.ignore` (not `.combine`) so the label
        // reads a proper sentence with the word "Glucose" up front and the word "stale" injected when
        // the reading is de-emphasized (a signal that is otherwise conveyed only by the grey color).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel(now: now))
        .accessibilityHint(failover?.reason ?? "")
    }

    /// N12: the spoken description of the ring, mirroring what's drawn. Includes "stale" whenever the
    /// reading is de-emphasized so a VoiceOver user gets the same "not current" cue the grey color gives.
    private func a11yLabel(now: Date) -> String {
        let present = GlucoseFreshness.presentation(of: snapshot.glucoseDate, now: now)
        var parts: [String] = []
        if let g = snapshot.glucose, present != .hidden {
            parts.append("Glucose \(unit.format(mgdl: g)) \(unitLabel)")
            parts.append(snapshot.trend)
            // F4 (A5): speak the band word too when it's a live (band-colored) reading — the spoken
            // parallel of the on-screen band label, so the band never depends on color alone.
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

    /// D3-03: `TandemBackend.applyClientError` (byte-guarded — not editable here) has one fallback path
    /// that sets `connectionDetail = "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"` when no more
    /// specific, already-human state string applies. Every OTHER `connectionDetail` assignment in
    /// TandemBackend is already a curated sentence ("Bluetooth is off", "Couldn't reconnect securely.
    /// Tap to retry…", …) and passes through this check byte-identical — only the recognizable bare
    /// "domain#code " token is replaced with one plain fallback sentence.
    private static func humanized(_ detail: String) -> String {
        detail.range(of: #"^\S+#-?\d+\s"#, options: .regularExpression) != nil
            ? "Connection error — try reconnecting"
            : detail
    }
}
