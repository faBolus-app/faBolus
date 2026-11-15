import Foundation

/// Where `DurableBolusLedger` keeps the ledger. A protocol so tests can inject a store that fails to
/// save at a chosen moment or reports a corrupt file, without touching the file system.
public protocol RemoteBolusLedgerPersisting: AnyObject {
    func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome
    func save(_ ledger: RemoteBolusLedger) throws
}

/// File-backed persistence for `RemoteBolusLedger`.
///
/// Writes are atomic, so a crash mid-save can't leave a truncated file. A missing file is a fresh
/// install and loads as an empty ledger; a file that exists but can't be read loads as empty with
/// `failedClosed` set, because it may be hiding an unknown outcome.
public final class RemoteBolusLedgerStore: RemoteBolusLedgerPersisting {
    private let url: URL
    private let cap: Int

    public init(url: URL, cap: Int = 256) {
        self.url = url
        self.cap = cap
    }

    /// At-rest protection for the ledger file: encrypted, but readable after the first unlock. A
    /// relaunch in the background while the phone is locked must still read it to keep blocking an
    /// unknown outcome, which `.completeFileProtection` would prevent.
    public static let fileProtection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication

    /// The ledger file inside an App Group container when one is available, else Application Support.
    /// `nil` only when neither directory exists. The name differs from the old app's
    /// `remote-bolus-ledger.json`, which this app never reads.
    public static func defaultURL(appGroupID: String?) -> URL? {
        let fm = FileManager.default
        let dir: URL?
        if let appGroupID, let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            dir = group
        } else {
            dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        return dir?.appendingPathComponent("bolus-ledger.json")
    }

    /// A load that tells "no ledger yet" apart from "a ledger that can't be read".
    public struct LoadOutcome: Sendable {
        public let ledger: RemoteBolusLedger
        /// A ledger file exists but couldn't be read. `ledger` is empty, and every new bolus is blocked.
        public let failedClosed: Bool
        public init(ledger: RemoteBolusLedger, failedClosed: Bool) {
            self.ledger = ledger
            self.failedClosed = failedClosed
        }
    }

    public func loadOutcome() -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadOutcome(ledger: RemoteBolusLedger(cap: cap), failedClosed: false)
        }
        guard let data = try? Data(contentsOf: url),
            let ledger = try? JSONDecoder().decode(RemoteBolusLedger.self, from: data)
        else {
            return LoadOutcome(ledger: RemoteBolusLedger(cap: cap), failedClosed: true)
        }
        return LoadOutcome(ledger: ledger, failedClosed: false)
    }

    public func save(_ ledger: RemoteBolusLedger) throws {
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: url, options: [.atomic, Self.fileProtection])
    }
}

/// A ledger transition that couldn't be saved. The caller must not send anything that depends on it.
public struct LedgerNotSaved: Error, Sendable, Equatable {
    public let underlying: String
}

