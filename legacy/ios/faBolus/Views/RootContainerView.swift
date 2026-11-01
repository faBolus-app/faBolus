import SwiftUI
import faBolusCore

/// App root: renders the host tabs (controlling this phone's pump).
struct RootContainerView: View {
    @Bindable var model: AppModel
    // Singleton; tracks first-run onboarding state.
    @State private var modeStore = ModeStore.shared
    /// MANDATORY, once-only informational notification disclosure — fires at first launch, not on
    /// first alert, so the Urgent (break-through-Focus) rung is disclosed before it could ever
    /// matter. `false` initially and flipped `true` in `.task`, rather than driven directly from
    /// `NotificationDisclosureGate.hasShown`, so the cover only ever opens once per launch.
    @State private var showNotificationDisclosure = false

    var body: some View {
        RootTabView(model: model)
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
            .task {
                if !NotificationDisclosureGate.hasShown {
                    showNotificationDisclosure = true
                }
            }
            // `onDismiss:` (not just the button's own action) marks it shown, so a swipe-to-dismiss
            // counts too — the user saw it either way, and it must never re-show on a later launch.
            .sheet(isPresented: $showNotificationDisclosure, onDismiss: { NotificationDisclosureGate.markShown() }) {
                NotificationDisclosureView { showNotificationDisclosure = false }
            }
    }
}
