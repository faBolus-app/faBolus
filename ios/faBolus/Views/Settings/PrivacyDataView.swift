import PhoneApp
import SwiftUI

/// Deleting what faBolus keeps on this phone. Refused while a bolus is in progress or its outcome is
/// unknown; the bolus record itself is never deleted, because it's what keeps an unknown outcome blocking.
struct PrivacyDataView: View {
    @Bindable var model: AppModel
    @State private var confirmErase = false
    @State private var confirmReset = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button("Delete history on this phone", role: .destructive) { confirmErase = true }
            } footer: {
                Text(
                    "Deletes the glucose, bolus and carb history and the logbook. Your pump pairing and CGM account are kept, and the pump's own history is untouched."
                )
            }
            Section {
                Button("Full reset", role: .destructive) { confirmReset = true }
            } footer: {
                Text(
                    "Deletes the history, forgets the pump and removes the Dexcom Share account. Your settings are kept. To use the pump again you pair with a new code."
                )
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle("Privacy & data")
        .confirmationDialog("Delete history on this phone?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Delete history", role: .destructive) {
                Task { message = text(await model.eraseHistory(), "History deleted.") }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Full reset?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset and forget the pump", role: .destructive) {
                Task { message = text(await model.fullReset(), "Reset done: history deleted, pump forgotten.") }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func text(_ result: AppModel.EraseResult, _ done: String) -> String {
        switch result {
        case .erased: return done
        case .refused(let why): return why
        }
    }
}
