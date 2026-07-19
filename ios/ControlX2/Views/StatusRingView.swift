import SwiftUI

/// Loop-style status ring around the current glucose reading + trend. The ring color reflects
/// connection/activity state (NOT closed-loop status — ControlX2 doesn't automate).
struct StatusRingView: View {
    let snapshot: PumpSnapshot

    var body: some View {
        ZStack {
            Circle()
                .stroke(LoopTheme.ringColor(snapshot.connection).opacity(0.25), lineWidth: 10)
            Circle()
                .trim(from: 0, to: snapshot.connection == .disconnected ? 0.05 : 1)
                .stroke(LoopTheme.ringColor(snapshot.connection),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: snapshot.connection)

            VStack(spacing: 2) {
                if let g = snapshot.glucose {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(g)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(LoopTheme.glucoseColor(g))
                        Text(snapshot.trend).font(.title2)
                    }
                    Text("mg/dL").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("—").font(.system(size: 44, weight: .bold, design: .rounded))
                }
                Text(snapshot.connection.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 180, height: 180)
    }
}