/// The one owner of the bolus ledger: every transition is saved before it returns.
///
/// One instance per ledger file, in the app process only. Its initializer treats anything in flight as
/// left over from a previous process, so a second instance opened while a bolus is in flight (another
/// process, or a second owner in this one) would rewrite that bolus. Anything else that needs to look at
/// the ledger reads it through `RemoteBolusLedgerStore.loadOutcome()`.
///
/// An actor, so a phone request and a watch request arriving together are decided one after the
/// other and only one proceeds. Its storage rules all fail closed:
/// - with no store, every new bolus is blocked;
/// - a ledger file that can't be read blocks every new bolus. It is read again each time the ledger or
///   its block is asked for, and adopted once it reads (a launch before the first unlock can't read it);
///   nothing but the user confirming on the pump writes over it;
/// - a request that can't be saved is dropped and the caller is told, before anything is sent;
/// - an acceptance that can't be saved is undone, so the caller doesn't send InitiateBolus;
/// - any later outcome that can't be saved stays in memory and blocks new boluses until a save
///   succeeds, because a restart would otherwise forget it.
public actor DurableBolusLedger {
    private var stored: RemoteBolusLedger
    private let store: (any RemoteBolusLedgerPersisting)?
    private var ledgerUnreadable: Bool
    private var outcomeNotSaved = false
    /// The app's clocks, when it gave them: then a phone clock set while the app runs moves the
    /// recent-delivery stamps with it (`followClock`).
    private let clock: SessionClock?
    private var clockSteps = ClockStepDetector()

    /// Loads the ledger and turns anything left in flight by a previous process into its restart
    /// outcome (`RemoteBolusLedger.recoverAfterRestart`), saving that before any new request.
    ///
    /// - Parameter clock: the app's clocks. Without them the ledger takes each call's `now` as it is.
    public init(store: sending (any RemoteBolusLedgerPersisting)?, now: Date = Date(), clock: SessionClock? = nil) {
        self.clock = clock
        guard let store else {
            self.store = nil
            stored = RemoteBolusLedger()
            ledgerUnreadable = false
            return
        }
        let loaded = store.loadOutcome()
        var ledger = loaded.ledger
        let recovered = !loaded.failedClosed && ledger.recoverAfterRestart(now: now)
        if recovered {
            do { try store.save(ledger) } catch { outcomeNotSaved = true }
        }
        self.store = store
        stored = ledger
        ledgerUnreadable = loaded.failedClosed
    }

    /// The ledger as it stands, its stamps moved for any phone clock set since the last look.
    public var ledger: RemoteBolusLedger {
        retryUnreadable()
        followClock()
        return stored
    }

    /// The time to stamp a change with: the ledger's own wall clock, read together with its look for a
    /// phone clock set, so a stamp the caller took just before the clock was set can't land unmoved among
    /// stamps that were moved. Without the app's clocks, the caller's time.
    private func stamp(_ given: Date) -> Date {
        followClock()
        return clock?.now() ?? given
    }

    /// The phone's clock being set (by hand, or a large network correction) shows as a change in the wall
    /// clock less the monotonic one. The recent-delivery stamps are moved by the same step, so a clock set
    /// forward between a delivery and a resend of the same dose under a new ID can't age the delivery out of
    /// the duplicate window. A few seconds' change is the clocks drifting, and moves nothing.
    private func followClock() {
        guard let clock, let step = clockSteps.step(clock) else { return }
        stored.phoneClockSet(by: step)
    }

    /// Why a new bolus can't start now, or `nil` when one may.
    public var block: BolusBlock? {
        if store == nil { return .noDurableStore }
        retryUnreadable()
        if ledgerUnreadable { return .ledgerUnreadable }
        if outcomeNotSaved { return .outcomeNotSaved }
        return stored.block
    }

    /// Record a new request. Only `.proceed` lets the caller go ahead, and it is returned only after the
    /// request is saved.
    ///
    /// - Throws: `LedgerNotSaved` when the request couldn't be saved. It was not recorded and nothing
    ///   may be sent.
    public func begin(
        _ request: DoseRequest, usedIncludedStaleBG: Bool = false, now: Date = Date()
    ) throws -> RemoteBolusLedger.Decision {
        // A repeat of a recorded request is answered from its own entry, so a remote always gets its
        // outcome back, even while storage problems block new requests. A file unreadable until now is
        // adopted first, so its entries answer.
        retryUnreadable()
        let now = stamp(now)
        if !stored.hasExistingEntry(request.ledgerKey), let block { return .blocked(block) }
        var next = stored
        let decision = next.begin(request, usedIncludedStaleBG: usedIncludedStaleBG, now: now)
        guard decision == .proceed else { return decision }
        try save(next, blocksOnFailure: false)
        stored = next
        return decision
    }

    /// The pump granted permission and assigned `bolusId`. Send InitiateBolus only if this returns
    /// `true` without throwing.
    ///
    /// - Throws: `LedgerNotSaved`. The acceptance is undone, so the request is still `requested`, and the
    ///   caller should not send InitiateBolus.
    @discardableResult
    public func markAccepted(
        _ key: RemoteBolusLedger.Key, bolusId: Int, pumpKey: String? = nil, pumpClock: UInt32? = nil,
        now: Date = Date()
    ) throws -> Bool {
        let now = stamp(now)
        var next = stored
        guard next.markAccepted(key, bolusId: bolusId, pumpKey: pumpKey, pumpClock: pumpClock, now: now) else {
            return false
        }
        try save(next, blocksOnFailure: false)
        stored = next
        return true
    }

    @discardableResult
    public func markDelivering(_ key: RemoteBolusLedger.Key, now: Date = Date()) throws -> Bool {
        try apply({ $0.markDelivering(key, now: $1) }, at: now)
    }

    @discardableResult
    public func markUnknown(_ key: RemoteBolusLedger.Key, now: Date = Date()) throws -> Bool {
        try apply({ $0.markUnknown(key, now: $1) }, at: now)
    }

    @discardableResult
    public func markDelivered(_ key: RemoteBolusLedger.Key, units: Double, now: Date = Date()) throws -> Bool {
        try apply({ $0.markDelivered(key, units: units, now: $1) }, at: now)
    }

    @discardableResult
    public func markRefused(_ key: RemoteBolusLedger.Key, reason: String, now: Date = Date()) throws -> Bool {
        try apply({ $0.markRefused(key, reason: reason, now: $1) }, at: now)
    }

    @discardableResult
    public func markFailed(_ key: RemoteBolusLedger.Key, reason: String, now: Date = Date()) throws -> Bool {
        try apply({ $0.markFailed(key, reason: reason, now: $1) }, at: now)
    }

    @discardableResult
    public func markDeliveredFromHistory(
        _ key: RemoteBolusLedger.Key, units: Double, historyPumpKey: String, now: Date = Date()
    ) throws -> Bool {
        try apply({ $0.markDeliveredFromHistory(key, units: units, historyPumpKey: historyPumpKey, now: $1) }, at: now)
    }

    @discardableResult
    public func markAbsentFromHistory(
        _ key: RemoteBolusLedger.Key, historyPumpKey: String, now: Date = Date()
    ) throws -> Bool {
        try apply({ $0.markAbsentFromHistory(key, historyPumpKey: historyPumpKey, now: $1) }, at: now)
    }

    /// Record a remote request refused before any entry, so its resend gets the same refusal after a
    /// restart. A refusal never blocks a new bolus, so neither does a failed save of one: it's kept in
    /// memory and goes to disk with the next save.
    ///
    /// - Throws: `LedgerNotSaved` when it couldn't be saved now.
    @discardableResult
    public func recordRemoteRefusal(
        _ key: RemoteBolusLedger.Key, reason: String, confirmations: [DoseConfirmation.Kind] = [], now: Date = Date()
    ) throws -> Bool {
        let now = stamp(now)
        guard stored.recordRemoteRefusal(key, reason: reason, confirmations: confirmations, now: now) else {
            return false
        }
        try save(stored, blocksOnFailure: false)
        return true
    }

    /// The user checked the pump and confirms one unknown outcome.
    @discardableResult
    public func confirmOnPump(_ key: RemoteBolusLedger.Key, now: Date = Date()) throws -> Bool {
        try apply({ $0.confirmOnPump(key, now: $1) }, at: now)
    }

    /// How often a read of the ledger or its block tries an unreadable file again. An explicit
    /// `reloadIfUnreadable()` always tries.
    static let unreadableRetryInterval: TimeInterval = 5
    private var lastUnreadableRetry: Double?

    /// `reloadIfUnreadable()`, at most once every `unreadableRetryInterval`: the ledger and its block are
    /// read on every tick, cancel and search, and a file that can't be read is opened from disk each try.
    private func retryUnreadable() {
        guard ledgerUnreadable else { return }
        let now = clock?.uptime() ?? ProcessInfo.processInfo.systemUptime
        if let last = lastUnreadableRetry, now >= last, now - last < Self.unreadableRetryInterval { return }
        lastUnreadableRetry = now
        reloadIfUnreadable()
    }

    /// Reads again a ledger file that couldn't be read, and adopts it as a launch would
    /// (`RemoteBolusLedger.recoverAfterRestart`). A file can be unreadable only for a while: one protected
    /// until the first unlock can't be read by a launch before it. The refusals this process recorded
    /// meanwhile are kept. Returns whether a file was adopted.
    @discardableResult
    public func reloadIfUnreadable() -> Bool {
        guard ledgerUnreadable, let store else { return false }
        let loaded = store.loadOutcome()
        guard !loaded.failedClosed else { return false }
        // This process's refusals are moved for a phone clock set so far; the file's stamps are its own.
        followClock()
        var adopted = loaded.ledger
        adopted.keepRefusals(from: stored)
        let recovered = adopted.recoverAfterRestart(now: clock?.now() ?? Date())
        stored = adopted
        ledgerUnreadable = false
        if recovered {
            do { try store.save(adopted) } catch { outcomeNotSaved = true }
        }
        return true
    }

    /// The user checked the pump and confirms every unknown outcome they were shown. While the file can't
    /// be read, that is the unreadable ledger itself: it is replaced by a fresh one. A file that reads now
    /// is adopted instead, and nothing in it is confirmed in this call: its unknown outcomes weren't shown
    /// when the user confirmed, so they block again, for the user to see and confirm. Never called
    /// automatically.
    public func confirmAllOnPump(now: Date = Date()) throws {
        if reloadIfUnreadable() { return }
        let now = stamp(now)
        var next = stored
        for entry in next.unresolved { next.confirmOnPump(entry.key, now: now) }
        stored = next
        try save(next, replacingUnreadable: true)
        ledgerUnreadable = false
    }

    /// Whether an outcome is held only in memory because its save failed, and saving again may lift that.
    /// Never while the file on disk is unreadable: replacing it is the user's call, through
    /// `confirmAllOnPump`, not a retry's.
    public var hasUnsavedOutcome: Bool { outcomeNotSaved && !ledgerUnreadable && store != nil }

    /// Try again to save an outcome that couldn't be saved. Lifts `.outcomeNotSaved` on success.
    public func retrySave() throws { try save(stored) }

    /// Apply a transition that has already happened at the pump. It's kept in memory even if the save
    /// fails, because it's the truth; the failed save blocks new boluses instead.
    private func apply(_ transition: (inout RemoteBolusLedger, Date) -> Bool, at now: Date) throws -> Bool {
        let now = stamp(now)
        guard transition(&stored, now) else { return false }
        try save(stored)
        return true
    }

    /// - Parameter blocksOnFailure: whether a failure leaves new boluses blocked. Not for a request or
    ///   an acceptance whose failed save is undone in memory: then nothing unsaved remains.
    /// - Parameter replacingUnreadable: only the user's confirm may write over a file that couldn't be read:
    ///   anything else would replace the outcomes it may hold with what this process has.
    private func save(
        _ ledger: RemoteBolusLedger, blocksOnFailure: Bool = true, replacingUnreadable: Bool = false
    ) throws {
        guard let store else { throw LedgerNotSaved(underlying: "No durable store") }
        guard !ledgerUnreadable || replacingUnreadable else {
            throw LedgerNotSaved(underlying: "The saved ledger couldn't be read")
        }
        do {
            try store.save(ledger)
            outcomeNotSaved = false
        } catch {
            if blocksOnFailure { outcomeNotSaved = true }
            throw LedgerNotSaved(underlying: String(describing: error))
        }
    }
}
