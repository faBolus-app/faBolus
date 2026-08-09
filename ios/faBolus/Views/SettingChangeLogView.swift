import SwiftUI
import UIKit
import faBolusCore

/// §2.1(3) B1(b): the therapy-settings CHANGE LOG — a human-readable, shareable audit trail of every
/// recorded setting change (origin + before/after + when), newest first. Read-only DISCLOSURE; reached
/// from `PumpControlView` (already behind advanced-control + not-read-only), so a plain caregiver/viewer
/// phone never surfaces it. The shareable/copyable text is the deterministic `SettingChangeLog.exportText()`.
struct SettingChangeLogView: View {
    let model: AppModel

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
                    ForEach(Array(o.log.history().enumerated()), id: \.offset) { _, c in row(c) }
                } footer: {
                    Text("Every therapy-setting change is recorded with its origin and time. This log stays on this device.")
                }
                Section {
                    ShareLink(item: o.log.exportText()) { Label("Share log", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = o.log.exportText() } label: {
                        Label("Copy log", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationTitle("Change log")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func row(_ c: StoredSettingChange) -> some View {
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
