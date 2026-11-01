import Foundation

/// Why a new bolus can't start. Ordered by precedence: the first one that applies is the one shown.
public enum BolusBlock: Sendable, Hashable {
    /// There is no durable place to record a bolus before sending it.
    case noDurableStore
    /// The ledger file exists but can't be read, so it may be hiding an unknown outcome.
    case ledgerUnreadable
    /// A bolus outcome couldn't be saved. Until it is, a restart would forget it.
    case outcomeNotSaved
    /// Another bolus is being worked on. This is what keeps a phone and a watch request from both
    /// delivering.
    case bolusInProgress
    /// An earlier bolus's outcome is unknown. Cleared by pump history or by the user confirming
    /// on the pump.
    case unknownOutcome(since: Date)

    public var userMessage: String {
        switch self {
        case .noDurableStore:
            return "Delivery is locked: no durable safety store is available on this device. Delivery stays "
                + "disabled until a storage location can be created."
        case .ledgerUnreadable:
            return "Delivery is locked: the safety ledger is unreadable. Check the pump/t:connect for any "
                + "unconfirmed bolus before dosing again."
        case .outcomeNotSaved:
            return "Delivery is locked: the last bolus outcome could not be saved. Check the pump/t:connect; "
                + "delivery resumes once the safety ledger is written."
        case .bolusInProgress:
            return "A bolus is already being delivered — wait for it to finish before sending another."
        case .unknownOutcome:
            return "The last bolus's outcome isn't confirmed yet. Bolusing resumes once the app reads it "
                + "from the pump's history, or once you check the pump and confirm."
        }
    }
}

/// The durable record of every bolus request and its `BolusOutcome`.
///
/// It does three jobs:
/// - **Each request delivers at most once.** Remotes resend a message after a reconnect or a
///   retry, so a request is keyed by who sent it and its request ID, above any transport. A repeat
///   gets the first request's outcome back, never a second dose.
/// - **One bolus at a time.** While one request is in flight every other request is refused, whichever
///   surface it came from.
/// - **An unknown outcome blocks new boluses** until pump history settles it or the user confirms
///   on the pump. The ledger is persisted after each transition (`DurableBolusLedger`), so the block
///   survives a restart, and a restart turns anything left in flight into `unknown`.
///
/// A value type with no I/O, so every rule here is tested without a file system.
public struct RemoteBolusLedger: Sendable, Codable {
    /// Who asked, and the request's ID.
    public struct Key: Sendable, Hashable, Codable {
        public let peerId: String
        public let requestId: String
        public init(peerId: String, requestId: String) {
            self.peerId = peerId
            self.requestId = requestId
        }
    }

    /// One request and where it stands.
    public struct Entry: Sendable, Hashable, Codable {
        public let request: DoseRequest
        public fileprivate(set) var outcome: BolusOutcome
        /// When `outcome` last changed.
        public fileprivate(set) var updatedAt: Date
        /// The pump's bolus ID, once the pump has assigned one. History is searched by it.
        public fileprivate(set) var bolusId: Int?
        /// The identity of the pump that assigned `bolusId`, so a later pump's history is never used to
        /// settle it. `nil` when unknown.
        public fileprivate(set) var pumpKey: String?
        /// The dose's correction used a stale glucose reading the user chose to include. An audit
        /// record only; it plays no part in any decision.
        public fileprivate(set) var usedIncludedStaleBG: Bool
        /// When the user confirmed an unknown outcome on the pump. The outcome stays `unknown`, because
        /// the app still doesn't know how much went in, but it no longer blocks; history can still
        /// settle it later.
        public fileprivate(set) var confirmedOnPumpAt: Date?
        /// Something that could deliver insulin may have been sent: the pump granted permission, which
        /// is the only way a bolus ID is recorded.
        public var reachedPump: Bool { bolusId != nil }

        public var key: Key { request.ledgerKey }

