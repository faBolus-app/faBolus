import Foundation
import TandemBLE
import TandemLink
import TandemMessages

/// A t:slim X2 and its radio, as CoreBluetooth would report them, for running the real session and link
/// with no pump. It pairs with the legacy 16-character code, answers the handshake, the status reads the
/// session makes, the signed bolus writes and the history log, and keeps a bolus engine: a granted
/// permission, an initiated bolus that delivers at `deliveryMilliunitsPerSecond` of clock time, cancel,
/// release, and history records for what it did. Every reply is framed and signed as the pump's would be,
/// so the link's checks run on it unchanged.
///
/// Faults are set per request (`answers`): a captured reply in place of the scripted one, an op-77 with
/// or without a drop, silence, or a drop before or after the pump acts on the request.
@MainActor
public final class ScriptedPump {
    public static let peripheralID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
    /// The legacy pairing code. The signing key is its bytes.
    public static let code = "ABCDEFGHIJKLMNOP"

    public var name = "tslim X2 ***693"
    public var serialNumber: UInt32 = 1693
    /// The ARM and MSP software versions PumpVersion reports: with the serial, the unit a support record
    /// is kept for.
    public var softwareVersion: UInt32 = 7
    public var apiVersion = (major: 2, minor: 5)
    public var inRange = true
    public var poweredOn = true
    public var linked = false
    /// The pump rejects the pairing code.
    public var rejectsPairing = false

    /// The pump's wall clock (seconds since 2008, local) at clock time 0, as TimeSinceReset's
    /// `currentTime` reports it and history records are stamped.
    public var wallClockAtStart: UInt32 = 512_442_842
    /// Seconds since the pump booted, at clock time 0 (TimeSinceReset's `pumpTimeSinceReset`).
    public var uptimeAtStart: UInt32 = 1_905_413

    // MARK: Readings

    public var insulinOnBoardMilliunits: UInt32 = 500
    public var reservoirUnits = 150
    public var batteryPercent = 80
    public var charging = false
    public var carbRatioMilli: UInt32 = 10_000
    public var correctionFactor = 40
    public var targetMgdl = 110
    public var maxBolusMilliunits = 25_000
    /// The IOB the calculator reply itself reports (op-115).
    public var calculatorInsulinOnBoardMilliunits: UInt32 = 500
    /// The CGM reading and how long before now it was measured, or nil for none.
    public var glucose: (mgdl: Int, ageSeconds: Double)? = (120, 60)
    /// The home-screen trend icon id (4 is flat, 0 no arrow).
    public var trendIcon = 4
    public var cgmHardwareInfo = "8KX21P"
    public var basalMilliunitsPerHour: UInt32 = 800
    public var controlIQEnabled = false
    public var alertBitmap: UInt64 = 0
    public var alarmBitmap: UInt64 = 0
    public var cgmAlertBitmap: UInt64 = 0
    public var reminderBitmap: UInt64 = 0
    public var malfunctionBitmap: UInt64 = 0
    /// A cartridge is in: without one the pump refuses bolus permission.
    public var cartridgeLoaded = true
    /// Answers a DismissNotification with status 0 but leaves the alert showing, as some firmware may.
    public var dismissLeavesAlert = false

    // MARK: Faults

    public enum Answer: Sendable {
        /// The scripted reply.
        case normal
        /// This cargo in place of the scripted reply (a captured frame's cargo).
        case cargo([UInt8])
        /// An op-77 with this error code, then a link drop about 90 ms later when `drops`.
        case error(code: UInt8, drops: Bool)
        /// No reply at all.
        case silent
        /// The pump acts on the request and its reply is lost.
        case actedWithoutReply
        /// The link drops once the request arrives: after the pump acted on it when `acted`, before
        /// when not.
        case drop(acted: Bool)
        /// These qualifying events, then the scripted reply: a notice that reaches the phone while the
        /// request is in flight.
        case notice(QualifyingEvent)
    }
    /// Answers by request, overriding the scripted one each time it arrives.
    public var answers: [MessageKey: Answer] = [:]
    /// Answers for the next arrival only, consumed in order.
    public var nextAnswers: [MessageKey: [Answer]] = [:]
    /// Reads this pump doesn't support, answered as P1 does: op-77 with cargo `00 00`, then a drop.
    public var unsupportedReads: Set<MessageKey> = [
        MessageKey(LoadStatusRequest.self), MessageKey(CurrentEgvGuiDataV2Request.self)
    ]
    /// Stop answering anything.
    public var silent = false

