import SwiftUI
import faBolusCore

/// App root: renders the host tabs (controlling this phone's pump), per `AppRouter`. Phase 3 (03-02,
/// REMOTE-02): the app-wide Remote mode (`.remote` target) is removed from narrow `main` along with
/// `PhoneRemoteClientModel`/`RemoteRootView` (preserved on `dev/phone-remote`); `AppRouter` now has a
/// single target, kept (not deleted) per the plan's scope.
struct RootContainerView: View {
    @Bindable var model: AppModel
    @State private var router = AppRouter()
    // P14 S3: the mode state machine (singleton — its init clamps the active mode to the earned ceiling
    // exactly once; everyone starts at Simple). Injected so Settings → Mode can drive it; it is the sole
    // writer of `AppSettings.appMode`, which the single access evaluator reads.
    @State private var modeStore = ModeStore.shared

    var body: some View {
        RootTabView(model: model)
        .environment(router)
        .environment(modeStore)
        // Phase 8 (08-01, LOCK-01): the first-run mode-onboarding `fullScreenCover` (`ModeOnboardingView`)
        // is removed — everyone now starts directly at Advanced (`ModeStore.init` force-sets
        // `hasCompletedOnboarding = true`), so the KEPT `ConnectPumpOnboardingView` step below's `&&`
        // condition is trivially satisfied without any change to its own gate logic.
        // Phase 09.4 (D-01): the skippable "Connect your pump" step, shown exactly once — AFTER the mode
        // step, and only while there's no stored pairing. Not gated by `router.target`/tabs, so it
        // presents regardless of which tab would otherwise render underneath.
        .fullScreenCover(isPresented: .init(
            get: { modeStore.hasCompletedOnboarding && !modeStore.hasCompletedPumpOnboarding && !model.hasStoredPairing },
            set: { _ in }
        )) {
            ConnectPumpOnboardingView(model: model, modeStore: modeStore)
        }
    }
}