        /// This entry stops a new bolus from starting.
        public var blocksNewBolus: Bool {
            outcome.isInFlight || (outcome.isUnknown && confirmedOnPumpAt == nil)
        }
    }

    /// What `begin` tells the caller to do.
    public enum Decision: Sendable, Hashable {
        /// A new request, now recorded as `requested`. The caller may go ahead.
        case proceed
        /// The same request is still being worked on, or its outcome is unknown. Don't deliver again.
        case duplicateInFlight
        /// The same request already has a final outcome. Report it; don't deliver again.
        case replay(BolusOutcome)
        /// The request ID was reused with different dose parameters. Refuse.
        case conflict
        /// A new bolus can't start now.
        case blocked(BolusBlock)
    }

    private var entries: [Key: Entry] = [:]
    /// Oldest first.
    private var order: [Key] = []
    private let cap: Int

    /// When each peer's dose content last went in or may have, so a remote that missed its outcome and
    /// recomposes the same dose under a new request ID can be stopped (`hasRecentlyDeliveredDuplicate`).
    /// It only needs to cover a seconds-scale window while the app runs, so it isn't persisted; the
    /// request ID is what protects across a restart.
    private var recentDeliveries: [String: Date] = [:]

    /// - Parameter cap: how many final entries are kept. Entries that block or may still change are
    ///   never evicted.
    public init(cap: Int = 256) { self.cap = max(1, cap) }

    // MARK: - Requests

    /// Record a new request, or recognize a repeat of one already recorded.
    ///
    /// A repeat is answered from its own entry first, so a remote that missed an outcome always gets
    /// it back, even while something else blocks new boluses.
    public mutating func begin(
        _ request: DoseRequest, usedIncludedStaleBG: Bool = false, now: Date = Date()
    ) -> Decision {
        let key = request.ledgerKey
        if let existing = entries[key] {
            if existing.request.doseKey != request.doseKey { return .conflict }
            return existing.outcome.isFinal ? .replay(existing.outcome) : .duplicateInFlight
        }
        if let block { return .blocked(block) }
        entries[key] = Entry(
            request: request, outcome: .requested, updatedAt: now, bolusId: nil, pumpKey: nil,
            usedIncludedStaleBG: usedIncludedStaleBG, confirmedOnPumpAt: nil)
        order.append(key)
        evictIfNeeded()
        return .proceed
    }

    /// Why a new bolus can't start, from what the ledger itself holds: one in flight, or an unknown
    /// outcome nobody has confirmed. Storage problems are added by `DurableBolusLedger`.
    public var block: BolusBlock? {
        let blocking = order.compactMap { entries[$0] }.filter(\.blocksNewBolus)
        if blocking.contains(where: { $0.outcome.isInFlight }) { return .bolusInProgress }
        let since = blocking.compactMap { entry -> Date? in
            if case .unknown(let since) = entry.outcome { return since }
            return nil
        }.min()
        return since.map { .unknownOutcome(since: $0) }
    }

    // MARK: - Transitions
    //
    // Each returns whether it applied. A move `BolusOutcome.canMove(to:)` doesn't allow is ignored, so a
    // late, duplicated or out-of-order pump event can't rewrite an outcome.

    /// The pump granted permission and assigned `bolusId`. This is the durable point before
    /// InitiateBolus: the caller saves the ledger and sends InitiateBolus only if the save succeeds.
    ///
    /// - Parameter pumpKey: the connected pump's identity. The unpaired sentinel isn't recorded,
    ///   because two different unpaired pumps would compare equal.
    @discardableResult
    public mutating func markAccepted(_ key: Key, bolusId: Int, pumpKey: String? = nil, now: Date = Date()) -> Bool {
        move(key, to: .accepted, now: now) { entry in
            entry.bolusId = bolusId
            if let pumpKey, pumpKey != Self.unpairedPumpKeySentinel { entry.pumpKey = pumpKey }
        }
    }

