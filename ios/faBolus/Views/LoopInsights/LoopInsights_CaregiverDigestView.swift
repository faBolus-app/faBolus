// Adapted from LoopPowerPack/Loop @ ad4c4d4 (MIT)
import SwiftUI
import faBolusCore
import faBolusDesign
import HistoryStore

/// 09.18d-03 (D-14/D-15/D-17) — the caregiver digest surface: a shareable, summary-only glucose +
/// activity snapshot the user can hand to a caregiver. This is the highest-PHI/§13-risk of the four
/// benign LoopInsights surfaces, so it carries the verbatim UI-SPEC PHI disclosure BEFORE any share
/// affordance and is reachable only when the default-OFF Smart Assist toggle is ON.
///
/// A **rewrite** of the mirror's `LoopInsights_CaregiverDigestView` (D-15): fed solely by the faBolus
/// `FaBolusInsightsAggregator` over `GlucoseHistoryStore` (no LoopKit stores, no `DataAggregator`) and
/// the benign `LoopInsights_CaregiverDigestService` (Task 1). ALL the mirror's LoopKit coordinator +
/// MessageUI mail/SMS compose + reminder scheduling + recipient configuration is stripped — the digest
/// is shared via the standard iOS share sheet (the faBolus `ShareLink` idiom, matching
/// `SettingChangeLogView`). Every line is a §13-compliant records summary — never advice or a dose.
struct LoopInsights_CaregiverDigestView: View {
    /// Optional to mirror `LoopInsights_EndoReportView` / `SiteAtlasRootView` — a nil shared store
    /// (failed to open at app init) degrades to the insufficient-history empty state, never a crash.
    let historyStore: GlucoseHistoryStore?
    /// The app's glucose display unit (`AppSettings.glucoseDisplayUnit`).
    var glucoseUnit: GlucoseUnit

    @State private var period: LoopInsightsReportPeriod = .sevenDays

    private var unitContext: InsightsGlucoseUnitContext { InsightsGlucoseUnitContext(unit: glucoseUnit) }

    private var report: FaBolusInsightsReport? {
        guard let historyStore else { return nil }
        return FaBolusInsightsAggregator(store: historyStore).report(period: .days(period.days))
    }

    private var digest: LoopInsights_CaregiverDigestService.Digest? {
        guard let report else { return nil }
        return LoopInsights_CaregiverDigestService.generateDigest(from: report, unit: unitContext)
    }

    var body: some View {
        Form {
            Section {
                Picker("Summary period", selection: $period) {
                    ForEach(LoopInsightsReportPeriod.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
            } footer: {
                Text("A summary of glucose and activity already recorded for this period.")
            }

            // PHI disclosure — shown BEFORE any share affordance (verbatim UI-SPEC copy, T-09.18d-10).
            Section {
                Label {
                    Text("This summary shares glucose and activity data. Anything you send goes to whoever you share it with. It's a summary of what's already happened — not advice or a dose.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(AppTheme.insulin)
                }
            } header: {
                Text("Before you share")
            }

            if let report, report.hasSufficientHistory, let digest {
                Section("Preview") {
                    Text(digest.text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section {
                    ShareLink(item: digest.text) {
                        Label("Share digest", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("**Off by default.** Advisory only — never blocks, changes, or suggests a dose. Shares via the standard share sheet.")
                }
            } else {
                Section {
                    Text("Not enough history yet to build a digest. Come back after a few days of readings.")
                        .foregroundStyle(.secondary)
                    Label("Share digest", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Caregiver digest")
        .navigationBarTitleDisplayMode(.inline)
    }
}
