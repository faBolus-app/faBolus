import Foundation
import TandemLink
import TandemMessages
import faBolusCore

/// How a request to deliver ended, as far as the session took it.
public enum DeliveryResult: Sendable, Equatable {
    /// Recorded in the ledger; the outcome when the session finished sending: `delivering` while the
    /// pump delivers, a final outcome, or `unknown`. Later moves come as `.bolusOutcome` events.
    case started(RemoteBolusLedger.Key, BolusOutcome)
    /// The ledger already holds this request; this is its outcome. Nothing new was sent.
    case alreadyRecorded(BolusOutcome)
    /// Nothing was recorded or sent.
    case notStarted(DeliveryRefusal)
}

public enum DeliveryRefusal: Sendable, Equatable {
    /// The pump isn't connected and ready.
    case notConnected
    /// The connected pump hasn't identified itself as the paired t:slim X2, or can't take a dose.
    case pumpNotTrusted
    /// The ledger won't start a new bolus.
    case blocked(BolusBlock)
    /// The request ID was used before for a different dose.
    case requestIdReused
    /// The request couldn't be saved, so it wasn't started.
    case notRecorded
    /// The dose can't be expressed to the pump.
    case invalidDose
}

/// How a request to cancel ended.
public enum CancelResult: Sendable, Equatable {
    /// The pump confirmed the cancel. How much went in comes with the bolus's outcome.
    case cancelled
    /// The delivery was stopped before InitiateBolus was sent: nothing went in.
    case stoppedBeforeStart
    /// The pump answered that it didn't cancel, usually because the bolus had already finished.
    case notCancelled
    /// The pump has no bolus in progress.
    case noBolus
    case notConnected
    /// The cancel went out with no definite answer. The bolus's outcome still comes from the pump.
    case unconfirmed
}

/// A delivery from its ledger entry to the pump's answer to InitiateBolus.
struct DeliveryInProgress {
    let key: RemoteBolusLedger.Key
    let owner: UUID
    /// When the user (or remote) confirmed it, by the phone's clock.
    let startedAt: Date
    var bolusId: Int?
    /// InitiateBolus has been handed to the queue: from here a cancel has to go to the pump.
    var initiateQueued = false
    var cancelRequested = false
}

/// A bolus the pump accepted, followed until the pump reports it done.
struct TrackedBolus {
    let key: RemoteBolusLedger.Key
    let bolusId: Int
    let startedAt: Date
    var lastStatusAt: Date
    var lastPollAt: Date?
    var polling = false
}

extension PumpSession {
    static let cancelledBeforeStartReason = "Cancelled before the bolus was sent to the pump."

    static func iobRoseReason(from before: Double, to now: Double) -> String {
        let f = { (u: Double) in String(format: "%.2f", u) }
        return "Active insulin rose from \(f(before)) to \(f(now)) U while the bolus was starting, so it wasn't "
            + "started. Check the pump's last bolus, then review the dose again."
    }

    /// Delivers a composed dose: records it, asks the pump for permission, records the bolus ID durably,
    /// sends the BG and carb entries and InitiateBolus, and follows the bolus until the pump reports it
    /// done. Every move is recorded in the ledger before it is emitted as `.bolusOutcome`.
    ///
    /// Only an authenticated reply is definite. A permission or InitiateBolus that went out with no
    /// definite answer is handled by what could have happened: no answer to permission delivered nothing;
    /// no answer to InitiateBolus is an unknown outcome, which blocks new boluses until history settles it.
    public func deliver(_ dose: ComposedDose) async -> DeliveryResult {
        guard state.link.isConnected, identity != nil else { return .notStarted(.notConnected) }
        guard identityTrusted, state.capabilities.canDeliverBolus else { return .notStarted(.pumpNotTrusted) }
        // The commands are built once before anything is recorded, so a dose the pump can't be told is
        // refused with nothing sent.
        do { _ = try BolusCommands.make(dose, bolusId: 1, uptime: 0) } catch { return .notStarted(.invalidDose) }

        // One delivery at a time, claimed before the first suspension: another request (the phone and a
        // remote together) can't start alongside, or clear this one's state when it ends, and a cancel
        // made while the request is being recorded is seen.
        guard delivery == nil else { return .notStarted(.blocked(.bolusInProgress)) }
        let key = dose.request.ledgerKey
        let owner = UUID()
        delivery = DeliveryInProgress(key: key, owner: owner, startedAt: clock())
        defer {
            if delivery?.owner == owner {
                delivery = nil
                if exclusiveOwner == owner { exclusiveOwner = nil }
                resumeQueue()
            }
        }
        let decision: RemoteBolusLedger.Decision
        do {
            decision = try await ledger.begin(
                dose.request, usedIncludedStaleBG: dose.usedIncludedStaleGlucose, now: clock())
        } catch {
            return .notStarted(.notRecorded)
        }
        switch decision {
        case .proceed: break
        case .duplicateInFlight: return .alreadyRecorded(await ledger.ledger.outcome(key) ?? .requested)
        case .replay(let outcome): return .alreadyRecorded(outcome)
        case .conflict: return .notStarted(.requestIdReused)
        case .blocked(let block): return .notStarted(.blocked(block))
        }
        emit(.bolusOutcome(key, .requested))
        exclusiveOwner = owner
        return .started(key, await runDelivery(dose, key: key, owner: owner))
    }