    // MARK: Bolus engine

    public struct Bolus: Sendable, Equatable {
        public let id: Int
        public let requestedMilliunits: UInt32
        public let startedAt: LinkTime
        public var cancelledAt: LinkTime?
        public let carbs: Int
        public let bg: Int
        public let typeBitmask: Int
        public let foodMilliunits: UInt32
        public let correctionMilliunits: UInt32
        public let iobMilliunits: UInt32
    }
    public var nextBolusId = 10650
    public var deliveryMilliunitsPerSecond: Double = 100
    public internal(set) var grantedPermission: Int?
    public internal(set) var activeBolus: Bolus?
    public private(set) var completed: [Bolus] = []
    /// Permissions released without a bolus.
    public internal(set) var released: [Int] = []

    // MARK: History

    public var firstSequence: UInt32 = 1000
    public private(set) var historyRecords: [[UInt8]] = []
    /// Records per stream frame.
    public var recordsPerFrame = 9

    // MARK: What arrived

    public struct Arrival: Sendable, Equatable {
        public let characteristic: Characteristic
        public let opCode: UInt8
        public let txId: UInt8
        public let cargo: [UInt8]
        /// The signed trailer's pump time, for a signed request.
        public let signedTime: UInt32?
    }
    public internal(set) var arrivals: [Arrival] = []

    weak var transport: ScriptedTransport?
    let clock: ScriptClock

    public init(clock: ScriptClock) { self.clock = clock }

    public var wallClock: UInt32 { wallClockAtStart &+ UInt32(clock.now) }
    public var uptime: UInt32 { uptimeAtStart &+ UInt32(clock.now) }

    public func arrivals(of type: (some Message).Type) -> [Arrival] {
        let key = MessageKey(type)
        return arrivals.filter { $0.characteristic == key.characteristic && $0.opCode == key.opCode }
    }

    // MARK: History records

    /// Appends a 26-byte history record of `typeId` stamped now (or `at`), with `body` at bytes 10...25.
    @discardableResult
    public func appendHistory(typeId: Int, at pumpTime: UInt32? = nil, body: [UInt8]) -> UInt32 {
        let seq = lastSequence.map { $0 &+ 1 } ?? firstSequence
        historyRecords.append(Self.record(typeId: typeId, pumpTime: pumpTime ?? wallClock, sequence: seq, body: body))
        return seq
    }

    /// Raw records, kept with their own sequence numbers (records taken from a capture).
    public func loadHistory(_ records: [[UInt8]]) {
        precondition(records.allSatisfy { $0.count == 26 })
        historyRecords += records
        historyRecords.sort { readU32($0, 6) < readU32($1, 6) }
    }

    /// The oldest and newest sequence numbers held.
    public var firstHeldSequence: UInt32? { historyRecords.map { readU32($0, 6) }.min() }
    public var lastSequence: UInt32? { historyRecords.map { readU32($0, 6) }.max() }

    public static func record(typeId: Int, pumpTime: UInt32, sequence: UInt32, body: [UInt8]) -> [UInt8] {
        var r = le16(typeId) + le32(pumpTime) + le32(sequence) + body
        r += [UInt8](repeating: 0, count: max(0, 26 - r.count))
        return Array(r.prefix(26))
    }

    public static func bolusCompletedBody(
        bolusId: Int, completionStatus: Int, iob: Float, delivered: Float, requested: Float
    ) -> [UInt8] {
        le16(completionStatus) + le16(bolusId) + float(iob) + float(delivered) + float(requested)
    }

