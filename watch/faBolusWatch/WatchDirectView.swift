import SwiftUI

/// "Direct" page: pair the watch straight to the pump (independent of the iPhone). Phase 1 —
/// pairing only; status + delivery over the direct link come in Phase 2. Because the pump keeps
/// one pairing at a time, pairing the watch evicts the phone (it must re-pair to use the pump).
struct WatchDirectView: View {
    @State private var pump = WatchPumpClient()
    @State private var showPairing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Direct to pump").font(.headline)

                if pump.isPaired {
                    Label("Paired directly", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                    Text("The watch is paired straight to the pump. Delivery over this link is coming (Phase 2).")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Re-pair") { showPairing = true }.tint(.indigo)
                    Button(role: .destructive) { pump.forget() } label: { Text("Forget pairing") }
                } else {
                    Text("Pair the watch to the pump to use it without your iPhone.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { showPairing = true } label: { Label("Pair to pump", systemImage: "antenna.radiowaves.left.and.right") }
                        .tint(.indigo)
                    Text("Uses a fresh code from the pump. Pairing the watch unpairs your iPhone.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $showPairing) { WatchPairingView(pump: pump) }
    }
}
