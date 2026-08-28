import SwiftUI
import faBolusCore

/// Skippable first-run "Connect your pump" step so a new user isn't dropped on a dead dashboard.
/// Opens the existing `PairingSheet` / `CgmSettingsView`; no new pump/pairing/dose logic.
/// All three exits call `modeStore.completePumpOnboarding()` so the step never reappears.
struct ConnectPumpOnboardingView: View {
    @Bindable var model: AppModel
    let modeStore: ModeStore
    @State private var showPairing = false

    /// Load-bearing (UI-SPEC): `BackendRegistry.makeSelected()` runs once at `App.swift` init — there is
    /// no live backend hot-swap. Selecting the demo pump only persists a choice for NEXT launch, so the
    /// footnote below is the entire state contract (no spinner, no fake progress, no relaunch mechanism).
    ///
    /// Phase 9 (09-03, MOBI-01, RESEARCH Pitfall 1): the Simulated-Mobi descriptor this id used to name
    /// is removed from `BackendRegistry.enabled` in the SAME commit as this edit. Deleting that
    /// descriptor WITHOUT this patch would make `BackendRegistry.selected()`'s fallback-to-`enabled[0]`
    /// resolve this button to the REAL `TandemBackend` on a device — a genuine on-device safety hazard,
    /// not a cosmetic one. `BackendRegistryTests.onboardingDemoIdResolvesToMockBackendNotTandem` pins this.
    private static let demoBackendId = "mock-tslim"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // D2-08 (WINDOWS ledger #24): decorative — the "Connect your pump" title and body
                    // below already state this screen's purpose, so hide the hero glyph from VoiceOver
                    // rather than letting it announce its raw SF Symbol name. Mirrors the decorative-icon
                    // hiding applied in 17-09 to AlertsView/CameraPermissionFallbackView and the existing
                    // StatusPillsView/StatusRingView convention.
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 56)).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Connect your pump").font(.title.bold())
                    Text(
                        "faBolus needs a pump connection to show your glucose and let you give a bolus. Connect now, explore with a demo pump, or skip and connect later from the dashboard."
                    )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                    // D1-04: the owner-signed-off (2026-08-09) experimental/not-FDA-cleared framing,
                    // reused verbatim from RegulatoryCopy — never redrafted here (17-PATTERNS.md
                    // "Existing-signed-off copy reuse over new copy"). RegulatoryCopyTests already pins
                    // its required-keyword content.
                    Text(RegulatoryCopy.firstRun)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button {
                        showPairing = true
                    } label: {
                        Text("Connect a pump").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    VStack(spacing: 6) {
                        Button {
                            BackendRegistry.select(Self.demoBackendId)
                            modeStore.completePumpOnboarding()
                        } label: {
                            Text("Use a demo pump").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).controlSize(.large)

                        // UI-SPEC §1: verbatim reuse of the SettingsView.swift:526 disclosure — the
                        // honest "no live swap" state contract, always visible under the button.
                        Text("Takes effect after you reopen the app.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    Button {
                        modeStore.completePumpOnboarding()
                    } label: {
                        Text("Skip for now")
                    }
                    .foregroundStyle(.secondary)

                    Divider().padding(.vertical, 4)

                    // D-02: optional, skippable CGM-failover guidance — no explicit skip control, since
                    // leaving the screen via any of the three actions above already skips it.
                    VStack(spacing: 8) {
                        Text("Optional: add a backup glucose feed").font(.headline)
                        Text(
                            "faBolus can use an independent glucose feed — such as Dexcom Share — as a backup. It's only shown if the pump's own reading goes stale. This is optional and you can skip it."
                        )
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        NavigationLink {
                            CgmSettingsView(model: model, settings: AppSettings.shared)
                        } label: {
                            Text("Set up backup CGM")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showPairing) {
            PairingSheet(model: model) {
                showPairing = false
                modeStore.completePumpOnboarding()
            }
        }
        // Phase 9 Plan 01 (MOBI-01/MOBI-03, D-03): reject-at-pairing observer — same shared helper as
        // MainHUDView's/SettingsView's triggers (`ios/faBolus/Data/AppModel+MobiReject.swift`), anchored
        // at this view's root so it OUTLIVES the transient `PairingSheet` presented above.
        .onChange(of: model.snapshot.pumpModel) { _, _ in model.rejectMobiIfDetected() }
    }
}