    /// A bolus started on the pump itself, as if from its own screen or before an app relaunch.
    public func startBolus(id: Int, milliunits: UInt32) {
        activeBolus = Bolus(
            id: id, requestedMilliunits: milliunits, startedAt: clock.now, cancelledAt: nil, carbs: 0, bg: 0,
            typeBitmask: 8, foodMilliunits: 0, correctionMilliunits: 0, iobMilliunits: 0)
    }

    // MARK: Bolus progress

    /// Moves an active bolus to completed when its time is up.
    func settleBolus() {
        guard let bolus = activeBolus else { return }
        let end =
            bolus.cancelledAt ?? (bolus.startedAt + Double(bolus.requestedMilliunits) / deliveryMilliunitsPerSecond)
        guard clock.now >= end else { return }
        activeBolus = nil
        completed.append(bolus)
        let delivered = deliveredMilliunits(bolus, at: end)
        appendHistory(
            typeId: BolusCompletedHistoryLog.typeId, at: wallClockAtStart &+ UInt32(end),
            body: Self.bolusCompletedBody(
                bolusId: bolus.id, completionStatus: delivered < bolus.requestedMilliunits ? 0 : 3,
                iob: Float(insulinOnBoardMilliunits) / 1000, delivered: Float(delivered) / 1000,
                requested: Float(bolus.requestedMilliunits) / 1000))
    }

    public func deliveredMilliunits(_ bolus: Bolus, at time: LinkTime? = nil) -> UInt32 {
        let t = min(time ?? clock.now, bolus.cancelledAt ?? .infinity)
        let delivered = max(0, t - bolus.startedAt) * deliveryMilliunitsPerSecond
        return min(bolus.requestedMilliunits, UInt32(delivered.rounded(.down)))
    }
}

/// The scripted pump's radio: performs the link's commands and reports what Bluetooth did.
@MainActor
public final class ScriptedTransport: LinkTransport {
    public var report: ((LinkInput) -> Void)?
    public let pump: ScriptedPump
    public let clock: ScriptClock
    public private(set) var commands: [TransportCommand] = []
    private var pendingConnect = false
    private var ended = false
    private var reassembly: [Characteristic: PacketReassembler] = [:]
    private var key: [UInt8] { Array(ScriptedPump.code.utf8) }

    public init(pump: ScriptedPump) {
        self.pump = pump
        self.clock = pump.clock
        pump.transport = self
    }

    /// What CoreBluetooth reports right after the central is created.
    public func start(restoring: Bool = false) {
        if restoring {
            report?(
                .restored([
                    RestoredPeripheral(
                        peripheralID: ScriptedPump.peripheralID, isConnected: pump.linked, name: pump.name)
                ]))
        }
        report?(.power(pump.poweredOn ? .poweredOn : .poweredOff))
    }

    public func perform(_ command: TransportCommand) {
        guard !ended else { return }
        commands.append(command)
        switch command {
        case .scan:
            if pump.inRange && pump.poweredOn {
                report?(.discovered(peripheralID: ScriptedPump.peripheralID, name: pump.name, rssi: -60))
            }
        case .connect(let id) where id == ScriptedPump.peripheralID:
            pendingConnect = true
            completeConnectIfPossible()
        case .cancelConnection:
            pendingConnect = false
            if pump.linked {
                pump.linked = false
                report?(.disconnected(peripheralID: ScriptedPump.peripheralID, nil))
            }
        case .discover(let id) where id == ScriptedPump.peripheralID:
            report?(.characteristicsDiscovered(Set(Characteristic.allCases)))
        case .subscribe(let c):
            report?(.subscription(c, isNotifying: true, failed: false))
        case .readDeviceInformation:
            report?(.deviceInformation(modelNumber: "1000354"))
        case .write(let c, let packets):
            receive(c, packets)
        default:
            break
        }
    }

    private func completeConnectIfPossible() {
        guard pendingConnect, pump.inRange, pump.poweredOn, !pump.linked else { return }
        pendingConnect = false
        pump.linked = true
        report?(.connected(peripheralID: ScriptedPump.peripheralID, name: pump.name))
    }

    // MARK: Events a test injects

    public func pumpWalksAway() {
        pump.inRange = false
        drop(code: 6)
    }

