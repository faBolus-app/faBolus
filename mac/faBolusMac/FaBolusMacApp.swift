import SwiftUI
import faBolusCore

@main
struct FaBolusMacApp: App {
    @State private var model = MacRemoteModel()

    var body: some Scene {
        // Main window: full dashboard (status + bolus + alerts).
        Window("faBolus", id: "main") {
            MacDashboardView(model: model)
                .frame(minWidth: 360, minHeight: 440)
        }
        .windowResizability(.contentSize)

        // Menu-bar item: current glucose in the bar; click for status + quick bolus.
        MenuBarExtra {
            MenuBarContentView(model: model)
                .frame(width: 300)
        } label: {
            Text(model.reachable ? "\(model.displayGlucose) \(model.trend)" : "—")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar popover: glucose, pills, quick bolus, alerts, and a link to the full window.
struct MenuBarContentView: View {
    var model: MacRemoteModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            MacStatusView(model: model)
            MacStatusPills(model: model)
            Divider()
            MacBolusEntryView(model: model)
            MacAlertsView(model: model)
            Divider()
            HStack {
                Button("Refresh") { model.requestStatus() }
                Spacer()
                Button("Open faBolus") { openWindow(id: "main") }
            }
            .font(.callout)
        }
        .padding(14)
    }
}

/// The full window: the same building blocks, laid out with more room.
struct MacDashboardView: View {
    var model: MacRemoteModel

    var body: some View {
        VStack(spacing: 18) {
            MacStatusView(model: model)
            MacStatusPills(model: model)
            Divider()
            MacBolusEntryView(model: model)
            MacAlertsView(model: model)
            Spacer()
            Button("Refresh status") { model.requestStatus() }
                .buttonStyle(.bordered)
        }
        .padding(20)
    }
}