    /// The pump accepted InitiateBolus.
    @discardableResult
    public mutating func markDelivering(_ key: Key, now: Date = Date()) -> Bool {
        move(key, to: .delivering, now: now)
    }

    /// The app lost track after something that could deliver was sent.
    @discardableResult
    public mutating func markUnknown(_ key: Key, now: Date = Date()) -> Bool {
        move(key, to: .unknown(since: now), now: now)
    }

    /// The pump reported how much went in, in its completion reply. Below the requested amount this is
    /// `stopped`, otherwise `delivered`, including `stopped(delivered: 0, …)` for a bolus stopped before
    /// anything went in. A non-finite or negative amount isn't a reading, so it's ignored and the outcome
    /// stays where it was. An unknown outcome is settled only from history
    /// (`markDeliveredFromHistory`, `markAbsentFromHistory`).
    @discardableResult
    public mutating func markDelivered(_ key: Key, units: Double, now: Date = Date()) -> Bool {
        guard units.isFinite, units >= 0, let entry = entries[key], !entry.outcome.isUnknown else { return false }
        let outcome = BolusOutcome.settled(deliveredUnits: units, requestedUnits: entry.request.totalUnits)
        return move(key, to: outcome, now: now)
    }

    /// The history of the pump identified by `historyPumpKey` records this unknown bolus with the
    /// amount delivered. Refused when the entry was assigned by a different pump, whose bolus IDs this
    /// history doesn't speak for.
    @discardableResult
    public mutating func markDeliveredFromHistory(
        _ key: Key, units: Double, historyPumpKey: String, now: Date = Date()
    ) -> Bool {
        guard units.isFinite, units >= 0, let entry = entries[key], entry.outcome.isUnknown,
            Self.comparePumpKey(entry.pumpKey, to: historyPumpKey) != .mismatch
        else { return false }
        let outcome = BolusOutcome.settled(deliveredUnits: units, requestedUnits: entry.request.totalUnits)
        return move(key, to: outcome, now: now)
    }

    /// The pump refused, in an authenticated reply.
    @discardableResult
    public mutating func markRefused(_ key: Key, reason: String, now: Date = Date()) -> Bool {
        move(key, to: .refused(reason: reason), now: now)
    }

    /// Nothing was delivered, for a reason the caller knows for certain. From `accepted` this is only
    /// right when InitiateBolus was never sent. It never applies to an unknown outcome: only pump
    /// history can settle that (`markAbsentFromHistory`).
    @discardableResult
    public mutating func markFailed(_ key: Key, reason: String, now: Date = Date()) -> Bool {
        guard entries[key]?.outcome.isUnknown == false else { return false }
        return move(key, to: .failed(reason: reason), now: now)
    }

    /// The history of the pump identified by `historyPumpKey` shows there was no such bolus, so an
    /// unknown outcome delivered nothing. Only the pump that assigned the bolus ID can show that: a
    /// different pump's history never contains it, and an entry with no recorded identity can't be
    /// matched, so both are refused and only history with the amount or the user confirming on the
    /// pump can release them.
    @discardableResult
    public mutating func markAbsentFromHistory(_ key: Key, historyPumpKey: String, now: Date = Date()) -> Bool {
        guard let entry = entries[key], entry.outcome.isUnknown,
            Self.comparePumpKey(entry.pumpKey, to: historyPumpKey) == .matches
        else { return false }
        return move(key, to: .failed(reason: Self.absentFromHistoryReason), now: now)
    }

    public static let absentFromHistoryReason = "Pump history shows this bolus was never delivered."

    /// The user checked the pump and confirms an unknown outcome there. New boluses are no longer
    /// blocked by it. It stays `unknown`, and history can still settle it.
    @discardableResult
    public mutating func confirmOnPump(_ key: Key, now: Date = Date()) -> Bool {
        guard var entry = entries[key], entry.outcome.isUnknown, entry.confirmedOnPumpAt == nil else {
            return false
        }
        entry.confirmedOnPumpAt = now
        entries[key] = entry
        return true
    }

