import Testing
import faBolusCore
@testable import faBolus

/// Behavior pins for the pure `DiagnosticsBundle` aggregator — fabricated section strings are injected
/// directly (mirrors the other diagnostics-text test files' "inject plain values, no live state"
/// precedent). `DiagnosticsBundle` itself never touches
/// `FileManager`/`WCSession`/`GarminRemoteBridge`/`GlucoseArbiter` — it only concatenates
/// already-formatted section strings supplied by the caller.
struct DiagnosticsBundleTests {
    /// Stable-order concatenation: sections come back in the SAME order they were supplied, with
    /// nothing dropped, added, or reordered.
    @Test func buildConcatenatesSectionsInSuppliedOrderStably() {
        let sections = ["[A]\nfirst", "[B]\nsecond", "[C]\nthird"]
        let result = DiagnosticsBundle.build(sections: sections)

        let indexA = result.range(of: "[A]")!.lowerBound
        let indexB = result.range(of: "[B]")!.lowerBound
        let indexC = result.range(of: "[C]")!.lowerBound
        #expect(indexA < indexB)
        #expect(indexB < indexC)
        #expect(result.contains("first"))
        #expect(result.contains("second"))
        #expect(result.contains("third"))
    }

    /// An absent/empty section renders its header + the explicit "not currently reachable" placeholder
    /// rather than vanishing — the header is never simply omitted.
    @Test func sectionOrPlaceholderRendersHeaderAndPlaceholderWhenSectionIsNil() {
        let block = DiagnosticsBundle.sectionOrPlaceholder(label: "Some Surface", section: nil)

        #expect(block.contains("[Some Surface]"))
        #expect(block.contains("— (not currently reachable)"))
    }

    @Test func sectionOrPlaceholderRendersHeaderAndPlaceholderWhenSectionIsEmptyString() {
        let block = DiagnosticsBundle.sectionOrPlaceholder(label: "Some Surface", section: "")

        #expect(block.contains("[Some Surface]"))
        #expect(block.contains("— (not currently reachable)"))
    }

    /// When a section string IS supplied, `sectionOrPlaceholder` passes it through verbatim — never
    /// reformats or re-derives it (the aggregator stays pure).
    @Test func sectionOrPlaceholderPassesThroughSuppliedSectionVerbatim() {
        let supplied = "\n[Some Surface]\nReachable: yes\nSent: 4"
        let block = DiagnosticsBundle.sectionOrPlaceholder(label: "Some Surface", section: supplied)

        #expect(block == supplied)
    }

    /// Purity: identical inputs always produce identical output — no I/O, no async, no hidden
    /// mutable state.
    @Test func buildIsPureAndIdempotentForIdenticalInputs() {
        let sections = ["[A]\nfirst", "[B]\nsecond"]
        let result1 = DiagnosticsBundle.build(sections: sections)
        let result2 = DiagnosticsBundle.build(sections: sections)
        #expect(result1 == result2)
    }

    /// `buildProvenanceSection` wraps an already-rendered literal stamp in a `[Build]` section
    /// verbatim — it never re-derives the dirty marker or the hash itself.
    @Test func buildProvenanceSectionRendersSuppliedStampInsideBuildSection() {
        let block = DiagnosticsBundle.buildProvenanceSection(buildStamp: "abc1234+")

        #expect(block.contains("[Build]"))
        #expect(block.contains("Commit: abc1234+"))
    }

    // MARK: - Connection telemetry: accrual window

    /// An already-formatted window-start string is rendered verbatim — the helper never derives it.
    @Test func connectionTelemetrySectionRendersSuppliedWindowStart() {
        let block = DiagnosticsBundle.connectionTelemetrySection(
            connectCount: 5, totalUptimeFormatted: "3h 12m", disconnects: [], reconcile: [],
            windowStartFormatted: "Sep 1, 2026 at 3:04 PM")

        #expect(block.contains("Window start: Sep 1, 2026 at 3:04 PM"))
    }

    /// The absent-window-start marker is rendered exactly as supplied — never substituted for a
    /// backfilled date.
    @Test func connectionTelemetrySectionRendersAbsentWindowStartMarkerVerbatim() {
        let block = DiagnosticsBundle.connectionTelemetrySection(
            connectCount: 0, totalUptimeFormatted: "—", disconnects: [], reconcile: [],
            windowStartFormatted: "unknown — accrued across an unknown set of builds")

        #expect(block.contains("Window start: unknown — accrued across an unknown set of builds"))
    }

    // MARK: - Connection telemetry: the non-complementarity limitation line

    /// The export section always carries the explicit "no ratio is meaningful" prose — a future
    /// reader holding only the export must not conclude Connects and Total uptime divide into a rate.
    @Test func connectionTelemetrySectionCarriesTheNoRatioLimitationLine() {
        let block = DiagnosticsBundle.connectionTelemetrySection(
            connectCount: 190, totalUptimeFormatted: "14m 54s", disconnects: [], reconcile: [],
            windowStartFormatted: "unknown — accrued across an unknown set of builds")

        #expect(block.lowercased().contains("no ratio") || block.lowercased().contains("not a rate"))
    }

}
