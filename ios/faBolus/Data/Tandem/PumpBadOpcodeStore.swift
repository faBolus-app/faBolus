import Foundation
import TandemMessages

/// Durable, per-pump memory of the CURRENT_STATUS read opcodes a specific pump has rejected with an op77
/// `ErrorResponse`.
///
/// The API-2.5, non-Control-IQ t:slim X2 answers op20 `LoadStatusRequest` (and possibly
/// op40/op114/op178/op138) with an opcode-less op77 `[0,0]` and tears the BLE link down.
/// `PumpReadScheduler.resolveErrorResponse` recovers the true failing opcode by txId/FIFO correlation
/// and records it in the never-resend `badOpcodes` set. That set must persist across reconnects AND app
/// relaunches, keyed to pump identity — otherwise the same pump re-drops once on every relaunch, and a
/// different pump would inherit a skip it never earned. op20 stays in the recurring `fastRead()` poll so
/// the `cartridgeReadyForBolus` pre-guard stays live on pumps that DO support op20.
///
/// Keying: the pump's CoreBluetooth peripheral UUID (the same durable identity `PumpPeripheralStore`
/// persists at discovery) — available BEFORE the first `fastRead()` of every connection, so the skip can
/// be applied from the very first poll (no re-drop). A firmware/API-version stamp is stored ALONGSIDE the
/// opcode set (never as part of the key, since the firmware isn't yet known at load time): a caller that
/// later observes a DIFFERENT firmware for the same pump discards the stale set and re-tests the opcode —
/// so a firmware update that newly supports op20 can never keep the pre-guard starved forever.
///
/// Only the main app persists this (`UserDefaults.standard`, matching `PumpPeripheralStore`/`PumpModelStore`
/// — the widget/intents never do BLE reads). `defaults` is injectable so the test suite runs against an
/// isolated suite and never touches `.standard`.
/// `@unchecked Sendable`: both stored properties are immutable `let`s, and `UserDefaults` is documented
/// thread-safe — so the shared `.standard` singleton and any cross-actor use carry no data-race risk.
struct PumpBadOpcodeStore: @unchecked Sendable {
    /// One pump's learned rejections plus the firmware they were learned under.
    struct Entry: Equatable {
        var firmware: String?
        var opcodes: Set<UInt8>
    }

    private let defaults: UserDefaults
    private let storageKey: String

    /// Cap the number of DISTINCT pumps retained, so a user who pairs many pumps over time never
    /// accumulates stale entries indefinitely (only the currently-adopted pump is otherwise pruned,
    /// via `forgetPairing` → `reset(for:)`). Each entry is bounded (≤ ~21 read opcodes), so this is a
    /// small map; the cap is generous. Least-recently-UPDATED pumps are evicted first (`Persisted.seq`,
    /// a monotonic counter — deterministic, not wall-clock).
    static let maxRetainedPumps = 16

    init(defaults: UserDefaults = .standard, storageKey: String = "learnedBadOpcodesByPump") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// Production singleton (backed by `UserDefaults.standard`).
    static let standard = PumpBadOpcodeStore()

    // MARK: - Read

    /// This pump's persisted `{firmware, opcodes}` entry, or an empty entry (`firmware: nil, opcodes: []`)
    /// when nothing has been learned for it yet.
    func entry(for pumpKey: String) -> Entry {
        guard let p = loadMap()[pumpKey] else { return Entry(firmware: nil, opcodes: []) }
        return Entry(firmware: p.fw, opcodes: Set(p.ops.compactMap { (0...255).contains($0) ? UInt8($0) : nil }))
    }

    /// Convenience: just this pump's learned opcode set.
    func learnedOpcodes(for pumpKey: String) -> Set<UInt8> { entry(for: pumpKey).opcodes }

    // MARK: - Write

