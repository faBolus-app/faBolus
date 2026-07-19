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

    var body: some Scene {
        WindowGroup {
            MainHUDView(model: model)
                .onAppear {
                    // Start listening for watch/Garmin remote commands (double-confirm host).
                    if remoteHost == nil { remoteHost = PhoneRemoteHost(model: model) }
                }
        }
    }
}
