import SwiftUI

/// A blocking "this feature is untested" gate for the app's unverified, hardware-unvalidated
/// features (the best-guess parameters catalogued in `docs/UNVERIFIED-GUESSES.md`).
///
/// Passive ⚠️ section footers already explain these, but a footer is easy to skip past — this makes
/// the risk **unmissable**: before the action runs, a modal states the feature has NOT been verified
/// on a real pump and will likely not work, and the user must explicitly acknowledge it. It is shown
/// **every time** (not a persisted one-off acknowledgement) because the gated actions are
/// insulin-schedule- or pump-config-affecting — accidental repeat use is exactly what we're guarding.
///
/// Usage:
/// ```
/// @State private var unverified = UnverifiedFeatureGate()
/// // …
/// Button("Set") { unverified.request("The CGM high/low alert mapping") { Task { await model.set… } } }
/// // …
/// .unverifiedFeatureGate(unverified)   // on the Form / container
/// ```
@MainActor
@Observable
final class UnverifiedFeatureGate {
    var isPresented = false
    private(set) var feature = ""
    private var pending: (() -> Void)?

    /// Arm the gate for `feature`; the modal's "Use it anyway" runs `action`, "Cancel" discards it.
    func request(_ feature: String, _ action: @escaping () -> Void) {
        self.feature = feature
        self.pending = action
        self.isPresented = true
    }

    func proceed() { let p = pending; pending = nil; p?() }
    func cancel() { pending = nil }
}

extension View {
    /// Attach the blocking untested-feature modal driven by `gate`. Place on the enclosing view; arm
    /// it from an action with `gate.request(_:_:)`.
    func unverifiedFeatureGate(_ gate: UnverifiedFeatureGate) -> some View {
        let binding = Binding(get: { gate.isPresented }, set: { gate.isPresented = $0 })
        return alert("Untested feature", isPresented: binding) {
            Button("Use it anyway", role: .destructive) { gate.proceed() }
            Button("Cancel", role: .cancel) { gate.cancel() }
        } message: {
            Text("⚠️ \(gate.feature) has NOT been verified on a real pump and will likely not work — it may do nothing or behave unexpectedly. It's a best-guess implementation from the protocol, not confirmed on hardware.\n\nOnly continue if you understand the risk and are watching the pump to confirm what actually happened.")
        }
    }
}
