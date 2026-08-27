import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 16 GO-1 Step 1 (the phase tracer, REMED-16/CX-A-01/CX-A-05) — the deterministic-equivalence
/// gate for the `RemoteStatusComposer` extraction from `AppModel.statusCommand`.
///
/// **Why not a raw-byte fixture (review concern #3).** `RemoteCommand.encoded()` uses a default
/// `JSONEncoder` (unstable key order) and the pre-move body read the wall clock (`Date()`) for
/// `glucoseAgeSec`, so a checked-in byte blob would be non-reproducible on its own terms, never mind
/// across a refactor. `AppModel.statusCommand` now takes an injectable `now` (default `Date()`, so
/// every production call site is unchanged) — with `now` fixed, every test below asserts:
///  1. **Determinism**: two composes of the identical inputs at the identical fixed instant produce
///     `Equatable`-equal `RemoteCommand`s AND byte-identical canonical (`.sortedKeys`) JSON — proving no
///     live singleton/clock read survived the move (a stray live read would make the SECOND call answer
///     differently the moment real state/time moved on, which `@Suite(.serialized)` plus these paired
///     calls would catch).
///  2. **Correctness**: each scenario's key fields are asserted against literal expected values traced
///     by hand from the pre-move body (transcribed verbatim into `RemoteStatusComposer.compose`), so
///     this is a genuine characterization/golden proof, not just an internal-consistency check.
///  3. **Wire validity**: `RemoteCommand.decodeValidated(try cmd.encoded())` round-trips without
///     throwing and decodes back to the identical command.
///
/// Three fixed scenarios per the plan: (a) linked + fresh glucose, (b) disconnected, (c) stale with
/// active alerts. `RemoteCommand` is already `Equatable` (declared on the type — no change needed).
///
/// Existing suites that already exercise `statusCommand` through real scenarios — `BolusGateHostFeedTests`
/// (`canBolus`/`bolusBlockReason`/`maxBolusUnits`), `CartridgeReadinessRemotePresentationTests`
/// (`cartridgeReady`) — continue to pass UNCHANGED after the move; they are the other half of the
/// equivalence proof (production call sites, not synthesized here).
@Suite(.serialized) @MainActor
struct RemoteStatusComposerEquivalenceTests {

    // MARK: - Fixtures (mirrors BolusGateHostFeedTests.makeModel / withClean verbatim)

