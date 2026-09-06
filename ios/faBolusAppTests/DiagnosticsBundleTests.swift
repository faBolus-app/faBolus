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

    // MARK: - Command latency: canonical fast→slow order

    /// The latency section renders buckets in the canonical fast→slow order, never the alphabetical
    /// key-sort the other dictionary rows use — `lt250ms` must appear before `ge4s` and `timeout`
    /// even though an alphabetical sort would place both of those first.
    @Test func commandLatencySectionRendersBucketsInCanonicalOrderNotAlphabetical() {
        let block = DiagnosticsBundle.commandLatencySection(
            counts: ["ge4s": 1, "lt1s": 2, "lt250ms": 3, "lt2s": 4, "lt4s": 5, "lt500ms": 6, "timeout": 7])

        let lt250msIndex = block.range(of: "lt250ms")!.lowerBound
        let ge4sIndex = block.range(of: "ge4s")!.lowerBound
        let timeoutIndex = block.range(of: "timeout")!.lowerBound
        #expect(lt250msIndex < ge4sIndex)
        #expect(lt250msIndex < timeoutIndex)
        #expect(block.contains("lt250ms: 3"))
        #expect(block.contains("ge4s: 1"))
        #expect(block.contains("timeout: 7"))
    }

    /// A bucket absent from `counts` still renders, at 0 — the fixed order stays visible regardless
    /// of which buckets happen to have data.
    @Test func commandLatencySectionZeroRendersAbsentBuckets() {
        let block = DiagnosticsBundle.commandLatencySection(counts: ["lt250ms": 3])

        #expect(block.contains("lt250ms: 3"))
        #expect(block.contains("lt500ms: 0"))
        #expect(block.contains("timeout: 0"))
    }

    // MARK: - Notification telemetry

    /// The printed field is `requested`, never `delivered`/`presented`/`seen` — the rename this
    /// export section owes once `CategoryTelemetry.requested` lands.
    @Test func notificationTelemetrySectionPrintsRequestedNotDelivered() {
        let block = DiagnosticsBundle.notificationTelemetrySection(
            counts: [(category: "pumpDisconnect", requested: 5, dismissed: 1, actedUpon: 2)],
            windowStartFormatted: "Sep 1, 2026 at 3:04 PM")

        #expect(block.contains("pumpDisconnect: requested 5, dismissed 1, acted 2"))
        #expect(!block.lowercased().contains("delivered"), "the old field name must not appear anywhere in the export")
    }

    /// An already-formatted window-start string renders verbatim, exactly like
    /// `connectionTelemetrySection`'s own convention — never derived here, never backfilled.
    @Test func notificationTelemetrySectionRendersSuppliedWindowStart() {
        let block = DiagnosticsBundle.notificationTelemetrySection(
            counts: [], windowStartFormatted: "Sep 1, 2026 at 3:04 PM")

        #expect(block.contains("Window start: Sep 1, 2026 at 3:04 PM"))
    }

    /// The export always carries the lower-bound + not-retroactive caveat, even with zero counts —
    /// a future reader holding only the export must not read `dismissed` as an exact, complete count.
    @Test func notificationTelemetrySectionAlwaysCarriesTheLowerBoundAndNotRetroactiveCaveat() {
        let block = DiagnosticsBundle.notificationTelemetrySection(
            counts: [(category: "pumpAlert", requested: 1, dismissed: 0, actedUpon: 0)],
            windowStartFormatted: "unknown — accrued across an unknown set of builds")

        #expect(block.lowercased().contains("lower bound"))
        #expect(block.lowercased().contains("not retroactive") || block.lowercased().contains("never reported"))
    }

    /// Non-vacuity for the empty case: the header + window start + caveat still render with no counts at
    /// all, exactly like the connection-telemetry section's own empty-state row.
    @Test func notificationTelemetrySectionRendersPlaceholderAndCaveatWhenCountsIsEmpty() {
        let block = DiagnosticsBundle.notificationTelemetrySection(
            counts: [], windowStartFormatted: "unknown — accrued across an unknown set of builds")

        #expect(block.contains("[Notification telemetry]"))
        #expect(block.contains("—"))
        #expect(block.lowercased().contains("lower bound"))
    }
}
