import SwiftUI
import faBolusCore

/// modern status ring around the current glucose reading + trend. The ring color reflects
/// connection/activity state (NOT closed-loop status — FaBolus doesn't automate).
struct StatusRingView: View {
    let snapshot: PumpSnapshot
    /// Set only when the live glucose is coming from a failover source (not the pump) — shows a
    /// small "via <source>" badge so the user knows where the number is from and why. `nil` = pump
    /// feed is live, so nothing extra is drawn (keeps the ring clean in the common case).
    var failover: (name: String, reason: String)? = nil

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
        .frame(width: 180, height: 180)
    }

    /// A stale reading is shown but de-emphasized (gray) with its age called out — "old is worse
    /// than nothing", so it's never presented as the current in-range/high/low value.
    @ViewBuilder private func content(now: Date) -> some View {
        let present = GlucoseFreshness.presentation(of: snapshot.glucoseDate, now: now)
        let stale = present == .stale
        VStack(spacing: 2) {
            if let g = snapshot.glucose, present != .hidden {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(g)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.glucoseColor(g, stale: stale))
                    Text(snapshot.trend).font(.title2)
                        .foregroundStyle(stale ? AppTheme.stale : .primary)
                }
                Text("mg/dL").font(.caption2).foregroundStyle(.secondary)
                if let d = snapshot.glucoseDate {
                    Text(GlucoseFreshness.ageLabel(for: d, now: now))
                        .font(.caption2)
                        .fontWeight(stale ? .semibold : .regular)
                        .foregroundStyle(stale ? AppTheme.low : .secondary)
                }
            } else {
                // No reading, or past the "hide" delay → show no value.
                Text("—").font(.system(size: 44, weight: .bold, design: .rounded))
                Text(snapshot.glucose == nil ? "mg/dL" : "no recent CGM")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(snapshot.connection.rawValue)
                .font(.caption).foregroundStyle(.secondary)
            if let f = failover {
                // Only shown while a failover source is supplying the live value (pump feed stale/
                // missing). Tap for the reason; nothing is drawn when the pump feed is live.
                Label("via \(f.name)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2).foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .help(f.reason)
                    .accessibilityHint(f.reason)
            }
        }
    }
}