    private func runDelivery(_ dose: ComposedDose, key: RemoteBolusLedger.Key, owner: UUID) async -> BolusOutcome {
        func send(_ message: any TandemMessages.Message, allowing: OperationRisk? = nil) async -> RequestResult {
            await exchange(message, allowing: allowing ?? message.operationRisk, priority: .delivery, owner: owner)
        }

        // The IOB the dose was decided against: the larger of the readings from preparing the dose (a
        // reading older than the IOB window says nothing about now) and the IOB the calculator subtracted.
        // The larger, because right after a bolus one reading can lag, and the two models can differ by a
        // step even when they agree.
        let now = clock()
        func fresh<T>(_ reading: Observed<T>?) -> T? {
            reading.flatMap { $0.isStale(after: freshness.insulinOnBoardStaleAfter, now: now) ? nil : $0.value }
        }
        let iobBeforePermission = [
            fresh(state.insulinOnBoard), fresh(state.bolusCalculator)?.insulinOnBoardUnits, dose.calculatorIOBUnits
        ]
        .compactMap { $0 }.max()
        // The pump checks a signed request against its own clock, so the clock is read first.
        guard case .reply(let firstClock) = await send(TimeSinceResetRequest(), allowing: .read),
            firstClock.message is TimeSinceResetResponse
        else { return await settle(key, .failed("The pump's clock couldn't be read. Nothing was sent.")) }

        if delivery?.cancelRequested == true {
            return await settle(key, .failed(Self.cancelledBeforeStartReason))
        }
        let bolusId: Int
        switch await send(BolusPermissionRequest()) {
        case .reply(let reply):
            guard let permission = reply.message as? BolusPermissionResponse else {
                return await settle(
                    key, .failed("The pump's answer to bolus permission wasn't one. Nothing was delivered."))
            }
            guard permission.granted else {
                return await settle(
                    key,
                    .refused(
                        "The pump refused bolus permission (status \(permission.status), reason \(permission.nackReasonId))."
                    ))
            }
            bolusId = permission.bolusId
        case .pumpError(let error):
            return await settle(key, .refused("The pump refused bolus permission (error \(error.errorCodeId))."))
        case .notSent(let reason):
            return await settle(key, .failed("Bolus permission wasn't sent (\(reason)). Nothing was delivered."))
        case .unknown(let reason):
            // Permission alone delivers nothing: whatever the pump did, no insulin went in.
            return await settle(key, .failed("No answer to bolus permission (\(reason)). Nothing was delivered."))
        }
        delivery?.bolusId = bolusId

        func abandon(_ reason: String) async -> BolusOutcome {
            // Close the permission the pump granted, as Tandem's app does when no bolus follows.
            let release = BolusPermissionReleaseRequest(bolusID: bolusId)
            _ = await send(release)
            return await settle(key, .failed(reason))
        }
        if delivery?.cancelRequested == true { return await abandon(Self.cancelledBeforeStartReason) }

        // The dose was sized from an IOB read before permission was asked. A bolus the pump started in
        // between, from its own screen or by Control-IQ, isn't in it. So the calculator snapshot, which
        // carries the pump's IOB, is read again now that the permission is held, as Tandem's app reads it
        // after permission in the recorded bolus 3.
        if let sizedFrom = iobBeforePermission {
            guard case .reply(let reply) = await send(BolusCalcDataSnapshotRequest(), allowing: .read),
                let snapshot = reply.message as? BolusCalcDataSnapshotResponse, snapshot.isAck
            else { return await abandon("The pump's active insulin couldn't be read again. Nothing was delivered.") }
            let iob = Double(snapshot.iob) / 1000
            if iob > sizedFrom + BolusVolume.stepUnits + 1e-9 {
                return await abandon(Self.iobRoseReason(from: sizedFrom, to: iob))
            }
        }

        // The durable point: InitiateBolus is sent only once the bolus ID is saved, so a crash after this
        // restarts as unknown, never as "not sent".
        do {
            let accepted = try await ledger.markAccepted(
                key, bolusId: bolusId, pumpKey: record.pairing?.pumpKey, pumpClock: anchor?.pumpTime(at: clock()),
                now: clock())
            guard accepted else { return await abandon("The bolus couldn't be recorded, so it wasn't started.") }
        } catch {
            return await abandon("The bolus couldn't be recorded, so it wasn't started.")
        }
        emit(.bolusOutcome(key, .accepted))

        // Tandem's app reads the clock again after permission, and signs the entries and InitiateBolus
        // with it; the entries carry its seconds since boot.
        guard case .reply(let secondClock) = await send(TimeSinceResetRequest(), allowing: .read),
            let time = secondClock.message as? TimeSinceResetResponse
        else { return await abandon("The pump's clock couldn't be read. Nothing was delivered.") }
        let commands: BolusCommands
        do { commands = try BolusCommands.make(dose, bolusId: bolusId, uptime: time.pumpTimeSinceReset) } catch {
            return await abandon("The dose couldn't be expressed to the pump. Nothing was delivered.")
        }

        // The entries are the pump's record of the BG and carbs; a failed one doesn't stop the bolus.
        let entries: [any TandemMessages.Message] = [
            commands.bgEntry as (any TandemMessages.Message)?, commands.carbEntry
        ]
        .compactMap { $0 }
        for entry in entries where delivery?.cancelRequested != true {
            _ = await send(entry)
        }
        if delivery?.cancelRequested == true { return await abandon(Self.cancelledBeforeStartReason) }

        // A bolus confirmed long ago (the app was suspended in between) isn't started now: the user may
        // have dosed some other way since. The limit is the remote-request freshness window.
        if let started = delivery?.startedAt, abs(clock().timeIntervalSince(started)) > RemoteRequestFreshness.maxAgeSec
        {
            return await abandon("Too long passed since the bolus was confirmed, so it wasn't started.")
        }
        // Checking the cancel flag and queuing InitiateBolus happen without a suspension between them, so a
        // cancel either stops it here or is queued after it.
        delivery?.initiateQueued = true
        let previousDelivery = lastDeliveryAt
        lastDeliveryAt = clock()
        switch await send(commands.initiate, allowing: .delivery) {
        case .reply(let reply):
            guard let initiate = reply.message as? InitiateBolusResponse, initiate.bolusId == bolusId else {
                return await settle(key, .unknown)
            }
            guard initiate.accepted else {
                return await settle(
                    key, .refused("The pump refused the bolus (status \(initiate.status), \(initiate.statusTypeId))."))
            }
            // Followed from before the move is recorded, so a drop while it is saved still finds it.
            let now = clock()
            tracked = TrackedBolus(key: key, bolusId: bolusId, startedAt: now, lastStatusAt: now)
            return await settle(key, .delivering)
        case .pumpError(let error):
            return await settle(key, .refused("The pump refused the bolus (error \(error.errorCodeId))."))
        case .notSent(let reason):
            lastDeliveryAt = previousDelivery
            return await abandon("The bolus wasn't sent (\(reason)). Nothing was delivered.")
        case .unknown:
            return await settle(key, .unknown)
        }
    }

