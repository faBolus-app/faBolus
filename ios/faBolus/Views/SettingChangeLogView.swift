import SwiftUI
import UIKit
import faBolusCore

/// §2.1(3)(4) B1(b)+B1(c): the therapy-settings CHANGE LOG — a human-readable, shareable audit trail of
/// every recorded setting change (origin + before/after + when), newest first, with a **one-tap revert**
/// on the current value of each setting. Reached from `PumpControlView` (already behind advanced-control +
/// not-read-only), so a plain caregiver/viewer phone never surfaces it. The shareable/copyable text is the
/// deterministic `SettingChangeLog.exportText()`. A revert re-applies the previous value through the SAME
/// gated therapy-write funnel as a normal edit (ack + capability + read-only + WritePolicy all still apply)
/// and is itself recorded as a new change.
struct SettingChangeLogView: View {
    let model: AppModel
    @State private var pendingRevert: PendingRevert?

    private struct PendingRevert: Identifiable {
        let id = UUID()
        let key: SettingKey
        let title: String
        let toDisplay: String
    }

    var body: some View {
        let o = model.settingChangeStore.loadOutcome()
        Form {
            if o.failedClosed {
                Section {
                    Label("Settings history is unavailable (the log couldn't be read).",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            } else if o.log.history().isEmpty {
                Section { Text("No setting changes recorded yet.").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(Array(o.log.history().enumerated()), id: \.offset) { _, c in
                        // Revert is offered ONLY on a key's CURRENT change (reverting a superseded one would
                        // fight a newer edit) and only when it has a previous value to restore.
                        let target = (o.log.current(c.key) == c) ? o.log.revertTarget(c.key) : nil
                        row(c, revertTo: target)
                    }
                } footer: {
                    Text("Every therapy-setting change is recorded with its origin and time. This log stays on this device. Revert re-applies the previous value to the pump — it asks for confirmation and needs a live pump connection.")
                }
                Section {
                    ShareLink(item: o.log.exportText()) { Label("Share log", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = o.log.exportText() } label: {
                        Label("Copy log", systemImage: "doc.on.doc")
                    }
                }
            }
            if let err = model.lastError {
                Section { Text(err).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Change log")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Revert this setting?",
                            isPresented: Binding(get: { pendingRevert != nil },
                                                 set: { if !$0 { pendingRevert = nil } }),
                            presenting: pendingRevert) { r in
            Button("Revert to \(r.toDisplay)", role: .destructive) {
                let key = r.key
                // This explicit confirm IS the untested-feature acknowledgment for the one gated write the
                // revert performs (parallel to the editor's warning sheet). It does NOT bypass any other
                // gate — child mode / read-only / capability are all still enforced inside `revertSetting`.
                Task { model.acknowledgeUnverifiedTherapy(); await model.revertSetting(key) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("This changes \(r.title) on your pump back to \(r.toDisplay). It's recorded as a new change and can itself be reverted.")
        }
    }

    @ViewBuilder private func row(_ c: StoredSettingChange, revertTo: BackupValue?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Self.fieldTitle(c.key)).fontWeight(.medium)
                Spacer(minLength: 8)
                Label(ClinicianTierAck.label(for: c.provenance), systemImage: c.provenance.symbolName)
                    .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            Text("\(c.before?.displayString ?? "—") → \(c.after.displayString)").font(.subheadline)
            Text(Date(timeIntervalSince1970: TimeInterval(c.atSeconds))
                    .formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let revertTo {
                Button {
                    pendingRevert = PendingRevert(key: c.key, title: Self.fieldTitle(c.key),
                                                  toDisplay: revertTo.displayString)
                } label: { Label("Revert", systemImage: "arrow.uturn.backward") }
                    .tint(.orange)
                    .disabled(!model.pumpReady)
            }
        }
    }

    /// A human title for a change row: the field's friendly name, plus the segment start time for a
    /// per-segment key. `nonisolated` because it's a pure string mapping with no view/actor state — a
    /// SwiftUI `View` is implicitly `@MainActor`, so without this a nonisolated test can't call it (Xcode
    /// 16.4 strict-concurrency rejects it, though the local 26.6 toolchain compiles it — the "local ≠ CI" trap).
    nonisolated static func fieldTitle(_ key: SettingKey) -> String {
        let name: String
        switch key.field {
        case "basalRate":        name = "Basal rate"
        case "carbRatio":        name = "Carb ratio"
        case "isf":              name = "Correction factor (ISF)"
        case "targetBg":         name = "Target glucose"
        case "maxBolus":         name = "Max bolus"
        case "maxBasal":         name = "Max basal"
        case "controlIQEnabled": name = "Control-IQ"
        default:                 name = key.field
        }
        if let start = key.segmentStartMinutes {
            return "\(name) · \(String(format: "%02d:%02d", start / 60, start % 60))"
        }
        return name
    }
}
