import Foundation
import TandemLink
import TandemMessages
import faBolusCore

/// A group of reads that come due together.
enum ReadGroup: CaseIterable, Hashable {
    /// What a dose, a cancel and the display can't do without, read first on every connection and with
    /// the status reads after: the pump clock, the bolus in progress, the calculator settings, IOB and
    /// glucose. Read ahead of anything that might draw a probe's op-77, which stops untested reads for the
    /// rest of the connection.
    case essential
    /// The pump's notifications.
    case alerts
    /// What changes minute to minute: the home screen (glucose trend, Control-IQ state), the insulin
    /// left, battery and the cartridge.
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
        case .essential:
            return [
                TimeSinceResetRequest(), CurrentBolusStatusRequest(), BolusCalcDataSnapshotRequest(),
                ControlIQIOBRequest(), CurrentEGVGuiDataRequest()
            ]
        case .alerts:
            return [
                AlertStatusRequest(), AlarmStatusRequest(), CGMAlertStatusRequest(), ReminderStatusRequest(),
                MalfunctionStatusRequest()
            ]
        case .status:
            return [HomeScreenMirrorRequest(), InsulinStatusRequest(), CurrentBatteryV2Request(), LoadStatusRequest()]
        case .settings:
            return [
                CurrentBasalStatusRequest(), BasalLimitSettingsRequest(), ControlIQInfoV2Request(), CGMStatusRequest()
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
        case .essential: return .essential
        case .alerts: return .alerts
        case .status: return .status
        case .settings, .cgmHardware: return .settings
        case .history: return .history
        }
    }
}

/// The reads a qualifying-event notice brings, bit by bit as t:connect sends them, limited to the reads
/// faBolus already sends: t:connect also reads ProfileStatus, LastBG, ExtendedBolusStatus, LastBolusStatus
/// and the Basal-IQ and sleep settings, which faBolus neither reads nor shows. The bit values are confirmed;
/// whether a t:slim raises each bit on every change is not.
enum NoticeReads {
    private static let iob: any TandemMessages.Message = ControlIQIOBRequest()
    private static let table: [(QualifyingEvent, [any TandemMessages.Message])] = [
        (.alert, [AlertStatusRequest()]),
        (.alarm, [AlarmStatusRequest()]),
        (.reminder, [ReminderStatusRequest()]),
        (.cgmAlert, [CGMAlertStatusRequest()]),
        // t:connect has no read for this bit; faBolus reads the malfunctions it shows.
        (.malfunction, [MalfunctionStatusRequest()]),
        (
            .homeScreenChange,
            [
                CurrentBasalStatusRequest(), CurrentEGVGuiDataRequest(), HomeScreenMirrorRequest(),
                ControlIQInfoV2Request()
            ]
        ),
        (.pumpSuspend, [InsulinStatusRequest(), iob]),
        (.pumpResume, [InsulinStatusRequest(), iob, CurrentEGVGuiDataRequest()]),
        (.timeChange, [iob, CGMStatusRequest(), TimeSinceResetRequest()]),
        (.basalChange, [iob, HomeScreenMirrorRequest(), CurrentBasalStatusRequest(), TempRateRequest()]),
        (.bolusChange, [CurrentBolusStatusRequest()]),
        (.iobChange, [iob]),
        (
            .cgmChange,
            [CGMStatusRequest(), CurrentEGVGuiDataRequest(), HomeScreenMirrorRequest(), TimeSinceResetRequest()]
        ),
        (.battery, [CurrentBatteryV2Request()]),
        // faBolus also reads the cartridge state, which t:connect doesn't.
        (.remainingInsulin, [InsulinStatusRequest(), LoadStatusRequest()]),
        (.controlIQInfo, [iob, ControlIQInfoV2Request()])
    ]
    private static let alertBits: QualifyingEvent = [.alert, .alarm, .reminder, .cgmAlert, .malfunction]

    static func reads(for events: QualifyingEvent) -> [(any TandemMessages.Message, PumpSession.Priority)] {
        var seen: Set<MessageKey> = []
        var reads: [(any TandemMessages.Message, PumpSession.Priority)] = []
        for (bit, messages) in table where events.contains(bit) {
            for message in messages where seen.insert(MessageKey(message)).inserted {
                reads.append((message, alertBits.contains(bit) ? .alerts : .status))
            }
        }
        return reads
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
    /// Who sent the last bolus (its ledger peer ID).
    public let lastDeliveryPeerId: String?
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
            lastDeliveryAt: lastDeliveryAt, lastDeliveryPeerId: lastDeliveryPeerId,
            remoteSizeLimitUnits: remoteSizeLimitUnits, freshness: freshness, now: now)
    }
}

