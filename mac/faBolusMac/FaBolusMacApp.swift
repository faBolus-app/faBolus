import SwiftUI
import AppKit
import faBolusCore

/// Menu-bar-only remote (no Dock icon / no main window — see `LSUIElement` in project.yml). Shows
/// the current glucose in the menu bar; clicking opens a popover with status, quick bolus, alerts,
/// and (behind the gear) the iPhone pairing screen.
@main
struct FaBolusMacApp: App {
    @State private var model = MacRemoteModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
                .frame(width: 300)
        } label: {
            Text(model.reachable ? "\(model.displayGlucose) \(model.trend)" : "—")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar popover. Toggles between the home view (status + bolus) and the connection
/// (pairing) view via the gear button, so everything lives in the menu-bar tool.
struct MenuBarContentView: View {
    var model: MacRemoteModel
    @State private var showingConnection = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(showingConnection ? "Connection" : "faBolus")
                    .font(.headline)
                Spacer()
                Button {
                    showingConnection.toggle()
                } label: {
                    Image(systemName: showingConnection ? "chevron.backward" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help(showingConnection ? "Back" : "Connection settings")
            }

            if showingConnection {
                MacConnectionView(model: model)
            } else {
                MacStatusView(model: model)
                MacStatusPills(model: model)
                Divider()
                MacBolusEntryView(model: model)
                MacAlertsView(model: model)
                if !model.pairing.connected {
                    Button {
                        showingConnection = true
                    } label: {
                        Label(model.pairing.pairedPhone == nil ? "No iPhone paired — set up"
                                                               : "iPhone not reachable",
                              systemImage: "wifi.slash")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()
            HStack {
                Button("Refresh") { model.requestStatus() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
    }
}
