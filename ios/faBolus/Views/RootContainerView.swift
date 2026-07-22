import SwiftUI
import faBolusCore

/// App root: renders either the normal host tabs (controlling this phone's pump) or the app-wide
/// Remote mode, per `AppRouter`. Owns the router (and thus the persistent remote client) and injects it
/// so the "Controlling" switcher in Settings can flip between them.
struct RootContainerView: View {
    @Bindable var model: AppModel
    @State private var router = AppRouter()

    var body: some View {
        Group {
            switch router.target {
            case .thisPump:
                RootTabView(model: model)
            case .remote:
                if let remote = router.remote {
                    RemoteRootView(host: model, remote: remote)
                } else {
                    RootTabView(model: model)   // safety fallback (shouldn't happen)
                }
            }
        }
        .environment(router)
    }
}
