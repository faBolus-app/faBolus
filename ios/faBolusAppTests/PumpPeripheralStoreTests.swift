import Testing
import Foundation
@testable import faBolus

/// P12 (C1) — the persisted pump peripheral id that lets a cold launch retrieve-before-scan. Pins the
/// UUID string round-trip + parse guard + clear-on-unpair. Saves/restores any real value so the test
/// doesn't disturb the host's defaults.
@MainActor
struct PumpPeripheralStoreTests {
    @Test func roundTripsAndClears() {
        let prior = PumpPeripheralStore.id()
        defer { if let prior { PumpPeripheralStore.set(prior) } else { PumpPeripheralStore.clear() } }

        let id = UUID()
        PumpPeripheralStore.set(id)
        #expect(PumpPeripheralStore.id() == id)  // round-trips (and parses the stored string back to UUID)
        PumpPeripheralStore.clear()
        #expect(PumpPeripheralStore.id() == nil)  // cleared on unpair → next launch scans, doesn't retry a stale id
    }
}