    public func pumpComesBack() {
        pump.inRange = true
        completeConnectIfPossible()
    }

    public func bluetooth(on: Bool) {
        pump.poweredOn = on
        if !on {
            pendingConnect = false
            pump.linked = false
            report?(.power(.poweredOff))
        } else {
            report?(.power(.poweredOn))
        }
    }

    public func drop(code: Int = 7) {
        guard !ended, pump.linked else { return }
        pump.linked = false
        report?(
            .disconnected(peripheralID: ScriptedPump.peripheralID, BluetoothError(domain: "CBErrorDomain", code: code)))
    }

    /// The app's process ended (a crash, or iOS killing it): this radio is gone. The pump's link to it
    /// drops, nothing more reaches the pump through it, and nothing more is reported, so a relaunch's new
    /// transport is the pump's only one.
    public func processEnded() {
        ended = true
        report = nil
        pendingConnect = false
        pump.linked = false
    }

    /// Sends the qualifying-events bitmap, as the pump does when something changes.
    public func qualifyingEvents(_ events: QualifyingEvent) {
        report?(.notified(.qualifyingEvents, le32(events.rawValue)))
    }

    // MARK: Requests

    private func receive(_ characteristic: Characteristic, _ packets: [[UInt8]]) {
        guard pump.linked else { return report?(.writeFailed(characteristic, txId: packets.first?[1])) ?? () }
        guard characteristic != .qualifyingEvents else { return }
        var reassembler = reassembly[characteristic] ?? PacketReassembler()
        var frame: [UInt8]?
        for packet in packets { frame = reassembler.ingest(packet) ?? frame }
        reassembly[characteristic] = reassembler
        guard let frame, frame.count >= 5 else { return }
        let opCode = frame[0]
        let txId = frame[1]
        let length = Int(frame[2])
        guard frame.count >= 3 + length + 2 else { return }
        var cargo = Array(frame[3..<(3 + length)])
        var signedTime: UInt32?
        if characteristic == .control, cargo.count >= 24 {
            signedTime = readU32(cargo, cargo.count - 24)
            cargo.removeLast(24)
        }
        pump.arrivals.append(
            ScriptedPump.Arrival(
                characteristic: characteristic, opCode: opCode, txId: txId, cargo: cargo, signedTime: signedTime))
        guard !pump.silent else { return }
        let key = MessageKey(characteristic: characteristic, opCode: opCode)
        let answer: ScriptedPump.Answer
        if var queued = pump.nextAnswers[key], !queued.isEmpty {
            answer = queued.removeFirst()
            pump.nextAnswers[key] = queued
        } else if let fixed = pump.answers[key] {
            answer = fixed
        } else if pump.unsupportedReads.contains(key) {
            answer = .error(code: 0, drops: true)
        } else {
            answer = .normal
        }
        if case .notice(let events) = answer { qualifyingEvents(events) }
        switch answer {
        case .silent:
            return
        case .actedWithoutReply:
            _ = respond(characteristic, opCode, cargo)
        case .drop(let acted):
            if acted { _ = respond(characteristic, opCode, cargo) }
            drop()
        case .error(let code, let drops):
            sendError(characteristic, request: opCode, code: code, txId: txId)
            if drops { _ = clock.schedule(after: 0.09) { [weak self] in self?.drop() } }
        case .cargo(let captured):
            guard let reply = respond(characteristic, opCode, cargo) else { return }
            send(type(of: reply).init(cargo: captured), txId: txId)
        case .normal, .notice:
            // A request the pump doesn't know gets BAD_OPCODE, as a real pump's does.
            guard let reply = respond(characteristic, opCode, cargo) else {
                return sendError(characteristic, request: opCode, code: 6, txId: txId)
            }
            send(reply, txId: txId)
            if characteristic == .currentStatus, opCode == HistoryLogRequest.props.opCode {
                streamHistory(start: readU32(cargo, 0), count: Int(cargo[4]))
            }
        }
    }

