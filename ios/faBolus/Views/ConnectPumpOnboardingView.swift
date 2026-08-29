import SwiftUI
import faBolusCore

/// Skippable first-run "Connect your pump" step so a new user isn't dropped on a dead dashboard.
/// Opens the existing `PairingSheet` / `CgmSettingsView`; no new pump/pairing/dose logic.
/// All three exits call `modeStore.completePumpOnboarding()` so the step never reappears.
struct ConnectPumpOnboardingView: View {
    @Bindable var model: AppModel
    let modeStore: ModeStore
    @State private var showPairing = false

    /// Backend selection applies on next launch only (`BackendRegistry.makeSelected()` runs once at
    /// `App.swift` init). This id must stay a mock: if it vanished from `BackendRegistry.enabled`,
    /// `selected()` would fall back to `enabled[0]` (real `TandemBackend`) and this button would
    /// pair a live pump. Pinned by `BackendRegistryTests`.
    private static let demoBackendId = "mock-tslim"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Decorative — title/body already name the screen; don't announce the SF Symbol.
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

                    // Owner-signed-off experimental / not-FDA-cleared framing — reuse, don't redraft.
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

                        // Honest "no live swap": selecting a demo pump takes effect on next launch.
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

                    // Optional backup-CGM guidance — leaving via any of the three actions above skips it.
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
        // Mobi reject-at-pairing: observe here so it outlives the transient PairingSheet.
        .onChange(of: model.snapshot.pumpModel) { _, _ in model.rejectMobiIfDetected() }
    }
}
