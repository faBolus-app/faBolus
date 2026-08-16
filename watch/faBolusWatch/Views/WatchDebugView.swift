import SwiftUI
import faBolusCore

// Phase 09.6-05 (Task 2, Part C-3b, D-03.3, BENCH-ONLY): this file lives outside
// `direct-pump/` (a new sibling `Views/` directory), so `project.yml`'s
// `excludes: [direct-pump]` does NOT remove it from the default (shipping) watch target build —
// only the `#if FABOLUS_WATCH_DIRECT_PUMP` guard below does. In the default build the flag is
// undefined (dropped from `SWIFT_ACTIVE_COMPILATION_CONDITIONS` by `scripts/generate-project.sh`
// when `FABOLUS_WATCH_DIRECT_PUMP` isn't `1`), so this whole file compiles to nothing — `WatchPumpClient`
// itself doesn't exist in that configuration (the `direct-pump/` directory is excluded), so any
// unconditional reference to it here would fail the default build.
#if FABOLUS_WATCH_DIRECT_PUMP

/// READ-ONLY bench diagnostics screen over the watch's own direct-to-pump client
/// (`WatchPumpClient`). Renders `WatchPumpClient`'s already-tracked pairing/connection state as
/// plain rows — no control affordance beyond what `WatchDirectView` already exposes, and calls NO
/// `WatchPumpClient` control-path method (`pair`/`connectResume`/`disconnect`/`forget`). Reads only
/// `pump.statusForDiagnostics` / `pump.isPaired`, both pre-existing/additive read-only accessors.
///
/// BENCH-ONLY (D-04): this view adds NO new pairing/connect/control capability toward the deferred
/// Apple-Watch-host / phone-as-remote swap (STATE.md Deferred Items) — it is strictly observability
/// over the already-built `WatchPumpClient`, and `WatchDirectBleScopeGuardTests` pins
/// `WatchPumpClient`'s control-path function signatures as additive-only so a future edit here (or
/// there) can't quietly widen this screen into a control surface (T-09.6-03).
///
/// `pump` is injected by `WatchRootView` — the SAME instance `WatchDirectView` controls — so this
/// screen reflects the real connection state rather than a second, always-idle client.
struct WatchDebugView: View {
    @Bindable var pump: WatchPumpClient

    /// The SAME shared "Share local diagnostics" opt-in every phone-side diagnostics section gates
    /// on (`NotificationCoordinator.telemetryEnabledKey` on the phone), App-Group-backed
    /// (`WidgetStore.appGroup`, which the watch target IS a member of — see
    /// `faBolusWatch.entitlements`). The watch target does not compile `NotificationCoordinator.swift`
    /// (an iOS-app-only file, not in this target's sources), so the raw UserDefaults key literal is
    /// duplicated here rather than the storage — same flag, same App Group container, no new opt-in
    /// (D-04, Pitfall 3).
    private var diagnosticsEnabled: Bool {
        UserDefaults(suiteName: WidgetStore.appGroup)?.bool(forKey: "notificationBroker.telemetryEnabled") ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("[Watch bench]").font(.headline)
                if !diagnosticsEnabled {
                    Text("Turn on “Share local diagnostics” on the phone to view bench state here.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                } else {
                    row("Status", pump.statusForDiagnostics)
                    row("Paired", pump.isPaired ? "yes" : "no")
                }
                Text("Read-only. Pair/forget the direct connection from the Direct page.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .padding(.top, 4)
        }
        .navigationTitle("Bench debug")
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).font(.caption) }
    }
}

#endif