    /// Run once when a saved ledger is loaded. Nothing can be in flight in a new process:
    /// - a request that never reached the pump failed, because nothing that delivers was sent;
    /// - one that did is now `unknown`, dated from its last transition, and blocks new boluses.
    ///
    /// Returns whether anything changed, so the caller knows to save.
    @discardableResult
    public mutating func recoverAfterRestart(now: Date = Date()) -> Bool {
        var changed = false
        for key in order {
            guard let entry = entries[key], entry.outcome.isInFlight else { continue }
            if entry.outcome == .requested {
                move(key, to: .failed(reason: "The app stopped before sending the bolus to the pump."), now: now)
            } else {
                move(key, to: .unknown(since: entry.updatedAt), now: now)
            }
            changed = true
        }
        return changed
    }

    @discardableResult
    private mutating func move(
        _ key: Key, to next: BolusOutcome, now: Date, _ update: (inout Entry) -> Void = { _ in }
    ) -> Bool {
        guard var entry = entries[key], entry.outcome.canMove(to: next) else { return false }
        let wasSent = entry.reachedPump || entry.outcome.mayHaveDelivered
        entry.outcome = next
        entry.updatedAt = now
        update(&entry)
        entries[key] = entry
        if next.isUnknown || (next.isFinal && (wasSent || next.mayHaveDelivered)) {
            recentDeliveries[recencyKey(key.peerId, entry.request.doseKey)] = now
        }
        // No eviction here: only `begin` grows the ledger, and evicting on a move could drop the entry
        // that just became final while a remote may still resend it.
        return true
    }

    // MARK: - Queries

    public func entry(_ key: Key) -> Entry? { entries[key] }

    public func outcome(_ key: Key) -> BolusOutcome? { entries[key]?.outcome }

    public func hasExistingEntry(_ key: Key) -> Bool { entries[key] != nil }

    /// Every entry, oldest first.
    public var allEntries: [Entry] { order.compactMap { entries[$0] } }

    /// Unknown outcomes that still block, oldest first. These are what the user is asked to check.
    public var unresolved: [Entry] { allEntries.filter { $0.outcome.isUnknown && $0.confirmedOnPumpAt == nil } }

    /// Every unknown outcome, confirmed on the pump or not, oldest first. These are what pump history
    /// is searched for.
    public var unknownOutcomes: [Entry] { allEntries.filter { $0.outcome.isUnknown } }

    /// The final outcomes recorded for `peerId`, oldest first, for re-sending to a remote that may
    /// have missed them across a restart.
    public func finalOutcomes(peerId: String) -> [(requestId: String, outcome: BolusOutcome)] {
        allEntries.filter { $0.key.peerId == peerId && $0.outcome.isFinal }.map { ($0.key.requestId, $0.outcome) }
    }

    // MARK: - Dose-content duplicates

    /// How long `hasRecentlyDeliveredDuplicate` remembers a dose: the same window as a remote request's
    /// freshness limit, since both bound how long a remote's stale view of the phone is a double-dose
    /// risk.
    public static let recentDuplicateWindowSec: TimeInterval = RemoteCommandFreshness.maxAgeSec

    /// True when `peerId`'s dose `doseKey` went in, or may have, within `window` of `now`, whatever
    /// request ID it had. Scoped to one peer: the risk is a remote recomposing its own request after
    /// missing the outcome, not a coincidental match from another surface. `begin` doesn't consult it;
    /// the dose checks do, before `begin`, for a request with a new ID.
    public func hasRecentlyDeliveredDuplicate(
        peerId: String, doseKey: String, within window: TimeInterval = recentDuplicateWindowSec, now: Date = Date()
    ) -> Bool {
        guard let at = recentDeliveries[recencyKey(peerId, doseKey)] else { return false }
        return now.timeIntervalSince(at) <= window
    }

