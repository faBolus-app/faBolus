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
    @State private var notifier: PumpAlertNotifier?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView(model: model)
                .onAppear {
                    // Start listening for remote commands (double-confirm host).
                    if remoteHost == nil { remoteHost = PhoneRemoteHost(model: model) }       // Apple Watch
                    if garmin == nil { garmin = GarminRemoteBridge(model: model) }             // Garmin venu3s
                    if notifier == nil { notifier = PumpAlertNotifier(model: model) }           // actionable alert notifications
                    AppSettings.shared.syncWidgetPreset()
                    consumeWidgetBolus()   // the Quick-Bolus widget may have opened us to deliver
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { consumeWidgetBolus() }
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

    /// Deliver a bolus the Quick-Bolus widget confirmed (1-2-3) and handed off via the App Group.
    /// Goes through the same validated signed path as a Garmin remote bolus (progress + cancel
    /// shown in-app); the pump still enforces its max and signing.
    private func consumeWidgetBolus() {
        guard let r = WidgetBolusStore.takePending() else { return }
        model.openBolusRequested = true   // surface the delivering UI
        Task { await model.remoteDeliver(requestId: r.requestId, units: r.units) }
    }
}
