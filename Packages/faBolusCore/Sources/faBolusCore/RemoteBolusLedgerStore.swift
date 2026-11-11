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
/// - a ledger file that can't be read blocks every new bolus until the user confirms on the pump;
/// - a request that can't be saved is dropped and the caller is told, before anything is sent;
/// - an acceptance that can't be saved is undone, so the caller doesn't send InitiateBolus;
/// - any later outcome that can't be saved stays in memory and blocks new boluses until a save
///   succeeds, because a restart would otherwise forget it.
public actor DurableBolusLedger {
    public private(set) var ledger: RemoteBolusLedger
    private let store: (any RemoteBolusLedgerPersisting)?
    private var ledgerUnreadable: Bool
    private var outcomeNotSaved = false

    /// Loads the ledger and turns anything left in flight by a previous process into its restart
    /// outcome (`RemoteBolusLedger.recoverAfterRestart`), saving that before any new request.
    public init(store: sending (any RemoteBolusLedgerPersisting)?, now: Date = Date()) {
        guard let store else {
            self.store = nil
            ledger = RemoteBolusLedger()
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
        self.ledger = ledger
        ledgerUnreadable = loaded.failedClosed
    }

    /// Why a new bolus can't start now, or `nil` when one may.
    public var block: BolusBlock? {
        if store == nil { return .noDurableStore }
        if ledgerUnreadable { return .ledgerUnreadable }
        if outcomeNotSaved { return .outcomeNotSaved }
        return ledger.block
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
        // outcome back, even while storage problems block new requests.
        if !ledger.hasExistingEntry(request.ledgerKey), let block { return .blocked(block) }
        var next = ledger
        let decision = next.begin(request, usedIncludedStaleBG: usedIncludedStaleBG, now: now)
        guard decision == .proceed else { return decision }
        try save(next, blocksOnFailure: false)
        ledger = next
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
        var next = ledger
        guard next.markAccepted(key, bolusId: bolusId, pumpKey: pumpKey, pumpClock: pumpClock, now: now) else {
            return false
        }
        try save(next, blocksOnFailure: false)
        ledger = next
        return true
    }

    @discardableResult
    public func markDelivering(_ key: RemoteBolusLedger.Key, now: Date = Date()) throws -> Bool {
        try apply { $0.markDelivering(key, now: now) }
    }

    @discardableResult
    public func markUnknown(_ key: RemoteBolusLedger.Key, now: Date = Date()) throws -> Bool {
        try apply { $0.markUnknown(key, now: now) }
    }

    @discardableResult
    public func markDelivered(_ key: RemoteBolusLedger.Key, units: Double, now: Date = Date()) throws -> Bool {
        try apply { $0.markDelivered(key, units: units, now: now) }
    }

    @discardableResult
    public func markRefused(_ key: RemoteBolusLedger.Key, reason: String, now: Date = Date()) throws -> Bool {
        try apply { $0.markRefused(key, reason: reason, now: now) }
    }

    @discardableResult
    public func markFailed(_ key: RemoteBolusLedger.Key, reason: String, now: Date = Date()) throws -> Bool {
        try apply { $0.markFailed(key, reason: reason, now: now) }
    }

    @discardableResult
    public func markDeliveredFromHistory(
        _ key: RemoteBolusLedger.Key, units: Double, historyPumpKey: String, now: Date = Date()
    ) throws -> Bool {
        try apply { $0.markDeliveredFromHistory(key, units: units, historyPumpKey: historyPumpKey, now: now) }
    }

    @discardableResult
    public func markAbsentFromHistory(
        _ key: RemoteBolusLedger.Key, historyPumpKey: String, now: Date = Date()
    ) throws -> Bool {
        try apply { $0.markAbsentFromHistory(key, historyPumpKey: historyPumpKey, now: now) }
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
        guard ledger.recordRemoteRefusal(key, reason: reason, confirmations: confirmations, now: now) else {
            return false
        }
        try save(ledger, blocksOnFailure: false)
        return true
    }

    /// The user checked the pump and confirms one unknown outcome.
    @discardableResult
    public func confirmOnPump(_ key: RemoteBolusLedger.Key, now: Date = Date()) throws -> Bool {
        try apply { $0.confirmOnPump(key, now: now) }
    }

    /// The user checked the pump and confirms every unknown outcome, including any an unreadable ledger
    /// may have hidden. Writes the ledger fresh, so an unreadable file is replaced. Never called
    /// automatically.
    public func confirmAllOnPump(now: Date = Date()) throws {
        // An unreadable file may have been a passing failure (a launch before the first unlock). Read it
        // again before writing, so a ledger that is readable now isn't replaced by an empty one.
        if ledgerUnreadable, let store {
            let reloaded = store.loadOutcome()
            if !reloaded.failedClosed {
                var recovered = reloaded.ledger
                recovered.recoverAfterRestart(now: now)
                ledger = recovered
            }
        }
        var next = ledger
        for entry in next.unresolved { next.confirmOnPump(entry.key, now: now) }
        ledger = next
        try save(next)
        ledgerUnreadable = false
    }

    /// Whether an outcome is held only in memory because its save failed, and saving again may lift that.
    /// Never while the file on disk is unreadable: replacing it is the user's call, through
    /// `confirmAllOnPump`, not a retry's.
    public var hasUnsavedOutcome: Bool { outcomeNotSaved && !ledgerUnreadable && store != nil }

    /// Try again to save an outcome that couldn't be saved. Lifts `.outcomeNotSaved` on success.
    public func retrySave() throws { try save(ledger) }

    /// Apply a transition that has already happened at the pump. It's kept in memory even if the save
    /// fails, because it's the truth; the failed save blocks new boluses instead.
    private func apply(_ transition: (inout RemoteBolusLedger) -> Bool) throws -> Bool {
        guard transition(&ledger) else { return false }
        try save(ledger)
        return true
    }

    /// - Parameter blocksOnFailure: whether a failure leaves new boluses blocked. Not for a request or
    ///   an acceptance whose failed save is undone in memory: then nothing unsaved remains.
    private func save(_ ledger: RemoteBolusLedger, blocksOnFailure: Bool = true) throws {
        guard let store else { throw LedgerNotSaved(underlying: "No durable store") }
        do {
            try store.save(ledger)
            outcomeNotSaved = false
        } catch {
            if blocksOnFailure { outcomeNotSaved = true }
            throw LedgerNotSaved(underlying: String(describing: error))
        }
    }
}
