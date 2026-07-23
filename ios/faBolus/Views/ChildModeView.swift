import SwiftUI
import faBolusCore

/// Reusable PIN entry. `.set` requires entering the PIN twice; `.verify` checks against the stored
/// hash and calls `onSuccess`. Used to arm child mode and to unlock it (change settings / turn off).
struct PinEntryView: View {
    enum Mode { case set, verify }
    let mode: Mode
    let prompt: String
    let onSuccess: (String) -> Void      // for .set: the new PIN; for .verify: the entered PIN
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIN (4–6 digits)", text: $pin)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    if mode == .set {
                        SecureField("Confirm PIN", text: $confirm)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    }
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) } else { Text(prompt) }
                }
            }
            .navigationTitle(mode == .set ? "Set PIN" : "Enter PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { submit() } }
            }
        }
    }

    private func submit() {
        let digits = pin.filter(\.isNumber)
        guard (4...6).contains(digits.count) else { error = "Use 4–6 digits."; return }
        switch mode {
        case .set:
            guard pin == confirm else { error = "PINs don't match."; return }
            onSuccess(digits); dismiss()
        case .verify:
            // Enforce the brute-force lockout (audit A-10).
            let locked = ChildModeStore.lockoutRemaining
            if locked > 0 {
                error = "Too many attempts. Try again in \(Int(locked.rounded(.up)))s."; pin = ""; return
            }
            if ChildModeStore.verify(digits) { onSuccess(digits); dismiss() }
            else {
                let now = ChildModeStore.lockoutRemaining
                error = now > 0 ? "Locked. Try again in \(Int(now.rounded(.up)))s." : "Incorrect PIN."
                pin = ""
            }
        }
    }
}

/// Manage child (locked) mode: arm it with a PIN, choose which actions stay allowed, and turn it off
/// (PIN required). Enforcement of the choices happens in `AppModel` (covering phone, widget, and all
/// remotes) — this screen only edits the policy.
struct ChildModeView: View {
    @Bindable var settings: AppSettings
    @State private var showSetPin = false
    @State private var showVerifyToDisable = false
    @State private var showVerifyToEdit = false
    @State private var unlockedForEditing = false

    var body: some View {
        Form {
            if !settings.childModeEnabled {
                Section {
                    Button { showSetPin = true } label: { Label("Turn on child mode", systemImage: "lock.fill") }
                } footer: {
                    Text("Sets a PIN and locks this device for a child: insulin delivery and settings changes are blocked unless you allow them below. You'll need the PIN to change these or turn it off.")
                }
            } else {
                Section {
                    Label("Child mode is on", systemImage: "lock.fill").foregroundStyle(.indigo)
                    Button(role: .destructive) { showVerifyToDisable = true } label: { Text("Turn off (PIN required)") }
                } footer: {
                    Text("Blocked actions no-op with a note on whichever device tried them — including the watch and Garmin.")
                }

                Section {
                    ForEach(ChildFeature.allCases) { feature in
                        Toggle(isOn: allowBinding(feature)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.label)
                                Text(feature.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!unlockedForEditing)
                    }
                } header: {
                    Text("Allowed while locked")
                } footer: {
                    if unlockedForEditing {
                        Text("On = the child may do it. Off = blocked. Insulin-affecting actions are off by default.")
                    } else {
                        Button("Unlock to edit (PIN)") { showVerifyToEdit = true }
                    }
                }

                Section {
                    Toggle("Require a parent to approve boluses", isOn: $settings.requireRemoteBolusApproval)
                        .disabled(!unlockedForEditing)
                } header: {
                    Text("Parent approval")
                } footer: {
                    Text("When on, a bolus started on this phone waits for a paired parent device (Mac or iPhone) to approve it — it isn't delivered until then, and is cancelled if no one responds within a minute. Requires **Remotes & devices → Allow remote devices** to be on and a parent device paired.")
                }
            }
        }
        .navigationTitle("Child mode")
        .sheet(isPresented: $showSetPin) {
            PinEntryView(mode: .set, prompt: "Choose a PIN the child doesn't know.") { newPin in
                ChildModeStore.setPIN(newPin)
                settings.childAllowed = ChildFeature.defaultAllowed
                settings.childModeEnabled = true
            }
        }
        .sheet(isPresented: $showVerifyToDisable) {
            PinEntryView(mode: .verify, prompt: "Enter the PIN to turn off child mode.") { _ in
                settings.childModeEnabled = false
                ChildModeStore.setPIN(nil)
                unlockedForEditing = false
            }
        }
        .sheet(isPresented: $showVerifyToEdit) {
            PinEntryView(mode: .verify, prompt: "Enter the PIN to change what's allowed.") { _ in
                unlockedForEditing = true
            }
        }
    }

    private func allowBinding(_ f: ChildFeature) -> Binding<Bool> {
        Binding(
            get: { settings.childAllowed.contains(f) },
            set: { on in
                if on { settings.childAllowed.insert(f) } else { settings.childAllowed.remove(f) }
            })
    }
}

/// Wraps the Settings content: when child mode is on and "Change settings" isn't allowed, the whole
/// Settings tab is hidden behind the PIN so the child can't change sources, pairing, or turn the mode
/// off. Unlock lasts for the current view session.
struct SettingsLockGate<Content: View>: View {
    @Bindable var settings: AppSettings
    @ViewBuilder var content: () -> Content
    @State private var unlocked = false
    @State private var showVerify = false

    private var locked: Bool { settings.childModeEnabled && !settings.childAllows(.changeSettings) && !unlocked }

    var body: some View {
        if locked {
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.indigo)
                Text("Settings are locked").font(.headline)
                Text("Child mode is on. Enter the PIN to change settings.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Enter PIN") { showVerify = true }.buttonStyle(.borderedProminent)
            }
            .padding()
            .sheet(isPresented: $showVerify) {
                PinEntryView(mode: .verify, prompt: "Enter the PIN to unlock settings.") { _ in unlocked = true }
            }
        } else {
            content()
        }
    }
}
