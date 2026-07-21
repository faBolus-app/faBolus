import SwiftUI
import faBolusCore

@main
struct FaBolusApp: App {
    // The pump backend is chosen from the compile-time BackendRegistry (Tandem on device, mock in
    // the Simulator by default; user-selectable when more than one backend is compiled in).
    @State private var model = AppModel(source: BackendRegistry.makeSelected())
    @State private var remoteHost: PhoneRemoteHost?
    @State private var peerHost: PeerRemoteHost?
    @State private var garmin: GarminRemoteBridge?
    @State private var notifier: PumpAlertNotifier?
    @State private var widgetBolus: WidgetBolusReceiver?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView(model: model)
                .alert("Save this pump's PIN?", isPresented: Binding(
                    get: { model.savePinPrompt != nil },
                    set: { if !$0 { model.dismissSavePinPrompt() } }
                )) {
                    Button("Save PIN") { model.saveOfferedPin() }
                    Button("Not now", role: .cancel) { model.dismissSavePinPrompt() }
                } message: {
                    Text("This looks like a Tandem Mobi — its PIN doesn't change. faBolus can save it so you don't re-type it next time you connect. You can change or clear it later on the Connect screen.")
                }
                .onAppear {
                    // Start listening for remote commands (double-confirm host).
                    if remoteHost == nil { remoteHost = PhoneRemoteHost(model: model) }       // Apple Watch
                    if peerHost == nil { peerHost = PeerRemoteHost(model: model) }             // Mac / iPhone remote (BLE)
                    if garmin == nil { garmin = GarminRemoteBridge(model: model) }             // Garmin venu3s
                    if notifier == nil {
                        notifier = PumpAlertNotifier(model: model)                              // actionable alert notifications
                        model.onNudge = { [weak notifier] title, body in notifier?.nudge(title: title, body: body) }
                    }
                    if widgetBolus == nil { widgetBolus = WidgetBolusReceiver(model: model) }    // Quick-Bolus widget delivery
                    AppSettings.shared.syncWidgetConfig()
                    AppSettings.shared.applyFreshness()   // stale/hide thresholds → faBolusCore
                    widgetBolus?.handlePending()   // deliver any queued widget bolus (suspended-app fallback)
                    if WidgetStore.takeOpenBolusRequest() { model.openBolusRequested = true }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        widgetBolus?.handlePending()
                        if WidgetStore.takeOpenBolusRequest() { model.openBolusRequested = true }
                    }
                }
                .onOpenURL { url in
                    if url.scheme == FaBolusDeepLink.scheme {
                        // Widget tap-to-bolus / open (fabolus://bolus). Opens the confirm flow.
                        if url.host == "bolus" { model.openBolusRequested = true }
                    } else {
                        garmin?.handleOpenURL(url)   // Connect IQ device-selection callback
                    }
                }
        }
    }
}
