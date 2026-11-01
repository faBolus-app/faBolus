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

    /// How many observations on DISTINCT connection cycles a `.afterCorroboratingStrikes` rejection needs
    /// before it becomes a durable exclusion. See `PumpBadOpcodeDurability`.
    ///
    /// Added for debug session `tslim-reservoir-battery-zero`: an opcode-less op-77 attributed by txId echo
    /// while ~16 reads were in flight is the one case where a burst-produced error can be pinned onto a
    /// perfectly supported read, and a single such observation used to be enough to blacklist it forever.
    /// 3 is chosen so a genuinely unsupported read still converges quickly (it fails on EVERY cycle) while
    /// no realistic one-off does. It costs nothing on a good link: the in-memory skip already suppresses
    /// the read for the rest of each connection, so the extra strikes are not extra drops within a cycle.
    static let durableStrikeThreshold = 3

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
    /// The hold-out sets every write path must respect, factored out so `record` and
    /// `recordStrike` can never drift apart. Returns false when this opcode must never be persisted:
    ///  - op0: the empty-cargo artifact / bootstrap opcode;
    ///  - a pure delivery/control-WRITE opcode (read-colliding op144/op164 are deliberately NOT in that
    ///    set, so a legitimately-learned READ still persists);
    ///  - a dose-input READ (op108 IOB / op115 therapy) — a durable blacklist bricks the calculator;
    ///  - an alert-read burst opcode (op72-76) — a durable blacklist silences the CGM-alert mirror;
    ///  - a reconciliation read (op58/op60) — a durable blacklist deletes the bolus-settle history
    ///    fallback, permanently disabling the primary path when the fast op164 read is unavailable.
    /// `PumpReadScheduler.insertBadOpcode` already refuses all of these before calling in; this is the
    /// second choke point so a future direct caller of the durable store can never seed one.
    private func isPersistable(_ opcode: UInt8) -> Bool {
        guard opcode != 0 else { return false }
        guard !PumpReadCatalog.deliveryControlWriteOpcodes.contains(opcode) else { return false }
        guard !PumpReadCatalog.doseInputReadOpcodes.contains(opcode) else { return false }
        guard !PumpReadCatalog.alertReadOpcodes.contains(opcode) else { return false }
        guard !PumpReadCatalog.reconciliationReadOpcodes.contains(opcode) else { return false }
        return true
    }

    /// Count one corroborating observation for `opcode` and persist it ONLY once the count reaches
    /// `durableStrikeThreshold`. Below the threshold nothing enters the never-resend set, so the read is
    /// re-probed on the next connection instead of being permanently deleted.
    ///
    /// The caller is responsible for calling this at most ONCE PER CONNECTION CYCLE per opcode
    /// (`PumpReadScheduler.strikesRecordedThisCycle`) — otherwise a single burst that errors the same read
    /// three times would reach the threshold instantly and the corroboration rule would be vacuous.
    /// Strike counts are dropped whenever the learned set is dropped (firmware change, `reset(for:)`), so
    /// a re-test always starts from zero.
    @discardableResult
    func recordStrike(_ opcode: UInt8, for pumpKey: String, firmware: String?) -> Bool {
        guard isPersistable(opcode) else { return false }
        var map = loadMap()
        var p = map[pumpKey] ?? Persisted(fw: firmware, ops: [])
        if let firmware, let existing = p.fw, existing != firmware {
            p.ops = []  // firmware changed since these were learned → re-test from scratch
            p.stk = [:]  // …and the strikes were earned under that stale firmware too
        }
        if let firmware { p.fw = firmware }
        let slot = String(opcode)
        var strikes = p.stk
        let count = (strikes[slot] ?? 0) + 1
        strikes[slot] = count
        p.stk = strikes
        let reachedThreshold = count >= Self.durableStrikeThreshold
        if reachedThreshold, !p.ops.contains(Int(opcode)) { p.ops.append(Int(opcode)) }
        p.seq = (map.values.map { $0.seq }.max() ?? 0) + 1
        map[pumpKey] = p
        map = prunedToCap(map)
        saveMap(map)
        return reachedThreshold
    }

    #if DEBUG
    /// Test accessor: corroborating strikes counted so far for one opcode on one pump.
    func strikeCountForTesting(_ opcode: UInt8, for pumpKey: String) -> Int {
        loadMap()[pumpKey]?.stk[String(opcode)] ?? 0
    }
    #endif

    func record(_ opcode: UInt8, for pumpKey: String, firmware: String?) {
        // The five hold-out guards (op0, delivery/control WRITE, dose-input READ, alert-read burst,
        // reconciliation READ) live in
        // `isPersistable` and are applied through it rather than restated here, so this path and
        // `recordStrike` genuinely CANNOT drift apart — see that helper's doc comment for what each one
        // protects and why. `PumpReadScheduler.insertBadOpcode` already refuses all four before calling in;
        // this is the second choke point, covering a future direct caller of the durable store and a
        // foreign/legacy persisted entry replayed here.
        //
        // debug `tslim-reservoir-battery-zero` self-audit: these guards were previously duplicated inline
        // here while `recordStrike` used the helper, so the helper's "can never drift apart" claim was not
        // actually true of this path. Routed through the helper to make it true.
        guard isPersistable(opcode) else { return }
        var map = loadMap()
        var p = map[pumpKey] ?? Persisted(fw: firmware, ops: [])
        if let firmware, let existing = p.fw, existing != firmware {
            p.ops = []  // firmware changed since these were learned → re-test from scratch
            p.stk = [:]  // …and so were any corroborating strikes
        }
        if let firmware { p.fw = firmware }
        if !p.ops.contains(Int(opcode)) { p.ops.append(Int(opcode)) }
        // Stamp this pump as most-recently-updated (monotonic, deterministic) and evict the
        // least-recently-updated pumps if we now exceed the cap.
        p.seq = (map.values.map { $0.seq }.max() ?? 0) + 1
        map[pumpKey] = p
        map = prunedToCap(map)
        saveMap(map)
    }

    /// Keep at most `maxRetainedPumps` entries, evicting the lowest `seq` (least-recently-updated) first.
    private func prunedToCap(_ map: [String: Persisted]) -> [String: Persisted] {
        guard map.count > Self.maxRetainedPumps else { return map }
        let keep = map.sorted { $0.value.seq > $1.value.seq }
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

    // MARK: - Codable persistence

    /// `seq`: a monotonic last-updated stamp for LRU eviction. `stk`: corroborating strike counts,
    /// keyed by the opcode's decimal string (JSON object keys must be strings) — only
    /// `.afterCorroboratingStrikes` rejections land here, an `.immediate` one goes straight to `ops`,
    /// and it is cleared alongside `ops` on a firmware change. Both non-optional (defaulted) rather
    /// than decoded leniently: `loadMap()` decodes the whole dictionary at once, so an entry written
    /// under an older, incompatible shape fails that decode and the map comes back empty rather than
    /// half-trusted — the store re-learns from a clean slate instead of running on a stale mix.
    private struct Persisted: Codable {
        var fw: String?
        var ops: [Int]
        var seq: Int = 0
        var stk: [String: Int] = [:]
    }

    // One entry decoded under an older shape empties this whole map on the app's first launch after this
    // change ships — every pump's learned skip set resets, so on each pump's next connect up to 5
    // previously-skipped reads are re-attempted. On an API-2.5 t:slim that means up to 5 opcode-less
    // rejections and the associated link-drop risk, then re-convergence over up to 3 connection cycles
    // (see `durableStrikeThreshold`) before the durable skip is relearned.
    private func loadMap() -> [String: Persisted] {
        guard let data = defaults.data(forKey: storageKey),
            let map = try? JSONDecoder().decode([String: Persisted].self, from: data)
        else { return [:] }
        return map
    }

    private func saveMap(_ map: [String: Persisted]) {
        defaults.set(try? JSONEncoder().encode(map), forKey: storageKey)
    }
}