    /// What the pump does with a request, and the reply it makes. Nil when it has no reply for it.
    private func respond(_ c: Characteristic, _ opCode: UInt8, _ cargo: [UInt8]) -> (any ResponseMessage)? {
        pump.settleBolus()
        switch (c, opCode) {
        case (.authorization, CentralChallengeRequest.props.opCode):
            return CentralChallengeResponse(
                cargo: [0, 0] + [UInt8](repeating: 7, count: 20) + [UInt8](repeating: 9, count: 8))
        case (.authorization, PumpChallengeRequest.props.opCode):
            return PumpChallengeResponse(cargo: [0, 0, pump.rejectsPairing ? 0 : 1])
        case (.currentStatus, ApiVersionRequest.props.opCode):
            return ApiVersionResponse(cargo: le16(pump.apiVersion.major) + le16(pump.apiVersion.minor))
        case (.currentStatus, PumpVersionRequest.props.opCode):
            var v = [UInt8](repeating: 0, count: 48)
            v.replaceSubrange(0..<4, with: le32(pump.softwareVersion))
            v.replaceSubrange(4..<8, with: le32(pump.softwareVersion))
            v.replaceSubrange(16..<20, with: le32(pump.serialNumber))
            return PumpVersionResponse(cargo: v)
        case (.currentStatus, TimeSinceResetRequest.props.opCode):
            return TimeSinceResetResponse(cargo: le32(pump.wallClock) + le32(pump.uptime))
        case (.currentStatus, ControlIQIOBRequest.props.opCode):
            var v = [UInt8](repeating: 0, count: 17)
            v.replaceSubrange(0..<4, with: le32(pump.insulinOnBoardMilliunits))
            v.replaceSubrange(12..<16, with: le32(pump.insulinOnBoardMilliunits))
            return ControlIQIOBResponse(cargo: v)
        case (.currentStatus, BolusCalcDataSnapshotRequest.props.opCode):
            var v = [UInt8](repeating: 0, count: 46)
            v.replaceSubrange(1..<3, with: le16(pump.correctionFactor))
            v.replaceSubrange(3..<7, with: le32(pump.calculatorInsulinOnBoardMilliunits))
            v.replaceSubrange(7..<9, with: le16(pump.reservoirUnits))
            v.replaceSubrange(9..<11, with: le16(pump.targetMgdl))
            v.replaceSubrange(11..<13, with: le16(pump.correctionFactor))
            v[13] = 1
            v.replaceSubrange(14..<18, with: le32(pump.carbRatioMilli))
            v.replaceSubrange(18..<20, with: le16(pump.maxBolusMilliunits))
            return BolusCalcDataSnapshotResponse(cargo: v)
        case (.currentStatus, InsulinStatusRequest.props.opCode):
            return InsulinStatusResponse(cargo: le16(pump.reservoirUnits) + [0, 20])
        case (.currentStatus, CurrentBatteryV2Request.props.opCode):
            var v = [UInt8](repeating: 0, count: 11)
            v[0] = UInt8(pump.batteryPercent)
            v[1] = UInt8(pump.batteryPercent)
            v[2] = pump.charging ? 1 : 0
            return CurrentBatteryV2Response(cargo: v)
        case (.currentStatus, CurrentEGVGuiDataRequest.props.opCode):
            guard let g = pump.glucose else { return CurrentEGVGuiDataResponse(cargo: [UInt8](repeating: 0, count: 8)) }
            let at = UInt32(max(0, Double(pump.wallClock) - g.ageSeconds))
            return CurrentEGVGuiDataResponse(cargo: le32(at) + le16(g.mgdl) + [1, 0])
        case (.currentStatus, HomeScreenMirrorRequest.props.opCode):
            var v = [UInt8](repeating: 0, count: 9)
            v[0] = UInt8(pump.trendIcon)
            return HomeScreenMirrorResponse(cargo: v)
        case (.currentStatus, CurrentBasalStatusRequest.props.opCode):
            return CurrentBasalStatusResponse(
                cargo: le32(pump.basalMilliunitsPerHour) + le32(pump.basalMilliunitsPerHour) + [0])
        case (.currentStatus, BasalLimitSettingsRequest.props.opCode):
            return BasalLimitSettingsResponse(cargo: le32(3000) + le32(3000))
        case (.currentStatus, ControlIQInfoV2Request.props.opCode):
            var v = [UInt8](repeating: 0, count: 19)
            v[0] = pump.controlIQEnabled ? 1 : 0
            return ControlIQInfoV2Response(cargo: v)
        case (.currentStatus, CGMHardwareInfoRequest.props.opCode):
            var v = Array(pump.cgmHardwareInfo.utf8.prefix(16))
            v += [UInt8](repeating: 0, count: 17 - v.count)
            return CGMHardwareInfoResponse(cargo: v)
        case (.currentStatus, CGMStatusRequest.props.opCode):
            return CGMStatusResponse(cargo: [1] + [UInt8](repeating: 0, count: 9))
        case (.currentStatus, LoadStatusRequest.props.opCode):
            return LoadStatusResponse(cargo: [0, pump.cartridgeLoaded ? 6 : 0, 0])
        case (.currentStatus, AlertStatusRequest.props.opCode):
            return AlertStatusResponse(cargo: le64(pump.alertBitmap))
        case (.currentStatus, AlarmStatusRequest.props.opCode):
            return AlarmStatusResponse(cargo: le64(pump.alarmBitmap))
        case (.currentStatus, CGMAlertStatusRequest.props.opCode):
            return CGMAlertStatusResponse(cargo: le64(pump.cgmAlertBitmap))
        case (.currentStatus, ReminderStatusRequest.props.opCode):
            return ReminderStatusResponse(cargo: le64(pump.reminderBitmap))
        case (.currentStatus, MalfunctionStatusRequest.props.opCode):
            return MalfunctionBitmaskStatusResponse(cargo: le64(pump.malfunctionBitmap))
        case (.currentStatus, CurrentBolusStatusRequest.props.opCode):
            var v = [UInt8](repeating: 0, count: 15)
            if let b = pump.activeBolus {
                v[0] = 1
                v.replaceSubrange(1..<3, with: le16(b.id))
                v.replaceSubrange(9..<13, with: le32(b.requestedMilliunits))
            }
            return CurrentBolusStatusResponse(cargo: v)
        case (.currentStatus, LastBolusStatusV2Request.props.opCode):
            var v = [UInt8](repeating: 0, count: 24)
            if let b = pump.completed.last {
                v.replaceSubrange(1..<3, with: le16(b.id))
                v.replaceSubrange(5..<9, with: le32(pump.wallClockAtStart &+ UInt32(b.startedAt)))
                v.replaceSubrange(9..<13, with: le32(pump.deliveredMilliunits(b)))
                v.replaceSubrange(20..<24, with: le32(b.requestedMilliunits))
            }
            return LastBolusStatusV2Response(cargo: v)
        case (.currentStatus, HistoryLogStatusRequest.props.opCode):
            let count = UInt32(pump.historyRecords.count)
            return HistoryLogStatusResponse(
                cargo: le32(count) + le32(pump.firstHeldSequence ?? 0) + le32(pump.lastSequence ?? 0))
        case (.currentStatus, HistoryLogRequest.props.opCode):
            return HistoryLogResponse(cargo: [0, 1])

        case (.control, BolusPermissionRequest.props.opCode):
            guard pump.cartridgeLoaded, pump.activeBolus == nil else {
                return BolusPermissionResponse(cargo: [1, 0, 0, 0, 0, 1])
            }
            let id = pump.nextBolusId
            pump.nextBolusId += 1
            pump.grantedPermission = id
            return BolusPermissionResponse(cargo: [0] + le16(id) + [0, 0, 0])
        case (.control, BolusPermissionReleaseRequest.props.opCode):
            let id = readU16(cargo, 0)
            guard pump.grantedPermission == id else { return BolusPermissionReleaseResponse(cargo: [1]) }
            pump.grantedPermission = nil
            pump.released.append(id)
            return BolusPermissionReleaseResponse(cargo: [0])
        case (.control, RemoteBgEntryRequest.props.opCode):
            return RemoteBgEntryResponse(cargo: [0])
        case (.control, RemoteCarbEntryRequest.props.opCode):
            return RemoteCarbEntryResponse(cargo: [0])
        case (.control, InitiateBolusRequest.props.opCode):
            let total = readU32(cargo, 0)
            let id = readU16(cargo, 4)
            guard pump.grantedPermission == id, pump.activeBolus == nil else {
                return InitiateBolusResponse(cargo: [1] + le16(id) + [0, 0, 1])
            }
            pump.grantedPermission = nil
            pump.activeBolus = ScriptedPump.Bolus(
                id: id, requestedMilliunits: total, startedAt: clock.now, cancelledAt: nil,
                carbs: readU16(cargo, 17), bg: readU16(cargo, 19), typeBitmask: Int(cargo[8]),
                foodMilliunits: readU32(cargo, 9), correctionMilliunits: readU32(cargo, 13),
                iobMilliunits: readU32(cargo, 21))
            return InitiateBolusResponse(cargo: [0] + le16(id) + [0, 0, 0])
        case (.control, CancelBolusRequest.props.opCode):
            let id = readU16(cargo, 0)
            guard var b = pump.activeBolus, b.id == id else {
                return CancelBolusResponse(cargo: [1] + le16(id) + [2, 0])
            }
            b.cancelledAt = clock.now
            pump.activeBolus = b
            pump.settleBolus()
            return CancelBolusResponse(cargo: [0] + le16(id) + [0, 0])
        case (.control, DismissNotificationRequest.props.opCode):
            let id = Int(readU32(cargo, 0))
            if pump.dismissLeavesAlert { return DismissNotificationResponse(cargo: [0]) }
            switch cargo[4] {
            case 0: pump.reminderBitmap &= ~(1 << UInt64(id))
            case 1: pump.alertBitmap &= ~(1 << UInt64(id))
            case 2: pump.alarmBitmap &= ~(1 << UInt64(id))
            default: pump.cgmAlertBitmap &= ~(1 << UInt64(id))
            }
            return DismissNotificationResponse(cargo: [0])
        default:
            return nil
        }
    }

