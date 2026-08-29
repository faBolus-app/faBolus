import SwiftUI
import faBolusCore

/// App root: renders the host tabs (controlling this phone's pump), per `AppRouter`.
struct RootContainerView: View {
    @Bindable var model: AppModel
    @State private var router = AppRouter()
    // Singleton; sole writer of `AppSettings.appMode` (forces `.advanced` once at init).
    @State private var modeStore = ModeStore.shared

    var body: some View {
        RootTabView(model: model)
            .environment(router)
            .environment(modeStore)
            // Skippable "Connect your pump" step, shown once while there's no stored pairing.
            .fullScreenCover(
                isPresented: .init(
                    get: {
                        modeStore.hasCompletedOnboarding && !modeStore.hasCompletedPumpOnboarding
                            && !model.hasStoredPairing
                    },
                    set: { _ in }
                )
            ) {
                ConnectPumpOnboardingView(model: model, modeStore: modeStore)
            }
    }
}
