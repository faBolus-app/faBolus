import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P11 (defect group B) — the SENDER half of the receive-side freshness bound: a remote stamps `sentAt`
/// on the delivery command it sends, so the host can compute the command's age and refuse it if it arrived
/// too late. Pins the round trip: `RemoteCommandWireFixture` (the shared Watch/Mac/iPhone-remote base) stamps a
/// fresh send time, and that same stamp, once aged past the bound, is what the host's `RemoteCommandFreshness`
/// check would reject.
@Suite(.serialized) @MainActor
struct SentAtStampTests {

    /// A transport that just records what was sent (the host side is exercised by RemoteCommandFreshnessTests).
    final class RecordingLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable = true
        private(set) var sent: [RemoteCommand] = []
        func send(_ command: RemoteCommand) { sent.append(command) }
    }

    @Test func bolusRequestCarriesAFreshSentAtStamp() throws {
        let link = RecordingLink()
        let model = RemoteCommandWireFixture(link: link)
        let before = Int(Date().timeIntervalSince1970)
        model.deliverUnits(2.0)
        let after = Int(Date().timeIntervalSince1970)
        let cmd = try #require(link.sent.first { $0.kind == .bolusRequest })
        let sentAt = try #require(cmd.sentAt)
        #expect(sentAt >= before && sentAt <= after)  // stamped with the real send time
        #expect(!RemoteCommandFreshness.isStale(cmd))  // a just-sent command is fresh → accepted
    }

    @Test func aStampedBolusGoneStaleWouldBeRejectedByTheHost() throws {
        let link = RecordingLink()
        let model = RemoteCommandWireFixture(link: link)
        model.deliverUnits(2.0)
        let cmd = try #require(link.sent.first { $0.kind == .bolusRequest })
        let sentAt = try #require(cmd.sentAt)
        // The exact command, arriving at the host well past the freshness bound, is refused.
        let late = Date(timeIntervalSince1970: TimeInterval(sentAt) + RemoteCommandFreshness.maxAgeSec + 10)
        #expect(RemoteCommandFreshness.isStale(cmd, now: late))
    }
}
