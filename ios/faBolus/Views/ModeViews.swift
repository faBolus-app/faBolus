import SwiftUI
import faBolusCore

// P14 Slice 3 — the first-run mode host + the mechanism to change mode.
//
// §13 NOTICE: every user-facing string in this file is DRAFT and is experimental-distribution surface —
// it must pass clinical review before an `experimental` build is distributed (BRANCHES.md §13). The
// mechanism (ModeStore) is copy-agnostic.
//
// P16 F6 (N13) — localization SEED: this file's mode/Objectives copy is the first slice backed by the
// app's String Catalog (`Localizable.xcstrings`). The SwiftUI `Text("…")`/`Button("…")`/`Label("…")`
// literals below already localize via `LocalizedStringKey`; their keys are seeded in the catalog. The
// mode descriptions route through `ModeCopy` (`String(localized:)`). English wording is UNCHANGED — the
// seed proves the pipeline, it does not re-word anything, and the §13 gate above is unaffected.

/// First-run overlay. Everyone starts in Simple (owner-locked); this simply explains that and dismisses.
/// Presented once (gated on `ModeStore.hasCompletedOnboarding`), never interactively dismissable so the
/// acknowledgment is explicit.
struct ModeOnboardingView: View {
    let modeStore: ModeStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "dial.medium.fill").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Welcome to faBolus").font(.title.bold())
                Text("faBolus starts in **Simple mode** — the essentials: see your glucose and give a bolus. As you get comfortable you can unlock more, one step at a time, in **Settings → Mode**.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Text(RegulatoryCopy.firstRun)
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .padding(.horizontal)
                Spacer()
                Button { modeStore.completeOnboarding() } label: {
                    Text("Start in Simple mode").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding()
            .interactiveDismissDisabled()
        }
    }
}

/// The mode control surface (Settings → Mode): the current-mode picker (clamped to what's earned), the
/// guided next-step unlock, and the expert opt-out (behind a warning). All state changes go through
/// `ModeStore`, which clamps in the store — the UI can only *offer* a change.
struct ModeSettingsView: View {
    @Environment(ModeStore.self) private var modeStore
    @State private var showUnlockConfirm = false
    @State private var showOptOutWarning = false

    private var nextTier: AppMode? {
        switch modeStore.earnedMode {
        case .simple: return .standard
        case .standard: return .advanced
        case .advanced: return nil
        }
    }

    // P16 F6 (N13): the mode descriptions now resolve through the String Catalog (see `ModeCopy` /
    // `Localizable.xcstrings`). English values are unchanged; this is a localization-mechanism seed.
    private func blurb(_ mode: AppMode) -> String { ModeCopy.description(mode) }

    var body: some View {
        Form {
            Section {
                Picker("Current mode", selection: Binding(
                    get: { modeStore.activeMode },
                    set: { modeStore.select($0) }
                )) {
                    ForEach(AppMode.allCases.filter { $0 <= modeStore.earnedMode }, id: \.self) { m in
                        Text(m.title).tag(m)
                    }
                }
            } header: { Text("Mode") } footer: {
                Text("\(modeStore.activeMode.title): \(blurb(modeStore.activeMode)) You can switch down anytime; switching up needs the setup step below.")
            }

            if let next = nextTier {
                Section {
                    Button { showUnlockConfirm = true } label: {
                        Label("Set up \(next.title) mode…", systemImage: "arrow.up.forward.circle")
                    }
                } footer: {
                    Text(blurb(next))
                }
            }

            Section {
                Button(role: .destructive) { showOptOutWarning = true } label: {
                    Label("I already know pump control — unlock Advanced", systemImage: "bolt.badge.a")
                }
            } footer: {
                Text("Skips the guided steps and switches straight to Advanced. Only if you already understand these features.")
            }
        }
        .navigationTitle("Mode")
        .confirmationDialog("Continue to \(nextTier?.title ?? "next") mode?",
                            isPresented: $showUnlockConfirm, titleVisibility: .visible) {
            if let next = nextTier {
                Button("Unlock \(next.title)") { modeStore.completeNextObjective() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(nextTier.map(blurb) ?? "") }
        .alert("Unlock Advanced mode?", isPresented: $showOptOutWarning) {
            Button("Unlock Advanced", role: .destructive) { modeStore.expertOptOutToAdvanced() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Advanced mode exposes temp basal, profiles, Control-IQ settings, and pump limits — these change therapy. Only continue if you understand them.")
        }
    }
}