    // MARK: - Following a delivering bolus

    func deliveryTick(now: Date) {
        guard var bolus = tracked else { return }
        // Checked on every tick, not only when a poll ends: a poll can wait behind another silent request
        // (one is on the wire at a time), and the bolus mustn't stay "delivering" past the silence.
        if statusWentSilent(bolus, now: now) {
            tracked = nil
            Task { await self.settle(bolus.key, .unknown) }
            return
        }
        guard !bolus.polling else { return }
        if bolus.lastPollAt.map({ now.timeIntervalSince($0) < config.deliveryPollInterval }) ?? false { return }
        bolus.lastPollAt = now
        bolus.polling = true
        tracked = bolus
        Task { await self.pollTrackedBolus(bolus.key) }
    }

    /// The bolus has gone `deliveryStatusSilence` with no status answer, and the pump can't still answer a
    /// poll of its own: none is out, or the one out is still waiting in the queue. A poll on the wire gets its
    /// whole deadline, so a slow answer after one lost reply still counts.
    private func statusWentSilent(_ bolus: TrackedBolus, now: Date) -> Bool {
        guard now.timeIntervalSince(bolus.lastStatusAt) > config.deliveryStatusSilence else { return false }
        return !bolus.polling || queue.contains { $0.priority == .delivery && $0.message is CurrentBolusStatusRequest }
    }

