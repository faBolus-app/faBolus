import SwiftUI

@main
struct ControlX2WatchApp: App {
    @State private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchHUDView(model: model) }
    }
}
