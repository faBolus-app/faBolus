import Testing
@testable import faBolus

/// Phase 09.6-06 (Task 1, Part C-1, D-03.1): behavior pins for the pure `DiagnosticsBundle`
/// aggregator — fabricated section strings are injected directly (mirrors every prior Part C
/// diagnostics-text test file's "inject plain values, no live state" precedent). `DiagnosticsBundle`
/// itself never touches `FileManager`/`WCSession`/`GarminRemoteBridge`/`GlucoseArbiter` — it only
/// concatenates already-formatted section strings supplied by the caller.
struct DiagnosticsBundleTests {
    /// (a) Stable-order concatenation: sections come back in the SAME order they were supplied, with
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

    /// (b) An absent/empty section renders its header + the explicit "not currently reachable"
    /// placeholder rather than vanishing (Pitfall 4) — the header is never simply omitted.
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

    /// (c) Purity: identical inputs always produce identical output — no I/O, no async, no hidden
    /// mutable state.
    @Test func buildIsPureAndIdempotentForIdenticalInputs() {
        let sections = ["[A]\nfirst", "[B]\nsecond"]
        let result1 = DiagnosticsBundle.build(sections: sections)
        let result2 = DiagnosticsBundle.build(sections: sections)
        #expect(result1 == result2)
    }
}
