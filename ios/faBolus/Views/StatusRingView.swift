import SwiftUI
import faBolusCore

/// modern status ring around the current glucose reading + trend. The ring color reflects
/// connection/activity state (NOT closed-loop status — FaBolus doesn't automate).
struct StatusRingView: View {
    let snapshot: PumpSnapshot

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
        let stale = GlucoseFreshness.isStale(snapshot.glucoseDate, now: now)
        VStack(spacing: 2) {
            if let g = snapshot.glucose {
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
                Text("—").font(.system(size: 44, weight: .bold, design: .rounded))
                Text("mg/dL").font(.caption2).foregroundStyle(.secondary)
            }
            Text(snapshot.connection.rawValue)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
