import SwiftUI

@main
struct ControlX2App: App {
    // Uses the mock data source by default so the app runs in the Simulator without hardware.
    // Swap for a LivePumpDataSource (PumpX2Kit) when a pump is available.
    @State private var model = AppModel(source: MockPumpDataSource())

    var body: some Scene {
        WindowGroup {
            MainHUDView(model: model)
        }
    }
}
