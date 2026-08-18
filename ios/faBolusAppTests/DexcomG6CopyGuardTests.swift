import Testing
import Foundation
@testable import faBolus

/// Phase 09.20-04 (D-03/D-05/D-14): pins the honest "Read from Dexcom app" copy for the G6/G5/ONE
/// direct-BLE source and guards against regressing back to the RETRACTED best-effort/hedging framing
/// (RESEARCH's "D-05 reliability re-check" + "Already-paired-sensor first-run behavior" found no
/// evidence for "often unreliable"/"may never connect"/"refused outright"/"best-effort" — that framing
/// was walked back, not confirmed). Source-scan technique mirrors `WatchDirectBleScopeGuardTests` /
/// `DexcomG6ScopeGuardTests`: `#filePath`-rooted repo-root walk + `String(contentsOf:)`, no BLE, no
/// simulator, no live sensor — this is a pure text-content guard.
struct DexcomG6CopyGuardTests {

    /// Resolve `<root>` by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/DexcomG6CopyGuardTests.swift`) until `Shared` exists — same
    /// technique as `DexcomG6ScopeGuardTests.repoRootURL()` / `WatchDirectBleScopeGuardTests.repoRootURL()`.
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("Shared")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func readSource(_ relativePath: String) -> String? {
        guard let root = repoRootURL() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static let sources = [
        "ios/faBolus/Data/GlucoseSourceRegistry.swift",
        "ios/faBolus/Views/CgmCredentialsView.swift",
        // Gap-closure (09.20-VERIFICATION.md): the point-of-selection blocking alert (FB-07) and the
        // BLE source's own doc-comment header also carry user/maintainer-facing G6 copy and must be
        // held to the same retraction as the two files above — a 2-file scope was exactly why this
        // guard stayed green while the retracted framing still lived in these two files.
        "ios/faBolus/Views/SettingsView.swift",
        "ios/faBolus/Data/Sources/DexcomG6BLESource.swift",
    ]

    /// Vacuous-pass guard: fail loudly if either source file cannot be resolved from `#filePath`,
    /// rather than silently passing every other `#expect` below because `combinedCorpus` is empty.
    @Test func sourceFilesResolveFromFilePath() throws {
        for path in Self.sources {
            #expect(Self.readSource(path) != nil,
                    "path resolution broke: could not read \(path) from #filePath=\(#filePath)")
        }
    }

    private static func combinedCorpus() -> String {
        Self.sources.compactMap(Self.readSource).joined(separator: "\n")
    }

    // MARK: (a) retracted hedging phrases are ABSENT

    @Test func retractedHedgingPhrasesAreAbsent() throws {
        let corpus = Self.combinedCorpus().lowercased()
        #expect(!corpus.isEmpty, "corpus is empty — path resolution likely broke")
        for hedge in [
            "often unreliable", "may never connect", "refused outright", "best-effort", "best effort",
            "likely will not connect", "needs an authenticated session", "often receives nothing",
            "unverified best guess",
        ] {
            #expect(!corpus.contains(hedge),
                    "retracted hedging phrase \"\(hedge)\" must not appear — D-03/D-05 walked this back (see 09.20-RESEARCH.md)")
        }
    }

    // MARK: (b) app-running precondition phrase is PRESENT

    @Test func appRunningPreconditionIsPresent() throws {
        let corpus = Self.combinedCorpus()
        #expect(corpus.contains("official Dexcom app installed, paired, and running"),
                "the hard precondition (Dexcom app installed/paired/running) must be stated")
    }

    // MARK: (c) "Read from Dexcom app" mode label is PRESENT

    @Test func readFromDexcomAppLabelIsPresent() throws {
        let corpus = Self.combinedCorpus()
        #expect(corpus.contains("Read from Dexcom app"),
                "the D-03 default mode label \"Read from Dexcom app\" must be present")
    }

    // MARK: (d) ~5-minute / wake-cycle first-reading guidance is PRESENT

    @Test func fiveMinuteWakeCycleGuidanceIsPresent() throws {
        let corpus = Self.combinedCorpus()
        #expect(corpus.contains("~5 minutes"),
                "the ~5-minute first-reading timing note must be present")
        #expect(corpus.contains("Dexcom wake cycle"),
                "the timing note must name the Dexcom wake cycle so it doesn't read as a failure")
    }

    // MARK: (e) toggle-Bluetooth-in-the-Dexcom-app remedy is PRESENT

    @Test func toggleBluetoothRemedyIsPresent() throws {
        let corpus = Self.combinedCorpus()
        #expect(corpus.contains("toggle Bluetooth off then on"), "the toggle-BT remedy must be present")
        #expect(corpus.contains("inside the official Dexcom app"),
                "the remedy must specify toggling Bluetooth INSIDE the official Dexcom app, not iOS Settings")
    }

    // MARK: (f) experimental / untested validation-pending marker is still PRESENT (D-14)

    @Test func experimentalValidationPendingMarkerIsPresent() throws {
        let corpus = Self.combinedCorpus().lowercased()
        #expect(corpus.contains("experimental"),
                "the experimental / validation-pending marker (D-14) must stay present — nothing here is on-device-verified yet")
    }

    // MARK: bonus — already-paired / no re-pairing / no transmitter-ID guidance (must_haves truth #2)

    @Test func alreadyPairedNoRePairingGuidanceIsPresent() throws {
        let corpus = Self.combinedCorpus()
        #expect(corpus.contains("no re-pairing"),
                "an already-set-up sensor must be documented as needing no re-pairing")
        #expect(corpus.contains("no transmitter ID"),
                "an already-set-up single sensor must be documented as needing no transmitter ID")
    }
}
