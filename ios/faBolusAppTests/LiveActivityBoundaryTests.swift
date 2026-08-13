import Testing
import Foundation
@testable import faBolus

/// The Phase 7 boundary invariant (D-18, 05-05): **"an ambient surface never reaches a signed
/// delivery command."** `Shared/LiveActivityIntents.swift` is the file every Live Activity button's
/// `LiveActivityIntent` lives in; this suite source-scans it (comment-stripped) for the signed-
/// delivery seam symbols and fails the build the moment one is ever added — mirroring
/// `SettingsCatalogTests`' `SettingsCatalog.commandAdjacentFlags` greppable-invariant idiom (a
/// machine-checked list, not prose) and `RescueCarbGuardTests`' `#filePath`-rooted path resolution
/// (`Packages/faBolusCore/Tests/faBolusCoreTests/RescueCarbGuardTests.swift`).
///
/// Plus two behavioral cases: the open-to-bolus intent carries no dose/carb payload (it has zero
/// `@Parameter`s — there is nothing it COULD carry), and the reconnect/snooze intents call through
/// `LiveActivityIntentBridge` — and ONLY through it — never touching any delivery state directly.
struct LiveActivityBoundaryTests {

    /// The signed-delivery seam identifiers barred from the LA intents file: the deliver-widget-bolus
    /// method (`AppModel.deliverWidgetBolus`), the bolus-gate evaluator (`BolusGate`, faBolusCore),
    /// the widget-bolus store type (`WidgetBolusStore`) + its set-pending writer (`setPending`), and
    /// the Darwin pending post (`darwinPending`). (`BolusGate`/`WidgetBolusStore` also catch any
    /// narrower reference like `.evaluate`/`.takePending`, since the type name itself is banned.)
    static let forbiddenDeliverySymbols: Set<String> = [
        "deliverWidgetBolus", "BolusGate", "WidgetBolusStore", "setPending", "darwinPending",
    ]

    /// Resolve `Shared/LiveActivityIntents.swift` from `#filePath`
    /// (`<root>/ios/faBolusAppTests/LiveActivityBoundaryTests.swift`), walking up to the repo root —
    /// same technique as `RescueCarbGuardTests.scanRoots()`.
    private static func intentsFileURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("Shared/LiveActivityIntents.swift")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// Strip `//`-style line comments. Sufficient for this one small file (no multiline `/* */`
    /// comments in it) — necessary because the file's OWN doc comments legitimately name the
    /// forbidden symbols in prose (explaining what must never appear in CODE), so an unstripped scan
    /// would false-positive on itself.
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let idx = line.range(of: "//") { return String(line[..<idx.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    // MARK: - Source scan (the build-enforced invariant)

    @Test func sourceScanContainsNoDeliverySeamSymbols() throws {
        guard let url = Self.intentsFileURL() else {
            Issue.record("could not resolve Shared/LiveActivityIntents.swift from #filePath=\(#filePath)")
            return
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let stripped = Self.stripLineComments(raw)
        let violations = Self.forbiddenDeliverySymbols.filter { stripped.contains($0) }
        #expect(violations.isEmpty,
                "Phase 7 boundary violated — LiveActivityIntents.swift references delivery-seam symbol(s): \(violations.sorted().joined(separator: ", "))")
    }

    /// A path-resolution bug must fail loudly, not pass vacuously (mirrors `RescueCarbGuardTests`'
    /// own `scanned > 0` guard).
    @Test func fileResolutionActuallyFoundTheIntentsFile() {
        #expect(Self.intentsFileURL() != nil,
                "boundary test could not locate Shared/LiveActivityIntents.swift — path resolution broke (#filePath=\(#filePath))")
    }

    // MARK: - Behavioral: open-to-bolus carries no dose/carb

    @Test func openBolusIntentSetsOnlyTheNavRequestAndCreatesNoPendingBolus() async throws {
        _ = WidgetStore.takeOpenBolusRequest()        // drain any residual flag first
        _ = WidgetBolusStore.takePending()            // ditto for the (unrelated) bolus-request slot

        _ = try await LAOpenBolusIntent().perform()

        // The ONLY effect: the bare-nav flag is now set.
        #expect(WidgetStore.takeOpenBolusRequest() == true, "open-to-bolus must set the nav request")
        // No dose/carb payload exists to leak — `LAOpenBolusIntent` declares zero `@Parameter`
        // properties, so nothing it does could carry one; confirmed here by checking the ONE place a
        // dose would have to land if it somehow did (the widget-bolus pending slot), which must stay empty.
        #expect(WidgetBolusStore.takePending() == nil, "open-to-bolus must never create a pending widget bolus")
    }

    // MARK: - Behavioral: reconnect/snooze route ONLY through the bridge, touch no delivery state

    @Test @MainActor func reconnectIntentCallsOnlyTheBridgeHook() async throws {
        defer { LiveActivityIntentBridge.reconnect = nil }
        var calls = 0
        LiveActivityIntentBridge.reconnect = { calls += 1 }

        _ = WidgetBolusStore.takePending()
        _ = try await LAReconnectIntent().perform()

        #expect(calls == 1, "reconnect must call through the bridge exactly once")
        #expect(WidgetBolusStore.takePending() == nil, "reconnect must never touch the widget-bolus pending slot")
    }

    @Test @MainActor func snoozeIntentCallsOnlyTheBridgeHook() async throws {
        defer { LiveActivityIntentBridge.snoozeAlertIfSafe = nil }
        var calls = 0
        LiveActivityIntentBridge.snoozeAlertIfSafe = { calls += 1 }

        _ = WidgetBolusStore.takePending()
        _ = try await LASnoozeAlertIntent().perform()

        #expect(calls == 1, "snooze must call through the bridge exactly once")
        #expect(WidgetBolusStore.takePending() == nil, "snooze must never touch the widget-bolus pending slot")
    }

    /// With the bridge left unset (as it is by default in this test process — `App.swift`'s
    /// `onAppear` never runs here), both intents are safe no-ops: no crash, and no delivery-adjacent
    /// state changes.
    @Test @MainActor func reconnectAndSnoozeAreSafeNoOpsWhenBridgeIsUnset() async throws {
        LiveActivityIntentBridge.reconnect = nil
        LiveActivityIntentBridge.snoozeAlertIfSafe = nil
        _ = WidgetBolusStore.takePending()

        _ = try await LAReconnectIntent().perform()
        _ = try await LASnoozeAlertIntent().perform()

        #expect(WidgetBolusStore.takePending() == nil)
    }
}
