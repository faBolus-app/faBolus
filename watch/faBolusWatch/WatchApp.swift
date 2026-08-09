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
            // C9 ("one owner, N remotes"): the direct-to-pump page is a SECOND pump-connection
            // holder that bypasses the PumpBackend seam, and pairing it EVICTS the phone. It is
            // excluded from shipping builds — see watch/faBolusWatch/direct-pump/STATUS.md.
            // Enable with FABOLUS_WATCH_DIRECT_PUMP=1 ./scripts/generate-project.sh (bench only).
            #if FABOLUS_WATCH_DIRECT_PUMP
            WatchDirectView()
            #endif
        }
        .tabViewStyle(.page)
        // N12 (Dynamic Type): scale up to the largest accessibility text size across every watch page.
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
        // The load-bearing block: the bolus sheet can never present unless remotes aren't read-only AND the
        // phone has enabled watch bolusing (§2.3), however showBolus is set.
        .sheet(isPresented: Binding(get: { showBolus && model.watchBolusAllowed }, set: { showBolus = $0 })) {
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
