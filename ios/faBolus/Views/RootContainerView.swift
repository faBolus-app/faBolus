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
        // First-run mode onboarding, shown exactly once (gated on the store). Not interactively
        // dismissable — the "Start in Simple" tap is the acknowledgment that sets the flag.
        .fullScreenCover(isPresented: .init(get: { !modeStore.hasCompletedOnboarding }, set: { _ in })) {
            ModeOnboardingView(modeStore: modeStore)
        }
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