    private func streamHistory(start: UInt32, count: Int) {
        let records = pump.historyRecords.filter {
            let seq = readU32($0, 6)
            return seq >= start && seq < start &+ UInt32(count)
        }
        var i = 0
        while i < records.count {
            let chunk = Array(records[i..<min(i + pump.recordsPerFrame, records.count)])
            send(HistoryLogStreamResponse(cargo: [UInt8(chunk.count), 1] + chunk.flatMap { $0 }), txId: 0)
            i += chunk.count
        }
    }

    private func send(_ message: any ResponseMessage, txId: UInt8) {
        let signed = message.signed
        // swiftlint:disable:next force_try - the pump's replies are well-formed
        let packets = try! Packetize.packetize(
            message, authenticationKey: signed ? key : [], txId: txId, pumpTimeSinceReset: pump.wallClock,
            maxChunkSize: 18)
        for packet in packets { report?(.notified(message.characteristic, packet.build())) }
    }

    /// An op-77, on the request's characteristic. On CONTROL the pump signs it.
    private func sendError(_ c: Characteristic, request: UInt8, code: UInt8, txId: UInt8) {
        let cargo: [UInt8] = c == .control ? [request, code] : [0, code]
        var frame: [UInt8] = [ErrorResponse.props.opCode, txId, UInt8(cargo.count + (c == .control ? 24 : 0))] + cargo
        if c == .control {
            let time = le32(pump.wallClock)
            let hmac = Packetize.doHmacSha1(frame + time, key: key)
            frame += time + hmac
        }
        frame += Bytes.calculateCRC16(frame)
        let chunks = stride(from: 0, to: frame.count, by: 18).map { Array(frame[$0..<min($0 + 18, frame.count)]) }
        for (n, chunk) in chunks.enumerated() { report?(.notified(c, [UInt8(chunks.count - 1 - n), txId] + chunk)) }
    }
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
func float(_ v: Float) -> [UInt8] { le32(v.bitPattern) }
func readU16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
func readU32(_ b: [UInt8], _ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[i + $1]) << (8 * UInt32($1)) } }