    /// Record an opcode this pump rejected, keyed to `pumpKey` and stamped with `firmware` (the API/firmware
    /// version read from THIS pump when the rejection was observed). op0 is never persisted — it is the
    /// empty-cargo artifact / bootstrap opcode and must never be suppressed. If a NON-nil `firmware` differs
    /// from the stamp already stored for this pump, the pre-existing opcodes are dropped first (they were
    /// learned under a different firmware and may no longer hold) before this one is recorded under the new
    /// stamp.
    func record(_ opcode: UInt8, for pumpKey: String, firmware: String?) {
        guard opcode != 0 else { return }
        // Never persist a pure delivery/control-WRITE opcode. `PumpReadScheduler.insertBadOpcode` already
        // refuses these before calling `persistBadOpcode`; this second choke point so a future direct
        // caller of the durable store can never seed a delivery opcode that would later hydrate into
        // `badOpcodes`. Read-colliding opcodes (op164/op144) are NOT in this set, so a legitimately-learned
        // READ still persists.
        guard !PumpReadCatalog.deliveryControlWriteOpcodes.contains(opcode) else { return }
        // Never persist a dose-input READ (op108 IOB / op115 therapy). A durable blacklist would brick
        // the bolus calculator with no re-probe. `insertBadOpcode` already refuses these; this second
        // choke point covers a future direct caller or a foreign/legacy persisted entry replayed here.
        guard !PumpReadCatalog.doseInputReadOpcodes.contains(opcode) else { return }
        // Never persist an alert-read burst opcode (op72-76, incl. op74 `CGMAlertStatusRequest`). A
        // durable blacklist would silence the phone-side CGM-alert mirror with no re-probe.
        guard !PumpReadCatalog.alertReadOpcodes.contains(opcode) else { return }
        var map = loadMap()
        var p = map[pumpKey] ?? Persisted(fw: firmware, ops: [])
        if let firmware, let existing = p.fw, existing != firmware {
            p.ops = []           // firmware changed since these were learned → re-test from scratch
        }
        if let firmware { p.fw = firmware }
        if !p.ops.contains(Int(opcode)) { p.ops.append(Int(opcode)) }
        // Stamp this pump as most-recently-updated (monotonic, deterministic) and evict the
        // least-recently-updated pumps if we now exceed the cap.
        p.seq = (map.values.compactMap { $0.seq }.max() ?? 0) + 1
        map[pumpKey] = p
        map = prunedToCap(map)
        saveMap(map)
    }

    /// Keep at most `maxRetainedPumps` entries, evicting the lowest `seq` (least-recently-updated)
    /// first. A missing `seq` (a legacy persisted entry) sorts oldest, so those are shed first.
    private func prunedToCap(_ map: [String: Persisted]) -> [String: Persisted] {
        guard map.count > Self.maxRetainedPumps else { return map }
        let keep = map.sorted { ($0.value.seq ?? 0) > ($1.value.seq ?? 0) }
            .prefix(Self.maxRetainedPumps)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    #if DEBUG
    /// Test accessor: how many distinct pumps the store currently retains.
    var retainedPumpCountForTesting: Int { loadMap().count }
    #endif

    /// Forget everything learned for one pump (e.g. on unpair, or when its firmware changed so the learned
    /// set is stale). A different pump's entry is untouched.
    func reset(for pumpKey: String) {
        var map = loadMap()
        map[pumpKey] = nil
        saveMap(map)
    }

    /// Wipe every pump's learned set (test hygiene / a full reset).
    func clearAll() { defaults.removeObject(forKey: storageKey) }

    // MARK: - Codable persistence

    /// `seq`: a monotonic last-updated stamp for LRU eviction. Optional so a legacy persisted payload
    /// decodes cleanly (nil ⇒ sorts oldest ⇒ evicted first). `fw`/`ops` unchanged.
    private struct Persisted: Codable { var fw: String?; var ops: [Int]; var seq: Int? = nil }

    private func loadMap() -> [String: Persisted] {
        guard let data = defaults.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: Persisted].self, from: data) else { return [:] }
        return map
    }

    private func saveMap(_ map: [String: Persisted]) {
        defaults.set(try? JSONEncoder().encode(map), forKey: storageKey)
    }
}