    private func makeModel() -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rsc-\(UUID().uuidString).json")
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }

    /// Clean gate state so a sibling test can't leave child/read-only set; advanced-control on (matches
    /// `BolusGateHostFeedTests.withClean` exactly — same funnel, same need for a clean baseline).
    private func withClean(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let child = s.childModeEnabled, ro = s.phoneReadOnly, adv = s.advancedControlEnabled, rro = s.remotesReadOnly
        s.childModeEnabled = false; s.phoneReadOnly = false; s.advancedControlEnabled = true; s.remotesReadOnly = false
        defer { s.childModeEnabled = child; s.phoneReadOnly = ro; s.advancedControlEnabled = adv; s.remotesReadOnly = rro }
        try await body()
    }

    /// Canonical (`.sortedKeys`) JSON string for a command — the wire-shape stability check (review
    /// concern #3's "canonical sorted-key wire check", NOT a raw-byte comparison).
    private func canonicalJSON(_ cmd: RemoteCommand) throws -> String {
        let data = try cmd.encoded()
        let obj = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: canonical, as: UTF8.self)
    }

    // MARK: - Scenario (a): linked + fresh glucose

    @Test func linkedFreshGlucoseIsDeterministicAndCorrect() async throws {
        try await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            let sampleDate = try #require(backend.snapshot.glucoseDate)
            let fixedNow = sampleDate.addingTimeInterval(30)   // 30s after the sample: unambiguously fresh
            // A fixed `replyingTo` id is required for the a==b determinism check below: with no
            // `replyingTo`, `RemoteCommand`'s own default initializer mints a FRESH random UUID per
            // call (by design — an unsolicited push has no request to echo), which is a genuine,
            // pre-existing (pre-move) source of per-call difference unrelated to the composer's purity.
            let requestId = "fixture-linked-fresh"

            let a = model.statusCommand(includeHistory: true, replyingTo: requestId, now: fixedNow)
            let b = model.statusCommand(includeHistory: true, replyingTo: requestId, now: fixedNow)
            #expect(a == b, "compose must be deterministic under a fixed clock (no live singleton/clock read)")
            #expect(try canonicalJSON(a) == canonicalJSON(b))

            #expect(a.glucoseAgeSec == 30)
            #expect(a.glucoseEpochSec == Int(sampleDate.timeIntervalSince1970))
            #expect(a.canBolus == true)
            #expect(a.bolusBlockReason == nil)
            #expect(a.maxBolusUnits == backend.snapshot.maxBolusUnits)   // no remote ceiling set ⇒ passthrough
            #expect(a.trend == GlucoseTrend.flat.token)                 // MockBackend seeds .flat
            #expect(a.remotesReadOnly == false)
            #expect(a.history?.isEmpty == false)
            #expect(a.historyEpochs?.count == a.history?.count)
            // MockBackend never confirms an op-20 read (cartridgeLoadStateConfirmed stays false), so
            // readiness is `.unknown` ⇒ the wire field is nil (NO SIGNAL), never a fabricated `true`.
            #expect(a.cartridgeReady == nil)

            let decoded = try RemoteCommand.decodeValidated(try a.encoded())
            #expect(decoded == a)
        }
    }

    // MARK: - Scenario (b): disconnected

    @Test func disconnectedIsDeterministicAndCorrect() async throws {
        try await withClean {
            let (model, backend) = makeModel()   // never connected — stays .disconnected
            let sampleDate = try #require(backend.snapshot.glucoseDate)
            let fixedNow = sampleDate.addingTimeInterval(30)
            let requestId = "fixture-disconnected"

            let a = model.statusCommand(includeHistory: false, replyingTo: requestId, now: fixedNow)
            let b = model.statusCommand(includeHistory: false, replyingTo: requestId, now: fixedNow)
            #expect(a == b)

            #expect(a.canBolus == false)
            #expect(a.bolusBlockReason == "pumpNotLinked")
            #expect(a.message == "Disconnected")
            #expect(a.history == nil)
            #expect(a.historyEpochs == nil)

            let decoded = try RemoteCommand.decodeValidated(try a.encoded())
            #expect(decoded == a)
        }
    }

    // MARK: - Scenario (c): stale, with active alerts

    @Test func staleWithActiveAlertsIsDeterministicAndCorrect() async throws {
        try await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            #expect(!backend.activeNotifications.isEmpty, "MockBackend must seed at least one alert for this scenario")
            let sampleDate = try #require(backend.snapshot.glucoseDate)
            let fixedNow = sampleDate.addingTimeInterval(3600)   // 1h later: unambiguously stale
            let requestId = "fixture-stale-with-alerts"

            let a = model.statusCommand(includeHistory: true, replyingTo: requestId, now: fixedNow)
            let b = model.statusCommand(includeHistory: true, replyingTo: requestId, now: fixedNow)
            #expect(a == b)
            #expect(try canonicalJSON(a) == canonicalJSON(b))

            #expect(a.glucoseAgeSec == 3600)
            #expect(a.alerts?.isEmpty == false)
            #expect(a.alerts?.first?.title == backend.activeNotifications.first?.title)
            #expect(a.alerts?.first?.kind == backend.activeNotifications.first?.kind.rawValue)
            // canBolus stays governed by link/in-flight/cartridge/access — staleness never gates it
            // (group-A/D contract, `BolusGate`'s own doc comment) — pinned here too.
            #expect(a.canBolus == true)

            let decoded = try RemoteCommand.decodeValidated(try a.encoded())
            #expect(decoded == a)
        }
    }

    // MARK: - Requestid echo + canonical wire stability across a repeated compose

    @Test func requestIdEchoesAndCanonicalWireIsStableAcrossRepeatedComposes() async throws {
        try await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            let sampleDate = try #require(backend.snapshot.glucoseDate)
            let fixedNow = sampleDate.addingTimeInterval(45)
            let requestId = "fixed-request-id-for-canonical-check"

            let a = model.statusCommand(includeHistory: true, replyingTo: requestId, now: fixedNow)
            let b = model.statusCommand(includeHistory: true, replyingTo: requestId, now: fixedNow)
            #expect(a.requestId == requestId)
            #expect(try canonicalJSON(a) == canonicalJSON(b))
        }
    }

    // MARK: - Composer purity scan (INV-C: no live singleton/clock read reached RemoteStatusComposer)

    /// Forbidden tokens: any of these appearing in `RemoteStatusComposer.swift`'s CODE (doc/line
    /// comments stripped first — the file's own header prose legitimately discusses `AppModel`/
    /// `AppSettings.shared` in EXPLANATION of what the thin adapter does elsewhere, so scanning raw
    /// text would false-positive on the documentation itself) would mean a live singleton, the wall
    /// clock, or an `AppModel`/`source` handle leaked past the thin-adapter boundary — the exact
    /// regression this scan exists to catch (a MISSED input in `RemoteStatusInputs`/
    /// `RemoteStatusSettings` should fail the build/test, not tempt a live read).
    private static let forbiddenLiveReadTokens: [String] = [
        "AppSettings.shared", "BolusPasscodeStore", "Date()", "self.snapshot", "AppModel",
    ]

    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("ios/faBolus/Data")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func readComposerSource() throws -> String {
        let root = try #require(Self.repoRootURL())
        return try String(contentsOf: root.appendingPathComponent("ios/faBolus/Data/Remote/RemoteStatusComposer.swift"),
                          encoding: .utf8)
    }

    /// Strips everything from the first `//` on each line onward (line/doc comments) so the forbidden-
    /// token scan sees only executable code — the file's OWN doc comments legitimately name every
    /// forbidden token in prose (explaining what the thin adapter does elsewhere), which would
    /// otherwise make this scan false-positive on itself. No string literal in this file contains
    /// `//`, so this simple per-line split is exact here (not a general-purpose Swift comment parser).
    private static func codeOnly(_ source: String) -> String {
        source.components(separatedBy: "\n").map { line -> String in
            guard let range = line.range(of: "//") else { return line }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
    }

    @Test func composerFileContainsNoLiveSingletonOrClockRead() throws {
        let code = Self.codeOnly(try Self.readComposerSource())
        for token in Self.forbiddenLiveReadTokens {
            #expect(!code.contains(token),
                    "RemoteStatusComposer.swift's CODE contains a forbidden live-read token: '\(token)' (INV-C)")
        }
    }

    /// Fault-injection proof (mirrors `CiqAwarenessScopeGuardTests`' idiom): a poisoned COPY of the real
    /// source's CODE, never written to disk, with a forbidden token appended as a bare code line (no
    /// comment marker), must be caught by the SAME matcher the real scan uses — proving the scan is not
    /// a vacuous always-pass.
    @Test func purityScanCatchesAnInjectedLiveRead() throws {
        let code = Self.codeOnly(try Self.readComposerSource())
        for poison in ["AppSettings.shared.remotesReadOnly", "BolusPasscodeStore.isRequired", "Date()"] {
            let poisoned = code + "\nlet _ = \(poison)\n"
            #expect(Self.forbiddenLiveReadTokens.contains { poisoned.contains($0) },
                    "the purity scan failed to catch an injected live-read reference to '\(poison)'")
        }
    }

    // MARK: - WR-02 hardening: enforce the assumption `codeOnly` silently relies on

    /// `codeOnly` strips from the FIRST `//` on each line. That is exact ONLY while no string literal on
    /// a line contains `//` before real code — the file's own doc comment concedes this as an UNENFORCED
    /// assumption. A future edit introducing e.g. `"http://…"` before real code on a line would make
    /// `codeOnly` over-strip that code and silently shrink what the purity scan sees. Returns true iff a
    /// `//` occurs INSIDE a string literal (a per-line quote-state scan; there is no multiline `"""`
    /// string in this file, so per-line state is exact).
    private static func hasSlashSlashInsideStringLiteral(_ source: String) -> Bool {
        for line in source.components(separatedBy: "\n") {
            var inString = false
            var escaped = false
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                if inString {
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { inString = false }
                    else if ch == "/" && i + 1 < chars.count && chars[i + 1] == "/" { return true }
                } else {
                    if ch == "\"" { inString = true }
                    else if ch == "/" && i + 1 < chars.count && chars[i + 1] == "/" { break } // real code comment
                }
                i += 1
            }
        }
        return false
    }

    /// The assumption, made loud: if this ever fails, `codeOnly` is no longer exact — rework the string
    /// literal or make `codeOnly` a real comment-aware parser. Do NOT relax the purity scan.
    @Test func codeOnlyStripperAssumptionHolds() throws {
        #expect(!Self.hasSlashSlashInsideStringLiteral(try Self.readComposerSource()),
                "RemoteStatusComposer.swift now has a `//` inside a string literal — codeOnly's strip-from-first-`//` will over-strip real code and silently weaken the INV-C purity scan.")
    }

    /// Fault-injection: the assumption checker must FLAG a `//` inside a string literal and PASS a `//`
    /// that is a genuine trailing comment.
    @Test func slashSlashInStringCheckerIsNotVacuous() {
        #expect(Self.hasSlashSlashInsideStringLiteral("let s = \"http://x\""))
        #expect(!Self.hasSlashSlashInsideStringLiteral("let s = \"plain\" // trailing comment"))
    }
}