    private func pollTrackedBolus(_ key: RemoteBolusLedger.Key) async {
        let result = await exchange(CurrentBolusStatusRequest(), priority: .delivery)
        // The bolus may have been given up on while this poll waited; its reply then says nothing about
        // any bolus followed since.
        guard var bolus = tracked, bolus.key == key else { return }
        bolus.polling = false
        let now = clock()
        guard case .reply(let reply) = result, let status = reply.message as? CurrentBolusStatusResponse else {
            tracked = bolus
            if statusWentSilent(bolus, now: now) {
                tracked = nil
                await settle(bolus.key, .unknown)
            }
            return
        }
        bolus.lastStatusAt = now
        tracked = bolus
        if status.isActive, status.bolusId == bolus.bolusId {
            if now.timeIntervalSince(bolus.startedAt) > config.deliveryTrackingLimit {
                tracked = nil
                await settle(bolus.key, .unknown)
            }
            return
        }
        // The pump no longer reports this bolus active: it finished, was cancelled or stopped.
        tracked = nil
        await settleFinished(bolus)
    }

    /// How much went in, from the pump's last-bolus record, or from history when that read isn't
    /// available (one pump answers it with op-77) or names a different bolus. With neither, the outcome
    /// is unknown and history settles it later.
    private func settleFinished(_ bolus: TrackedBolus) async {
        // An untested read here would be a probe, and its op-77 can drop the link: history settles it. A
        // reply is used only when its first byte marks it valid (1); any other value says nothing about
        // what went in, whatever bolus ID it carries.
        if !isUntested(LastBolusStatusV2Request()),
            case .reply(let reply) = await exchange(LastBolusStatusV2Request(), priority: .delivery),
            let last = reply.message as? LastBolusStatusV2Response, last.isValid, last.bolusId == bolus.bolusId
        {
            await settle(bolus.key, .delivered(last.deliveredUnits))
            return
        }
        if case .completed(let record) = await searchHistory(for: bolus.bolusId, acceptedAt: nil) {
            await settle(bolus.key, .delivered(record.deliveredUnits))
            return
        }
        await settle(bolus.key, .unknown)
    }

    /// The link dropped: a bolus being followed can no longer be, and its outcome is unknown until
    /// history settles it on the next connection.
    func deliveryLinkDropped() {
        guard let bolus = tracked else { return }
        tracked = nil
        Task { await self.settle(bolus.key, .unknown) }
    }

    // MARK: - Cancel

