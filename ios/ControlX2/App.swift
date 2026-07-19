import SwiftUI

@main
struct ControlX2App: App {
    // On a device, talk to a real pump via PumpX2Kit. In the Simulator (no Bluetooth) use the
    // mock so the UI is still demoable.
    #if targetEnvironment(simulator)
    @State private var model = AppModel(source: MockPumpDataSource())
    #else
    @State private var model = AppModel(source: LivePumpDataSource())
    #endif
    @State private var remoteHost: PhoneRemoteHost?
    @State private var garmin: GarminRemoteBridge?

    var body: some Scene {
        WindowGroup {
            MainHUDView(model: model)
                .onAppear {
                    // Start listening for remote commands (double-confirm host).
                    if remoteHost == nil { remoteHost = PhoneRemoteHost(model: model) }       // Apple Watch
                    if garmin == nil { garmin = GarminRemoteBridge(model: model) }             // Garmin venu3s
                }
                .onOpenURL { url in
                    if url.scheme == ControlX2DeepLink.scheme {
                        // Widget tap-to-bolus / open (controlx2://bolus). Opens the confirm flow.
                        if url.host == "bolus" { model.openBolusRequested = true }
                    } else {
                        garmin?.handleOpenURL(url)   // Connect IQ device-selection callback
                    }
                }
        }
    }
}