extension PumpSession {
    /// Asks the pump for the calculator inputs and glucose for a dose about to be composed, and returns
    /// them with the ledger. A read that fails leaves the older value, which the composer then treats as
    /// not read for this dose.
    public func prepareDose() async -> DosePreparation {
        followPhoneClock()
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
            pump: state, inputsRequestedAt: requestedAt, lastDeliveryAt: lastDeliveryAt,
            lastDeliveryPeerId: lastDelivery?.peerId, ledger: await ledger.ledger,
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
        followPhoneClock()
        let now = uptime()
        resumeLinkWaiters()
        resumeQueue()
        historyTick(now: now)
        ledgerSaveTick(now: now)
        guard state.link.isConnected, identity != nil else { return }
        deliveryTick(now: now)
        for group in [ReadGroup.essential, .alerts, .status, .settings, .cgmHardware] where isDue(group, now: now) {
            schedule(group, now: now)
        }
        if glucoseIsDue(now: clock(), uptime: now), !isQueued(CurrentEGVGuiDataRequest.self),
            !restingAfterNoAnswer(CurrentEGVGuiDataRequest(), now: now)
        {
            lastGlucoseRead = now
            let mirror = HomeScreenMirrorRequest()
            let reads: [any TandemMessages.Message] =
                isQueued(HomeScreenMirrorRequest.self) || restingAfterNoAnswer(mirror, now: now)
                ? [CurrentEGVGuiDataRequest()] : [CurrentEGVGuiDataRequest(), mirror]
            enqueue(reads, priority: .status)
        }
        if isDue(.history, now: now), !historyBusy, onceThisConnection.contains(.settings), !historyPausedForBattery() {
            due[.history] = now.addingTimeInterval(config.historySyncInterval)
            Task { await self.syncHistory() }
        }
        if let at = nextReconcileAt, now >= at, onceThisConnection.contains(.settings) {
            nextReconcileAt = nil
            Task { await self.reconcileUnknownOutcomes() }
        }
    }

    private func isDue(_ group: ReadGroup, now: Uptime) -> Bool {
        if group == .cgmHardware {
            return !onceThisConnection.contains(.cgmHardware) && onceThisConnection.contains(.settings)
        }
        guard let at = due[group] else { return false }
        return now >= at
    }

    private func schedule(_ group: ReadGroup, now: Uptime) {
        onceThisConnection.insert(group)
        switch group {
        case .alerts: due[group] = now.addingTimeInterval(config.alertInterval)
        case .essential, .status: due[group] = now.addingTimeInterval(config.statusInterval)
        case .settings: due[group] = now.addingTimeInterval(config.settingsInterval)
        case .cgmHardware, .history: break
        }
        // A read already waiting isn't queued twice, nor one resting after the pump left it unanswered. While a
        // bolus is followed its own polls read its status every second, so the routine copy would only take a
        // poll's turn on the wire.
        for read in group.reads
        where !queue.contains(where: { MessageKey($0.message) == MessageKey(read) })
            && !restingAfterNoAnswer(read, now: now) && !(tracked != nil && read is CurrentBolusStatusRequest)
        {
            // A read this pump's class is suspected of rejecting goes last, after everything else.
            enqueue([read], priority: isSuspected(read) ? .probe : group.priority)
        }
    }

    /// The pump's CGM sends a reading every 5 minutes. From 20 s before the next one is expected until it
    /// arrives (or 2.5 minutes after), glucose is read every 10 s, so a new value shows within seconds
    /// instead of up to a minute later.
    private func glucoseIsDue(now: Date, uptime: Uptime) -> Bool {
        guard let measured = state.glucose?.measuredAt, state.glucose?.source == .pump else { return false }
        let expected = measured.addingTimeInterval(5 * 60)
        guard now >= expected.addingTimeInterval(-20), now <= expected.addingTimeInterval(150) else { return false }
        return lastGlucoseRead.map { uptime.timeIntervalSince($0) >= 10 } ?? true
    }
}
