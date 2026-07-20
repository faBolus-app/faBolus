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

            VStack(spacing: 2) {
                // Hide a reading older than 6 minutes so a stale value is never shown as current.
                if let g = snapshot.glucose, !snapshot.isGlucoseStale {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(g)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.glucoseColor(g))
                        Text(snapshot.trend).font(.title2)
                    }
                    Text("mg/dL").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("—").font(.system(size: 44, weight: .bold, design: .rounded))
                    Text(snapshot.glucose == nil ? "mg/dL" : "no recent CGM")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(snapshot.connection.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 180, height: 180)
    }
}