    private func recencyKey(_ peerId: String, _ doseKey: String) -> String { peerId + "\u{1F}" + doseKey }

    /// A stable fingerprint of the dose parameters. Rounded so float formatting can't make two equal
    /// doses differ.
    public static func doseKey(units: Double?, carbsGrams: Double?, bgMgdl: Int?) -> String {
        func f(_ d: Double?) -> String { d.map { String(format: "%.4f", $0) } ?? "-" }
        return "u:\(f(units))|c:\(f(carbsGrams))|bg:\(bgMgdl.map(String.init) ?? "-")"
    }

    // MARK: - Pump identity

    /// The identity a caller must not record: the "no peripheral yet" identity. Two different unpaired
    /// pumps would both produce it and compare equal.
    public static let unpairedPumpKeySentinel = "real|unpaired"

    /// How an entry's recorded pump compares with the pump connected now.
    public enum PumpKeyComparison: Sendable, Equatable {
        /// No identity was recorded.
        case grandfathered
        /// Same pump: its history may settle the entry.
        case matches
        /// A different pump: its history must never settle the entry, so only the user confirming on the
        /// pump that assigned it can release the block.
        case mismatch
    }

    public static func comparePumpKey(_ pumpKey: String?, to currentPumpIdentity: String) -> PumpKeyComparison {
        guard let pumpKey else { return .grandfathered }
        return pumpKey == currentPumpIdentity ? .matches : .mismatch
    }

    // MARK: - Reconciliation notification keys

    /// Prefix of the per-request reconciliation notification's dedupe key.
    public static let reconciliationDedupeKeyPrefix = "reconcile-"

    /// The dedupe key of the notification that announces this request's settled outcome. One per
    /// request, so a withdrawal can find it by `isReconciliationDedupeKey`.
    public static func reconciliationDedupeKey(peerId: String, requestId: String) -> String {
        "\(reconciliationDedupeKeyPrefix)\(peerId)-\(requestId)"
    }

    /// Whether `dedupeKey` belongs to the reconciliation family. A plain prefix test, because peer and
    /// request IDs may contain `-`; prefer the notification category when deciding what to prune.
    public static func isReconciliationDedupeKey(_ dedupeKey: String) -> Bool {
        dedupeKey.hasPrefix(reconciliationDedupeKeyPrefix)
    }

    /// The fixed key for the notice shown when the ledger can't be read, which has no request to name.
    /// Fixed, so repeated launches with an unreadable ledger replace one notice instead of stacking.
    public static let unreadableLedgerReconciliationDedupeKey = "\(reconciliationDedupeKeyPrefix)ledger-unreadable"

    // MARK: - Eviction

    private mutating func evictIfNeeded() {
        while order.count > cap {
            guard let index = order.firstIndex(where: { entries[$0].map(Self.isEvictable) ?? true }) else { break }
            entries.removeValue(forKey: order.remove(at: index))
        }
    }

    /// Only a final outcome may be dropped. Anything in flight or unknown still matters to a restart or
    /// to a history search.
    private static func isEvictable(_ entry: Entry) -> Bool { entry.outcome.isFinal }

    // MARK: - Codable

    /// The saved format. A file with any other version is treated as unreadable, so a format this build
    /// doesn't know can't be misread as an empty ledger.
    public static let formatVersion = 1

    private enum CodingKeys: String, CodingKey { case version, cap, entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c, debugDescription: "Unsupported ledger format \(version)")
        }
        cap = max(1, try c.decode(Int.self, forKey: .cap))
        for entry in try c.decode([Entry].self, forKey: .entries) {
            let key = entry.key
            guard entries[key] == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .entries, in: c, debugDescription: "Duplicate ledger entry")
            }
            entries[key] = entry
            order.append(key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(cap, forKey: .cap)
        try c.encode(allEntries, forKey: .entries)
    }
}
