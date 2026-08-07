import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P15 Addendum B (AB3) — the shared `RemoteClientModel` seams the Apple Watch, Mac, and remote-iPhone
/// all use to offer the stale-CGM three-way choice, plus the divergence-guard consistency that the
/// include-stale path depends on.
///
/// The three-way DECISION itself (which bg feeds the calculation, whether a path sends anything) is
/// pinned in faBolusCore `StaleBolusPromptTests`. Here we pin the CLIENT behavior:
///   • `staleCarbWarnNeeded` — warn iff a stale-but-real reading exists (fresh / no-reading bypass),
///   • `deliverCarbs(_:includeStaleBG:)` — the stale value is sent for the correction ONLY on the
///     explicit per-attempt include, else dropped (today's carbs-only behavior), and
///   • the `remoteEstimateUnits` on the wire is computed from the SAME bg the host will recompute with,
///     so the host's 0.10 U divergence guard doesn't reject an included-stale dose (the critical bug the
///     AB3 plan calls out).
/// The watch UI has no unit-test seam; it routes through these model methods, so pinning them here guards
/// the watch's (and Mac's) Addendum B wiring.
@MainActor
@Suite(.serialized) struct StaleCarbClientTests {

    /// A link that captures every command sent, so a composed bolus can be inspected on the wire.
    private final class CapturingLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        var sent: [RemoteCommand] = []
        func send(_ command: RemoteCommand) { sent.append(command) }
    }

    /// Build a model with calculator settings and a reading whose source age is `ageMinutes` old.
    /// carbRatio 10 g/U, ISF 50 mg/dL/U, target 100 mg/dL, IOB 0 ⇒ a correction is added iff the reading
    /// is above target and used.
    private func model(bg: Int?, ageMinutes: Double) -> (RemoteClientModel, CapturingLink) {
        let link = CapturingLink()
        let m = RemoteClientModel(link: link)
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.carbRatio = 10; cmd.isf = 50; cmd.targetBg = 100
        if let bg { cmd.bgMgdl = Double(bg) }
        cmd.glucoseEpochSec = Int(Date().timeIntervalSince1970 - ageMinutes * 60)
        m.handle(cmd)
        link.sent.removeAll()          // drop nothing was sent on handle, but be explicit
        return (m, link)
    }

    // MARK: staleCarbWarnNeeded

    @Test func warnsOnlyWhenStaleReadingPresent() {
        // Stale reading present → warn.
        let (stale, _) = model(bg: 200, ageMinutes: 60)
        #expect(stale.isGlucoseStale)
        #expect(stale.staleCarbWarnNeeded)

        // Fresh reading → no warning (composes normally).
        let (fresh, _) = model(bg: 200, ageMinutes: 0.5)
        #expect(!fresh.isGlucoseStale)
        #expect(!fresh.staleCarbWarnNeeded)

        // No reading at all → nothing to include; carbs-only, no three-way.
        let (none, _) = model(bg: nil, ageMinutes: 60)
        #expect(none.glucose == nil)
        #expect(!none.staleCarbWarnNeeded)
    }

    // MARK: deliverCarbs(includeStaleBG:) — the stale value is sent only on the explicit include

    @Test func includeStaleSendsTheStaleValueAndMatchingEstimate() {
        let (m, link) = model(bg: 200, ageMinutes: 60)
        m.deliverCarbs(30, includeStaleBG: true)
        let cmd = link.sent.last
        #expect(cmd?.kind == .bolusRequest)
        #expect(cmd?.carbsGrams == 30)
        #expect(cmd?.bgMgdl == 200)        // the stale value IS used for the correction here
        // Divergence-guard consistency: the estimate on the wire equals the estimate computed with the
        // SAME (stale) bg the host will recompute with.
        #expect(cmd?.remoteEstimateUnits == m.estimatedUnits(forCarbs: 30, includeStaleBG: true))
    }

    @Test func carbsOnlyDropsTheStaleValue() {
        let (m, link) = model(bg: 200, ageMinutes: 60)
        m.deliverCarbs(30)                 // default includeStaleBG == false ⇒ today's behavior
        let cmd = link.sent.last
        #expect(cmd?.carbsGrams == 30)
        #expect(cmd?.bgMgdl == nil)        // stale value dropped from the correction
        #expect(cmd?.remoteEstimateUnits == m.estimatedUnits(forCarbs: 30))
    }

    @Test func includeStaleIsInsulinIncreasingVsCarbsOnly() {
        // A stale reading above target: including it must add the correction (a strictly larger dose),
        // which is why the choice is flagged insulin-INCREASING.
        let (m, _) = model(bg: 200, ageMinutes: 60)
        let withStale = m.estimatedUnits(forCarbs: 30, includeStaleBG: true)
        let carbsOnly = m.estimatedUnits(forCarbs: 30)
        #expect(withStale != nil && carbsOnly != nil)
        #expect(withStale! > carbsOnly!)
    }

    @Test func includeStaleIsANoOpWhenReadingIsFresh() {
        // A fresh reading is always used regardless of the flag: both paths send the same real bg and
        // estimate. The flag only matters when the reading is stale.
        let (m, link) = model(bg: 150, ageMinutes: 0.5)
        m.deliverCarbs(30, includeStaleBG: true)
        let a = link.sent.last
        m.deliverCarbs(30)                 // includeStaleBG == false
        let b = link.sent.last
        #expect(a?.bgMgdl == 150)
        #expect(b?.bgMgdl == 150)
        #expect(a?.remoteEstimateUnits == b?.remoteEstimateUnits)
    }
}
