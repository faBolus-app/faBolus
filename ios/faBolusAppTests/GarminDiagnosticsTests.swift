import Testing
import faBolusCore
@testable import faBolus

/// Behavior pins for the `[Garmin CIQ]` diagnostics section — a fabricated
/// `GarminDiagnostics.BridgeState` plain value is injected directly (no live
/// `GarminRemoteBridge`/ConnectIQ instantiation required), mirroring `RemoteRoleDiagnostics`'s
/// "inject the already-tracked state as plain values" precedent. Any Garmin device name must never
/// appear verbatim in the rendered text.
@MainActor
struct GarminDiagnosticsTests {
    @Test func populatedConnectedStateRendersQueueSendWatchdogAndDevice() {
        let state = GarminDiagnostics.BridgeState(
            queueDepth: 3, lastSendOutcome: .delivered, watchdogFires: 1,
            deviceConnected: true, deviceName: nil)
        let block = GarminDiagnostics.section(state: state, enabled: true)
        let lines = block.components(separatedBy: "\n")

        #expect(lines.first == "")
        #expect(lines[1] == "[Garmin CIQ]")
        #expect(block.contains("Queue depth: 3"))
        #expect(block.contains("Last send: delivered"))
        #expect(block.contains("Watchdog fires: 1"))
        #expect(block.contains("Device: connected"))
    }

    @Test func pairedButDisconnectedDeviceRendersDeviceDisconnected() {
        let state = GarminDiagnostics.BridgeState(
            queueDepth: 0, lastSendOutcome: .failed, watchdogFires: 2,
            deviceConnected: false, deviceName: nil)
        let block = GarminDiagnostics.section(state: state, enabled: true)

        #expect(block.contains("Queue depth: 0"))
        #expect(block.contains("Last send: failed"))
        #expect(block.contains("Watchdog fires: 2"))
        #expect(block.contains("Device: disconnected"))
    }

    @Test func noDeviceEverPairedRendersUnreachableEmptyState() {
        let block = GarminDiagnostics.section(state: nil, enabled: true)

        #expect(block.contains("[Garmin CIQ]"))
        #expect(block.contains("— (not currently reachable)"))
        #expect(!block.contains("Queue depth"))
    }

    @Test func disabledRendersOnlyHeaderAndEmptyStatePrompt() {
        let state = GarminDiagnostics.BridgeState(
            queueDepth: 5, lastSendOutcome: .delivered, watchdogFires: 3,
            deviceConnected: true, deviceName: "Zev's venu3s")
        let block = GarminDiagnostics.section(state: state, enabled: false)

        #expect(block.contains("[Garmin CIQ]"))
        #expect(!block.contains("Queue depth"))
        #expect(!block.contains("Zev's venu3s"))
    }

    @Test func deviceNameNeverAppearsVerbatimAndTokenIsDeterministicAcrossCalls() {
        let state = GarminDiagnostics.BridgeState(
            queueDepth: 1, lastSendOutcome: .timedOut, watchdogFires: 4,
            deviceConnected: true, deviceName: "Zev's venu3s")
        let first = GarminDiagnostics.section(state: state, enabled: true)
        let second = GarminDiagnostics.section(state: state, enabled: true)

        #expect(!first.contains("Zev's venu3s"))
        #expect(first == second)
        #expect(first.contains("Device: connected"))
        #expect(first.contains("Last send: timed out"))
    }
}
