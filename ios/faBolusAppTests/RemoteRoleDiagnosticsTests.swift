import Testing
import faBolusCore
@testable import faBolus

/// Phase 09.6-03 (Task 2, Part C-4b, D-03.4): behavior pins for the `[Remote role]` diagnostics
/// section — fabricated role/peer inputs only (no live BLE/`MacPairingCoordinator` instantiation
/// required), matching the plan's "inject the host/peer state as plain values" direction.
struct RemoteRoleDiagnosticsTests {
    @Test func hostWithGrantedAndPendingPeerRendersRoleAndPerPeerLines() {
        let granted = RemoteRoleDiagnostics.PeerInfo(
            displayName: "Zev's MacBook Pro", connected: true,
            policy: RemotePeerPolicy(permissions: [.bolus, .cancelBolus], approvalMode: .auto))
        let pending = RemoteRoleDiagnostics.PeerInfo(
            displayName: "Tia's iPhone", connected: false, policy: .viewOnly)
        let block = RemoteRoleDiagnostics.section(role: "host", peers: [granted, pending], enabled: true)
        let lines = block.components(separatedBy: "\n")

        #expect(lines.first == "")
        #expect(lines[1] == "[Remote role]")
        #expect(lines.contains("Role: host"))
        // One line per peer: connection + grant state present, exactly 2 peer lines beyond role.
        let peerLines = lines.filter { $0 != "" && $0 != "[Remote role]" && $0 != "Role: host" }
        #expect(peerLines.count == 2)
        #expect(peerLines.contains { $0.contains("connected") && $0.contains("granted") })
        #expect(peerLines.contains { $0.contains("disconnected") && $0.contains("pending") })
    }

    @Test func noRemoteRelationshipRendersEmptyState() {
        let block = RemoteRoleDiagnostics.section(role: "host", peers: [], enabled: true)
        let lines = block.components(separatedBy: "\n")

        #expect(lines == ["", "[Remote role]", "— (not currently reachable)"])
    }

    @Test func disabledRendersOnlyHeaderAndEmptyStatePrompt() {
        let peer = RemoteRoleDiagnostics.PeerInfo(displayName: "Zev's MacBook Pro", connected: true, policy: .fullControl)
        let block = RemoteRoleDiagnostics.section(role: "host", peers: [peer], enabled: false)
        let lines = block.components(separatedBy: "\n")

        #expect(lines == [
            "",
            "[Remote role]",
            "Turn on “Share local diagnostics” above to start collecting remote-role data.",
        ])
        #expect(!block.contains("Zev's MacBook Pro"))
    }

    @Test func peerDisplayNameNeverAppearsVerbatim() {
        let peer = RemoteRoleDiagnostics.PeerInfo(displayName: "Zev's MacBook Pro", connected: true,
                                                   policy: RemotePeerPolicy(permissions: [.bolus], approvalMode: .auto))
        let block = RemoteRoleDiagnostics.section(role: "host", peers: [peer], enabled: true)
        #expect(!block.contains("Zev's MacBook Pro"))
        #expect(!block.contains("MacBook"))
    }

    @Test func stableTokenIsDeterministicAcrossCalls() {
        let peer = RemoteRoleDiagnostics.PeerInfo(displayName: "Same Name", connected: true, policy: .viewOnly)
        let a = RemoteRoleDiagnostics.section(role: "host", peers: [peer], enabled: true)
        let b = RemoteRoleDiagnostics.section(role: "host", peers: [peer], enabled: true)
        #expect(a == b)
    }
}
