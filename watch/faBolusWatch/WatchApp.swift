import SwiftUI
import faBolusCore

@main
struct FaBolusWatchApp: App {
    @State private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchRootView(model: model) }
    }
}

/// Paged watch UI, mirroring the phone tabs / Garmin screens: Glance · Chart · Details · Alerts.
/// Swipe left/right between pages. Bolus opens as a sheet from the glance.
struct WatchRootView: View {
    @Bindable var model: WatchModel
    @State private var showBolus = false

    var body: some View {
        TabView {
            WatchGlanceView(model: model, showBolus: $showBolus)
            WatchChartView(model: model)
            WatchDetailsView(model: model)
            WatchAlertsView(model: model)
            WatchDirectView()
        }
        .tabViewStyle(.page)
        // The load-bearing block: the bolus sheet can never present in read-only mode, however showBolus is set.
        .sheet(isPresented: Binding(get: { showBolus && !model.readOnly }, set: { showBolus = $0 })) {
            WatchBolusView(model: model)
        }
        .onAppear { model.requestStatus() }
    }
}

/// Shared modern glucose color.
func watchGlucoseColor(_ mgdl: Int?, stale: Bool) -> Color {
    guard let g = mgdl, !stale else { return .gray }
    switch RemoteGlucose.band(g) {
    case 0: return .red
    case 1: return .green
    case 2: return .yellow
    default: return .orange
    }
}
