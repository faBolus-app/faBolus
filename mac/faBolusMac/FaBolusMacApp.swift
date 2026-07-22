import SwiftUI
import AppKit
import faBolusCore

/// Menu-bar-only remote (no Dock icon / no main window — see `LSUIElement` in project.yml). Shows
/// the current glucose in the menu bar; clicking opens a popover with status, quick bolus, alerts,
/// and (behind the gear) display customization + iPhone pairing.
@main
struct FaBolusMacApp: App {
    @State private var model = MacRemoteModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
                .frame(width: 300)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The label shown in the menu bar. Composed per the user's Display settings, optionally colored by
/// glucose range.
struct MenuBarLabel: View {
    var model: MacRemoteModel

    var body: some View {
        let d = model.display
        // In the menu bar, hide the value once hidden — and (by default) once merely stale — so an old
        // number can't read as current. The popover still shows the greyed value.
        let hideStale = d.menuBarHideStale && model.isGlucoseStale
        if let g = model.glucose, !model.glucoseHidden, !hideStale {
            var s = model.displayGlucose
            if d.menuBarShowUnits { s += " mg/dL" }
            if d.menuBarShowTrend { s += " \(model.trend)" }
            if d.menuBarShowDelta, let delta = model.deltaText { s += " \(delta)" }
            if d.menuBarShowIOB { s += String(format: " · %.1fU", model.iobUnits) }
            let color: Color = (d.menuBarColorByRange && !model.isGlucoseStale) ? MacTheme.glucoseColor(g) : .primary
            return Text(s).foregroundStyle(color)
        } else {
            return Text("—").foregroundStyle(.primary)
        }
    }
}

/// The menu-bar popover. Toggles between the home view (status + bolus) and the settings view
/// (display options + connection) via the gear button, so everything lives in the menu-bar tool.
struct MenuBarContentView: View {
    var model: MacRemoteModel
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(showingSettings ? "Settings" : "faBolus")
                    .font(.headline)
                Spacer()
                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: showingSettings ? "chevron.backward" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help(showingSettings ? "Back" : "Settings")
            }

            if showingSettings {
                ScrollView {
                    MacSettingsPane(model: model, display: model.display)
                        .padding(.trailing, 12)   // keep content clear of the overlay scroll bar
                }
                .frame(maxHeight: 400)
            } else {
                MacStatusView(model: model)
                MacStatusPills(model: model)
                Divider()
                MacBolusEntryView(model: model)
                MacAlertsView(model: model)
                if !model.pairing.connected {
                    Button {
                        showingSettings = true
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
        .background {
            // Optional solid (opaque) background instead of the translucent system material.
            if model.display.solidBackground {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea()
            }
        }
    }
}
