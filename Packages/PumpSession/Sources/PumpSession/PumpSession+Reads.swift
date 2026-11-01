import Foundation
import TandemLink
import TandemMessages
import faBolusCore

/// A group of reads that come due together.
enum ReadGroup: CaseIterable, Hashable {
    /// The pump's notifications.
    case alerts
    /// What changes minute to minute: IOB, glucose and its trend, reservoir, battery, the bolus in
    /// progress and the cartridge.
    case status
    /// What changes rarely: the calculator settings, basal, limits, Control-IQ, the CGM session, and the
    /// pump clock.
    case settings
    /// Once a connection: the CGM hardware string (the G6 transmitter ID, unverified).
    case cgmHardware
    /// History sync.
    case history

    var reads: [any TandemMessages.Message] {
        switch self {
        case .alerts:
            return [
                AlertStatusRequest(), AlarmStatusRequest(), CGMAlertStatusRequest(), ReminderStatusRequest(),
                MalfunctionStatusRequest()
            ]
        case .status:
            return [
                ControlIQIOBRequest(), CurrentEGVGuiDataRequest(), HomeScreenMirrorRequest(), InsulinStatusRequest(),
                CurrentBatteryV2Request(), CurrentBolusStatusRequest(), LoadStatusRequest()
            ]
        case .settings:
            return [
                TimeSinceResetRequest(), BolusCalcDataSnapshotRequest(), CurrentBasalStatusRequest(),
                BasalLimitSettingsRequest(), ControlIQInfoV2Request(), CGMStatusRequest()
            ]
        case .cgmHardware:
            // op-96: answered on P1 with no sensor. GetG6TransmitterHardwareInfo is never sent: it drew
            // op-77 and a dropped link on P1.
            return [CGMHardwareInfoRequest()]
        case .history:
            return []
        }
    }

    var priority: PumpSession.Priority {
        switch self {
        case .alerts: return .alerts
        case .status: return .status
        case .settings, .cgmHardware: return .settings
        case .history: return .history
        }
    }
}

/// What a dose needs from the session: the pump's state with its calculator inputs freshly asked for,
/// and the ledger's view, captured together.
public struct DosePreparation: Sendable {
    /// The pump's state after the refresh. Merge a backup CGM source into it with `GlucoseArbiter`.
    public let pump: PumpState
    /// When the refresh was asked for. A reading received before it doesn't count as read for this dose.
    public let inputsRequestedAt: Date
    public let lastDeliveryAt: Date?
    public let ledger: RemoteBolusLedger
    public let bolusBlock: BolusBlock?
    public let freshness: FreshnessThresholds
    public let now: Date

    /// The composer's context, from this preparation.
    /// - Parameter pump: the state after `GlucoseArbiter.merge`, or `self.pump` when there's no backup.
    public func context(
        pump: PumpState? = nil, access: AccessPolicy.AccessContext, remoteSizeLimitUnits: Double?
    ) -> DoseContext {
        DoseContext(
            pump: pump ?? self.pump, access: access, bolusBlock: bolusBlock, inputsRequestedAt: inputsRequestedAt,
            lastDeliveryAt: lastDeliveryAt, remoteSizeLimitUnits: remoteSizeLimitUnits, freshness: freshness, now: now)
    }
}

extension PumpSession {
    /// Asks the pump for the calculator inputs and glucose for a dose about to be composed, and returns
    /// them with the ledger. A read that fails leaves the older value, which the composer then treats as
    /// not read for this dose.
    public func prepareDose() async -> DosePreparation {
        let requestedAt = clock()
        if state.link.isConnected {
            for read: any TandemMessages.Message in [
                BolusCalcDataSnapshotRequest(), ControlIQIOBRequest(), CurrentEGVGuiDataRequest(),
                HomeScreenMirrorRequest()
            ] {
                _ = await exchange(read, priority: .doseInputs)
            }
        }
        return DosePreparation(
            pump: state, inputsRequestedAt: requestedAt, lastDeliveryAt: lastDeliveryAt, ledger: await ledger.ledger,
            bolusBlock: await ledger.block, freshness: freshness, now: clock())
    }

    /// Reads the pump's CGM glucose now, ahead of the routine schedule.
    public func refreshGlucose() async {
        guard state.link.isConnected else { return }
        _ = await exchange(CurrentEGVGuiDataRequest(), priority: .user)
        _ = await exchange(HomeScreenMirrorRequest(), priority: .user)
    }

    // MARK: - The tick

    var tickInterval: TimeInterval {
        tracked != nil || page != nil || delivery != nil ? config.busyTick : config.idleTick
    }

    /// Does whatever has come due by the clock: routine reads, the reads around the next CGM reading, a
    /// delivering bolus's status, a history page that went quiet, a history sync or an unknown outcome's
    /// search. Cheap when nothing is due, so it runs after every link event as well as on the timer; a
    /// suspended app catches up on its next one.
    public func tick() {
        let now = clock()
        resumeQueue()
        historyTick(now: now)
        guard state.link.isConnected, identity != nil else { return }
        deliveryTick(now: now)
        for group in [ReadGroup.alerts, .status, .settings, .cgmHardware] where isDue(group, now: now) {
            schedule(group, now: now)
        }
        if glucoseIsDue(now: now), !isQueued(CurrentEGVGuiDataRequest.self) {
            lastGlucoseRead = now
            enqueue([CurrentEGVGuiDataRequest(), HomeScreenMirrorRequest()], priority: .status)
        }
        if isDue(.history, now: now), !historyBusy, onceThisConnection.contains(.settings) {
            due[.history] = now.addingTimeInterval(config.historySyncInterval)
            Task { await self.syncHistory() }
        }
        if let at = nextReconcileAt, now >= at, onceThisConnection.contains(.settings) {
            nextReconcileAt = nil
            Task { await self.reconcileUnknownOutcomes() }
        }
    }

    private func isDue(_ group: ReadGroup, now: Date) -> Bool {
        if group == .cgmHardware {
            return !onceThisConnection.contains(.cgmHardware) && onceThisConnection.contains(.settings)
        }
        guard let at = due[group] else { return false }
        return now >= at
    }

    private func schedule(_ group: ReadGroup, now: Date) {
        onceThisConnection.insert(group)
        switch group {
        case .alerts: due[group] = now.addingTimeInterval(config.alertInterval)
        case .status: due[group] = now.addingTimeInterval(config.statusInterval)
        case .settings: due[group] = now.addingTimeInterval(config.settingsInterval)
        case .cgmHardware, .history: break
        }
        // A read already waiting isn't queued twice.
        let reads = group.reads.filter { read in !queue.contains { MessageKey($0.message) == MessageKey(read) } }
        enqueue(reads, priority: group.priority)
    }

    /// The pump's CGM sends a reading every 5 minutes. From 20 s before the next one is expected until it
    /// arrives (or 2.5 minutes after), glucose is read every 10 s, so a new value shows within seconds
    /// instead of up to a minute later.
    private func glucoseIsDue(now: Date) -> Bool {
        guard let measured = state.glucose?.measuredAt, state.glucose?.source == .pump else { return false }
        let expected = measured.addingTimeInterval(5 * 60)
        guard now >= expected.addingTimeInterval(-20), now <= expected.addingTimeInterval(150) else { return false }
        return lastGlucoseRead.map { now.timeIntervalSince($0) >= 10 } ?? true
    }
}
