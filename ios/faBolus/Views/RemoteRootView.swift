import SwiftUI
import faBolusCore

/// App-wide **Remote mode**: the whole app operates as a remote for another phone's pump. Mirrors the
/// host tab layout (a Remote dashboard + Settings) so it looks and behaves like a host. The remote
/// model is owned by `AppRouter` and stays alive across switches. Switch back to this phone's own pump
/// under Settings → Controlling.
struct RemoteRootView: View {
    @Bindable var host: AppModel
    @Bindable var remote: PhoneRemoteClientModel

    var body: some View {
        TabView {
            NavigationStack {
                Group {
                    if remote.conn.authenticated {
                        RemoteDashboardView(model: remote)
                    } else {
                        RemotePairingView(model: remote)
                    }
                }
                .navigationTitle(remote.conn.authenticated ? (remote.conn.pairedHost ?? "Remote") : "Pair a remote")
                .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Remote", systemImage: "iphone.gen3.radiowaves.left.and.right") }

            // Settings stay app-wide (the "Controlling" switcher lives here to get back to this pump).
            SettingsView(model: host)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
