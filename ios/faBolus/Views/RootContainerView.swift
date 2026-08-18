import SwiftUI
import faBolusCore

/// App root: renders either the normal host tabs (controlling this phone's pump) or the app-wide
/// Remote mode, per `AppRouter`. Owns the router (and thus the persistent remote client) and injects it
/// so the "Controlling" switcher in Settings can flip between them.
struct RootContainerView: View {
    @Bindable var model: AppModel
    @State private var router = AppRouter()
    // P14 S3: the mode state machine (singleton — its init clamps the active mode to the earned ceiling
    // exactly once; everyone starts at Simple). Injected so Settings → Mode can drive it; it is the sole
    // writer of `AppSettings.appMode`, which the single access evaluator reads.
    @State private var modeStore = ModeStore.shared

    var body: some View {
        Group {
            switch router.target {
            case .thisPump:
                RootTabView(model: model)
            case .remote:
                if let remote = router.remote {
                    RemoteRootView(remote: remote)
                } else {
                    RootTabView(model: model)   // safety fallback (shouldn't happen)
                }
            }
        }
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