    /// Cancels the bolus in progress. Never blocked by any setting or gate: it reaches the pump ahead of
    /// everything else, except an InitiateBolus already queued, which it follows so it can't arrive first.
    /// One request is on the wire at a time, as in t:connect, so it waits for the request ahead of it to be
    /// answered, up to `requestDeadline` when the pump is silent.
    public func cancelBolus() async -> CancelResult {
        if var d = delivery, !d.initiateQueued {
            d.cancelRequested = true
            delivery = d
            return .stoppedBeforeStart
        }
        guard state.link.isConnected else { return .notConnected }
        let owner = delivery?.owner
        let priority: Priority = owner == nil ? .cancel : .delivery
        var bolusId = tracked?.bolusId ?? delivery?.bolusId
        if bolusId == nil {
            // Ask the pump which bolus it is delivering. "No bolus" is said only on its answer; if it can't
            // be asked, the newest bolus that may still be delivering is cancelled by its recorded ID.
            let result = await exchange(CurrentBolusStatusRequest(), priority: .cancel)
            if case .reply(let reply) = result, let status = reply.message as? CurrentBolusStatusResponse {
                guard status.isActive else { return .noBolus }
                bolusId = status.bolusId
            } else {
                bolusId = await ledger.ledger.allEntries.last {
                    $0.bolusId != nil && ($0.outcome == .accepted || $0.outcome == .delivering || $0.outcome.isUnknown)
                }?.bolusId
                guard bolusId != nil else { return state.link.isConnected ? .unconfirmed : .notConnected }
            }
        }
        guard let bolusId else { return .noBolus }
        let request = CancelBolusRequest(bolusId: bolusId)
        let result = await exchange(request, allowing: request.operationRisk, priority: priority, owner: owner)
        tracked?.lastPollAt = nil
        switch result {
        case .reply(let reply):
            return (reply.message as? CancelBolusResponse)?.wasCancelled == true ? .cancelled : .notCancelled
        case .pumpError:
            // The pump didn't take the request, which says nothing about the bolus: it may still be
            // delivering, so the user is told to check the pump and cancel there.
            return .unconfirmed
        case .notSent:
            return .notConnected
        case .unknown:
            return .unconfirmed
        }
    }

    // MARK: - Unsaved outcomes

    /// An outcome the ledger couldn't save blocks new boluses until a save succeeds. Saving it again on a
    /// timer lifts the block once storage recovers (a full disk, say), rather than leaving the user stuck
    /// until the app relaunches. This includes an outcome whose save failed at launch.
    func ledgerSaveTick(now: Date) {
        guard !savingLedger, now >= nextLedgerSaveAt ?? .distantPast else { return }
        nextLedgerSaveAt = now.addingTimeInterval(config.ledgerSaveRetry)
        savingLedger = true
        Task { await self.saveUnsavedOutcomes() }
    }

    func saveUnsavedOutcomes() async {
        defer { savingLedger = false }
        guard await ledger.hasUnsavedOutcome else { return }
        do {
            try await ledger.retrySave()
            ledgerSaveFailing = false
            emit(.bolusOutcomesSaved)
        } catch {
            guard !ledgerSaveFailing else { return }
            ledgerSaveFailing = true
            sessionLog.error("bolus outcome still not saved: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Ledger moves

    enum LedgerMove {
        case failed(String)
        case refused(String)
        case delivering
        case delivered(Double)
        case unknown
        case deliveredFromHistory(Double, pumpKey: String)
        case absentFromHistory(pumpKey: String)
    }

    /// Records a move and emits the outcome it left. A move the ledger couldn't save is still the truth
    /// and stays in memory, where it blocks new boluses until a save succeeds.
    @discardableResult
    func settle(_ key: RemoteBolusLedger.Key, _ move: LedgerMove) async -> BolusOutcome {
        let now = clock()
        do {
            switch move {
            case .failed(let reason): try await ledger.markFailed(key, reason: reason, now: now)
            case .refused(let reason): try await ledger.markRefused(key, reason: reason, now: now)
            case .delivering: try await ledger.markDelivering(key, now: now)
            case .delivered(let units): try await ledger.markDelivered(key, units: units, now: now)
            case .unknown: try await ledger.markUnknown(key, now: now)
            case .deliveredFromHistory(let units, let pumpKey):
                try await ledger.markDeliveredFromHistory(key, units: units, historyPumpKey: pumpKey, now: now)
            case .absentFromHistory(let pumpKey):
                try await ledger.markAbsentFromHistory(key, historyPumpKey: pumpKey, now: now)
            }
        } catch {
            sessionLog.error("bolus outcome not saved: \(String(describing: error), privacy: .public)")
        }
        let outcome = await ledger.ledger.outcome(key) ?? .requested
        emit(.bolusOutcome(key, outcome))
        // An outcome that just became unknown is searched for soon, not at the next routine sync.
        if outcome.isUnknown {
            let soon = clock().addingTimeInterval(config.reconcileWhileDelivering)
            nextReconcileAt = min(nextReconcileAt ?? soon, soon)
        }
        return outcome
    }
}
