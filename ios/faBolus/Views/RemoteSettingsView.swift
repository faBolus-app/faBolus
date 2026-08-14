import SwiftUI
import faBolusCore

/// 09.3-04 (SC1, D-04): `showStats` is bound from two mutually-exclusive screens (host
/// `DisplaySettingsView` and remote `RemoteSettingsView` — `AppRouter.target` never shows both at once).
/// A single shared footer string makes the two Toggles explicit, labeled mirrors of one property rather
/// than two independently-drifting descriptions of the same stats card.
enum StatsCardCopy {
    static let footer = "Adds a dashboard card with Time-in-Range, GMI, average, and variability (CV) over the last ~24 hours of readings held in memory."
}

/// The "Controlling" switcher: flip the whole app between driving this phone's own pump and acting as a
/// remote for another phone. Reused at the bottom of Remotes & devices (host) and in the trimmed
/// remote-mode Settings.
struct ControllingSection: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        Section {
            Button { router.controlThisPump() } label: {
                row("This phone's pump", "cross.case.fill", selected: router.target == .thisPump)
            }.tint(.primary)
            Button { router.controlRemote() } label: {
                row(router.remote?.conn.pairedHost.map { "Remote: \($0)" } ?? "Remote (another phone)",
                    "iphone.gen3.radiowaves.left.and.right", selected: router.target == .remote)
            }.tint(.primary)
        } header: { Text("Controlling") } footer: {
            Text("Use this phone for its own pump, or turn the whole app into a remote for another phone's pump. Switching is instant and your pairing is remembered.")
        }
    }

    @ViewBuilder private func row(_ title: String, _ icon: String, selected: Bool) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }
}

/// Trimmed Settings shown while the app is in **Remote mode** — only what applies to being a remote:
/// the Controlling switcher (to go back to this phone's pump), the remote dashboard's display options,
/// forgetting the host, and help. The host's own settings (pump, CGM, alerts, watch/Garmin, child mode)
/// don't apply to a remote and are hidden.
struct RemoteSettingsView: View {
    @Bindable var remote: PhoneRemoteClientModel
    @State private var settings = AppSettings.shared

    var body: some View {
        NavigationStack {
            List {
                ControllingSection()

                if remote.conn.pairedHost != nil {
                    Section {
                        Toggle("Show statistics card", isOn: $settings.showStats)
                    } header: { Text("Remote dashboard") } footer: {
                        Text(StatsCardCopy.footer)
                    }
                    Section {
                        Button("Forget this host", role: .destructive) { remote.conn.forget() }
                    } footer: {
                        Text("Removes the pairing with \(remote.conn.pairedHost ?? "the host"). Scan its QR again to reconnect.")
                    }
                }

                Section {
                    Link(destination: faBolusHelpURL) { Label("Help & documentation", systemImage: "questionmark.circle") }
                } footer: { Text("Opens faBolus.org.") }
            }
            .navigationTitle("Settings")
        }
    }
}
