import SwiftUI
import faBolusCore

/// On-watch pairing: enter the pump's 6-digit code, then run JPAKE directly from the watch. A saved
/// Mobi PIN is prefilled (editable/clearable to pair a different pump). Saving is *offered after
/// pairing* once a Mobi is recognized — not decided up front. The derived secret is stored in the
/// watch Keychain (WatchPairingStore) for resume-auth later.
struct WatchPairingView: View {
    @Bindable var pump: WatchPumpClient
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var hadSavedPin = false
    @State private var pinOfferHandled = false

    // After a Mobi pairing with a typed code that isn't already saved, offer to save it.
    private var shouldOfferSave: Bool {
        WatchPumpModelStore.isMobi() == true && !code.isEmpty && code != WatchPairingStore.loadPin()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                switch pump.pairState {
                case .idle, .failed:
                    Text("Enter pump code").font(.headline)
                    TextField("6 digits", text: $code)
                        .textContentType(.oneTimeCode)
                        .font(.title3.monospacedDigit())
                        .multilineTextAlignment(.center)
                    if case let .failed(msg) = pump.pairState {
                        Text(msg).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    Button("Pair") { pinOfferHandled = false; pump.pair(code: code) }
                        .tint(.indigo)
                        .disabled(code.count != 6)
                    if hadSavedPin {
                        Button("Clear saved PIN", role: .destructive) {
                            WatchPairingStore.clearPin(); code = ""; hadSavedPin = false
                        }.font(.caption2)
                    }
                    Text("On the pump: Bluetooth → Pair Device (Mobi: on the charging pad, press the button twice; PIN is behind the cartridge).")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)

                case .connecting:
                    ProgressView()
                    Text("Connecting to pump…").font(.caption)

                case .pairing:
                    ProgressView()
                    Text("Pairing…").font(.caption)

                case .paired:
                    Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
                    Text("Paired!").font(.headline)
                    if shouldOfferSave && !pinOfferHandled {
                        Text("Save this Mobi's PIN so you don't re-type it next time?")
                            .font(.caption2).multilineTextAlignment(.center)
                        Button("Save PIN") { WatchPairingStore.savePin(code); pinOfferHandled = true }
                            .tint(.indigo)
                        Button("Not now") { pinOfferHandled = true }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .padding(.top, 4)
        }
        .navigationTitle("Pair")
        .onAppear {
            if let pin = WatchPairingStore.loadPin() { code = pin; hadSavedPin = true }   // prefill saved Mobi PIN
        }
    }
}
