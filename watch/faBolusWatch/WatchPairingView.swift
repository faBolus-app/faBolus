import SwiftUI
import faBolusCore

/// On-watch pairing: enter the pump's fresh 6-digit code, then run JPAKE directly from the watch.
/// The derived secret is stored in the watch Keychain (WatchPairingStore) for resume-auth later.
struct WatchPairingView: View {
    @Bindable var pump: WatchPumpClient
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

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
                    Button("Pair") { pump.pair(code: code) }
                        .tint(.indigo)
                        .disabled(code.count != 6)
                    Text("On the pump: Options → Device Settings → Bluetooth → Pair Device.")
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
                    Button("Done") { dismiss() }
                }
            }
            .padding(.top, 4)
        }
        .navigationTitle("Pair")
    }
}
