import Foundation
import TandemAuth
import TandemBLE
import TandemLink
import TandemMessages

/// A t:slim X2 and its radio, as CoreBluetooth would report them, for running the real session and link
/// with no pump. It pairs with the legacy 16-character code, or with J-PAKE on a 6-digit code
/// (`jpakeCode`), answers the handshake, the status reads the
/// session makes, the signed bolus writes and the history log, and keeps a bolus engine: a granted
/// permission, an initiated bolus that waits `pendingSeconds` and then delivers at
/// `deliveryMilliunitsPerSecond` of clock time, cancel, a stop on the pump, release, and the history
/// records a t:slim writes for each step. Every reply is framed and signed as the pump's would be,
/// so the link's checks run on it unchanged.
///
/// Faults are set per request (`answers`): a captured reply in place of the scripted one, an op-77 with
/// or without a drop, silence, a drop before or after the pump acts on the request, or a damaged reply (a
/// bad CRC or signature, another request's txId, or the reply twice). With `raisesNotices` the pump also
/// sends a qualifying-events notice for each of its own changes.
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
    /// A 6-digit pump, as P2 is: it pairs with J-PAKE on this code. Nil for a legacy pump.
    public var jpakeCode: String?
    /// The secret the pump keeps from its last J-PAKE pairing. A reconnect (rounds 3 and 4 only) must
    /// confirm with it, and any other is refused.
    public var jpakeSecret: [UInt8]?

    /// The pump's wall clock (seconds since 2008, local) at clock time 0, as TimeSinceReset's
    /// `currentTime` reports it and history records are stamped.
    public var wallClockAtStart: UInt32 = 512_442_842
    /// Seconds since the pump booted, at clock time 0 (TimeSinceReset's `pumpTimeSinceReset`).
    public var uptimeAtStart: UInt32 = 1_905_413

    // MARK: Readings

    public var insulinOnBoardMilliunits: UInt32 = 500
    public var reservoirUnits = 150 { didSet { if reservoirUnits != oldValue { notice(.remainingInsulin) } } }
    public var batteryPercent = 80 { didSet { if batteryPercent != oldValue { notice(.battery) } } }
    public var charging = false
    public var carbRatioMilli: UInt32 = 10_000
    public var correctionFactor = 40
    public var targetMgdl = 110
    public var maxBolusMilliunits = 25_000
    /// The IOB the calculator reply itself reports (op-115).
    public var calculatorInsulinOnBoardMilliunits: UInt32 = 500
    /// The CGM reading and how long before now it was measured, or nil for none.
    public var glucose: (mgdl: Int, ageSeconds: Double)? = (120, 60) {
        didSet {
            if glucose?.mgdl != oldValue?.mgdl || glucose?.ageSeconds != oldValue?.ageSeconds { notice(.cgmChange) }
        }
    }
    /// The home-screen trend icon id (4 is flat, 0 no arrow).
    public var trendIcon = 4
    public var cgmHardwareInfo = "8KX21P"
    public var basalMilliunitsPerHour: UInt32 = 800
    public var controlIQEnabled = false
    public var alertBitmap: UInt64 = 0 { didSet { if alertBitmap != oldValue { notice(.alert) } } }
    public var alarmBitmap: UInt64 = 0 { didSet { if alarmBitmap != oldValue { notice(.alarm) } } }
    public var cgmAlertBitmap: UInt64 = 0 { didSet { if cgmAlertBitmap != oldValue { notice(.cgmAlert) } } }
    public var reminderBitmap: UInt64 = 0 { didSet { if reminderBitmap != oldValue { notice(.reminder) } } }
    public var malfunctionBitmap: UInt64 = 0 {
        didSet { if malfunctionBitmap != oldValue { notice(.malfunction) } }
    }
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
        /// The pump acts, and its reply arrives with its CRC broken.
        case badCRC
        /// The pump acts, and its signed reply carries a signature made with another key. Only for a
        /// request whose reply is signed.
        case badSignature
        /// The pump acts, and its reply carries a txId no request uses: the request's with its top bit
        /// flipped, so it can't be matched to another request in flight.
        case wrongTxId
        /// The pump acts once, and its reply arrives twice.
        case duplicate
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

    // MARK: Notices

    /// Send a qualifying-events notice for each of the pump's own changes: an alert, alarm, reminder,
    /// CGM-alert or malfunction bitmap set or cleared (its own bit), a bolus accepted, starting to deliver
    /// or ending (bolus change), a new reading (CGM change), the battery (battery) and the reservoir
    /// (remaining insulin). Off by default: which bit a t:slim raises for which change is unconfirmed, and
    /// a pump that raises none is the worst case the session's timed reads must cover. A change made while
    /// answering a request (a cancel, a dismiss) sends its notice before that reply; that order is
    /// unconfirmed too. A bolus's start and end are timed at its acceptance, at the rate then.
    public var raisesNotices = false
    /// The notices sent because of `raisesNotices`, in order.
    public private(set) var noticesSent: [QualifyingEvent] = []

    func notice(_ events: QualifyingEvent) {
        guard raisesNotices, let transport else { return }
        noticesSent.append(events)
        transport.qualifyingEvents(events)
    }

    // MARK: Bolus engine

    public struct Bolus: Sendable, Equatable {
        public let id: Int
        public let requestedMilliunits: UInt32
        /// When the pump accepted it, or when it started on the pump.
        public let startedAt: LinkTime
        /// When insulin starts to flow: after the pending phase for a remote bolus.
        public let deliversFrom: LinkTime
        /// Set when something ends it before it delivers everything.
        public var stop: Stop?
        /// How it ended, once it has.
        public var ended: Stop?
        /// CurrentBolusStatus's source byte: 8 for a remote bolus, as in the capture of bolus 3; 0 for one
        /// started on the pump, unconfirmed.
        public let source: UInt8
        /// Whether the records for the start of delivery are written.
        public var deliveryRecorded = false
        public let carbs: Int
        public let bg: Int
        public let typeBitmask: Int
        public let foodMilliunits: UInt32
        public let correctionMilliunits: UInt32
        public let iobMilliunits: UInt32
    }

    /// When a bolus ends, or is to end, and the completion status the pump records for it.
    public struct Stop: Sendable, Equatable {
        public let at: LinkTime
        public let completionStatus: Int
    }

    /// The completion status in a bolus's completed record. Only `delivered` is recorded on a t:slim (the
    /// capture of bolus 3); the others are unconfirmed (docs/UNVERIFIED-GUESSES.md #19), so a test that
    /// depends on them tests a guess.
    public enum CompletionStatus {
        public static let delivered = 3
        public static let cancelledFromPhone = 4
        public static let stoppedOnPump = 0
        public static let alarm = 1
        public static let malfunction = 2
    }

    public var nextBolusId = 10650
    /// 1 U per 40 s, the rate of the one recorded t:slim bolus (bolus 3: activated at pump time
    /// 0x1A8E638A, completed 40 s later). A test that doesn't time delivery can raise it.
    public var deliveryMilliunitsPerSecond: Double = 25
    /// How long an accepted remote bolus stays pending (CurrentBolusStatus 2) before it delivers: 15 s in
    /// the capture of bolus 3, between its initiate records and its activated record.
    public var pendingSeconds: Double = 15
    /// The pump drops a pending bolus instead of delivering it: nothing goes in, and its status read
    /// stops naming it. Unconfirmed: no record shows how a t:slim does this.
    public var dropsPendingBolus = false

    /// How long a remote bolus of `milliunits` takes from acceptance to its end: the pending phase, then
    /// delivery at the current rate.
    public func deliverySeconds(milliunits: UInt32) -> Double {
        pendingSeconds + Double(milliunits) / deliveryMilliunitsPerSecond
    }
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

    /// Appends a 26-byte history record of `typeId` stamped now (or `at`), with `body` at bytes 10...25,
    /// after the records the bolus engine has due by now, so sequence numbers follow pump time.
    @discardableResult
    public func appendHistory(typeId: Int, at pumpTime: UInt32? = nil, body: [UInt8]) -> UInt32 {
        settleBolus()
        return append(typeId: typeId, at: pumpTime, body: body)
    }

    @discardableResult
    private func append(typeId: Int, at pumpTime: UInt32? = nil, body: [UInt8]) -> UInt32 {
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

    /// A bolus started on the pump itself, as if from its own screen or before an app relaunch. It delivers
    /// at once, with no pending phase and no initiate or requested records.
    public func startBolus(id: Int, milliunits: UInt32) {
        activeBolus = Bolus(
            id: id, requestedMilliunits: milliunits, startedAt: clock.now, deliversFrom: clock.now, source: 0,
            carbs: 0, bg: 0, typeBitmask: 8, foodMilliunits: 0, correctionMilliunits: 0, iobMilliunits: 0)
        notice(.bolusChange)
        scheduleBolusSteps()
        settleBolus()
    }

    /// Ends the active bolus now, as an alarm, a malfunction or a stop on the pump's own screen does, with
    /// that completion status (see `CompletionStatus`), and raises `alarmBit` in the alarm bitmap.
    public func stopBolus(completionStatus: Int, alarmBit: Int? = nil) {
        if let alarmBit { alarmBitmap |= 1 << UInt64(alarmBit) }
        settleBolus()
        guard var bolus = activeBolus else { return }
        bolus.stop = Stop(at: clock.now, completionStatus: completionStatus)
        activeBolus = bolus
        settleBolus()
    }

    // MARK: Bolus progress

    /// Accepts a remote bolus: it goes pending, and the pump writes its initiate and requested records.
    func acceptBolus(_ bolus: Bolus) {
        activeBolus = bolus
        append(typeId: IobSnapshotPreBolusHistoryLog.typeId, body: iobSnapshotBody(bolus))
        for (typeId, body) in Self.requestRecords(bolus, at: wallClock) { append(typeId: typeId, body: body) }
        if dropsPendingBolus {
            activeBolus?.stop = Stop(at: bolus.deliversFrom, completionStatus: CompletionStatus.stoppedOnPump)
        }
        notice(.bolusChange)
        scheduleBolusSteps()
    }

    /// With `raisesNotices`, settles the active bolus when it starts to deliver and when it's due to end,
    /// so its notices go out then rather than on the next request.
    private func scheduleBolusSteps() {
        guard raisesNotices, let bolus = activeBolus else { return }
        let fullEnd = bolus.deliversFrom + Double(bolus.requestedMilliunits) / deliveryMilliunitsPerSecond
        for due in [bolus.deliversFrom, fullEnd] where due > clock.now {
            _ = clock.schedule(after: due - clock.now) { [weak self] in self?.settleBolus() }
        }
    }

    /// Writes what has happened to the active bolus by now: the start of delivery, then its end, when it
    /// moves to `completed`.
    func settleBolus() {
        guard var bolus = activeBolus else { return }
        let fullEnd = bolus.deliversFrom + Double(bolus.requestedMilliunits) / deliveryMilliunitsPerSecond
        let end = min(bolus.stop?.at ?? fullEnd, fullEnd)
        if !bolus.deliveryRecorded, clock.now >= bolus.deliversFrom, end > bolus.deliversFrom {
            bolus.deliveryRecorded = true
            activeBolus = bolus
            let at = wallClockAtStart &+ UInt32(bolus.deliversFrom)
            append(typeId: BolusActivatedHistoryLog.typeId, at: at, body: Self.activatedBody(bolus))
            append(typeId: BolusDeliveryHistoryLog.typeId, at: at, body: Self.deliveryBody(bolus, delivered: nil))
            notice(.bolusChange)
        }
        guard clock.now >= end else { return }
        let status =
            end < fullEnd
            ? (bolus.stop?.completionStatus ?? CompletionStatus.stoppedOnPump) : CompletionStatus.delivered
        bolus.ended = Stop(at: end, completionStatus: status)
        activeBolus = nil
        completed.append(bolus)
        let delivered = deliveredMilliunits(bolus, at: end)
        let at = wallClockAtStart &+ UInt32(end)
        if bolus.deliveryRecorded {
            append(typeId: BolusDeliveryHistoryLog.typeId, at: at, body: Self.deliveryBody(bolus, delivered: delivered))
            append(typeId: IobSnapshotPostBolusHistoryLog.typeId, at: at, body: iobSnapshotBody(bolus))
        }
        append(
            typeId: BolusCompletedHistoryLog.typeId, at: at,
            body: Self.bolusCompletedBody(
                bolusId: bolus.id, completionStatus: status, iob: Float(insulinOnBoardMilliunits) / 1000,
                delivered: Float(delivered) / 1000, requested: Float(bolus.requestedMilliunits) / 1000))
        notice(.bolusChange)
    }

    public func deliveredMilliunits(_ bolus: Bolus, at time: LinkTime? = nil) -> UInt32 {
        let t = min(time ?? clock.now, bolus.stop?.at ?? .infinity)
        let delivered = max(0, t - bolus.deliversFrom) * deliveryMilliunitsPerSecond
        return min(bolus.requestedMilliunits, UInt32(delivered.rounded(.down)))
    }

    // MARK: Bolus records

    // The records a t:slim writes for a remote bolus, in the layout and order of the capture of bolus 3
    // (Captures.swift): at the request the pre-bolus IOB snapshot (206), requested (64, 65, 66), a
    // permission change (295) and the initiate records (292, 293, 343, 298); when delivery starts,
    // activated (55) and delivery (280); at the end a second 280, the post-bolus IOB snapshot (207) and
    // completed (20). The bolus ID, amounts, carbs, BG and times follow the request; a constant byte is the
    // capture's value and its meaning is unconfirmed, as is every field that bolus left at 0.

    static func requestRecords(_ b: Bolus, at requestTime: UInt32) -> [(Int, [UInt8])] {
        let iob = Float(b.iobMilliunits) / 1000
        return [
            (
                BolusRequestedMsg1HistoryLog.typeId,
                le16(b.id) + [3, b.correctionMilliunits > 0 ? 1 : 0] + le16(b.carbs) + le16(b.bg) + float(iob)
                    + le32(0)
            ),
            (
                BolusRequestedMsg2HistoryLog.typeId,
                le16(b.id) + [4, 100] + le16(0) + le16(0) + le16(0) + le16(0) + [1, 0, 1, 0]
            ),
            (
                BolusRequestedMsg3HistoryLog.typeId,
                le16(b.id) + le16(0) + float(Float(b.foodMilliunits) / 1000)
                    + float(Float(b.correctionMilliunits) / 1000) + float(Float(b.requestedMilliunits) / 1000)
            ),
            (BolusPermissionChangeHistoryLog.typeId, le16(b.id) + [0, 1, 1]),
            (
                InitiateBolusRequestMsg1HistoryLog.typeId,
                le32(requestTime) + [0, UInt8(b.typeBitmask & 0xFF)] + le16(b.id) + le32(b.requestedMilliunits)
                    + le32(b.foodMilliunits)
            ),
            (
                InitiateBolusRequestMsg2HistoryLog.typeId,
                [0, 0] + le16(b.id) + le32(b.correctionMilliunits) + le32(0) + le16(b.carbs) + le16(b.bg)
            ),
            (
                InitiateBolusRequestMsg3HistoryLog.typeId,
                [0, 0] + le16(b.id) + le32(b.iobMilliunits) + le32(0) + le32(0)
            ),
            (InitiateBolusResponseHistoryLog.typeId, le16(b.id))
        ]
    }

    func iobSnapshotBody(_ b: Bolus) -> [UInt8] {
        let iob = Float(insulinOnBoardMilliunits) / 1000
        return le16(b.id) + [2, 1] + float(iob) + float(iob) + float(iob)
    }

    static func activatedBody(_ b: Bolus) -> [UInt8] {
        le16(b.id) + [1, 0] + float(Float(b.iobMilliunits) / 1000) + float(Float(b.requestedMilliunits) / 1000)
    }

    /// A delivery record: started (status 1) or, with `delivered`, ended (status 0).
    static func deliveryBody(_ b: Bolus, delivered: UInt32?) -> [UInt8] {
        le16(b.id) + [delivered == nil ? 1 : 0, 5, b.source, UInt8(b.id & 0xFF)] + le16(Int(b.requestedMilliunits))
            + le16(0) + le16(Int(b.correctionMilliunits)) + le16(0) + le16(Int(delivered ?? 0))
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
    /// The signing key: the legacy code's bytes, or the key the connection's J-PAKE handshake derived.
    private var key: [UInt8] { sessionKey ?? Array(ScriptedPump.code.utf8) }
    private var sessionKey: [UInt8]?
    private var jpake: JpakeExchange?

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
                endLink()
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

    /// The link is gone: the connection's J-PAKE session key and any handshake in progress go with it.
    private func endLink() {
        pump.linked = false
        sessionKey = nil
        jpake = nil
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
            endLink()
            report?(.power(.poweredOff))
        } else {
            report?(.power(.poweredOn))
        }
    }

    public func drop(code: Int = 7) {
        guard !ended, pump.linked else { return }
        endLink()
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
        endLink()
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
        if characteristic == .authorization, Self.jpakeOpCodes.contains(opCode) {
            return answerJpake(opCode, cargo, txId: txId, answer: answer)
        }
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
        case .normal, .notice, .badCRC, .badSignature, .wrongTxId, .duplicate:
            // A request the pump doesn't know gets BAD_OPCODE, as a real pump's does.
            guard let reply = respond(characteristic, opCode, cargo) else {
                return sendError(characteristic, request: opCode, code: 6, txId: txId)
            }
            send(reply, txId: txId, fault: answer)
            if characteristic == .currentStatus, opCode == HistoryLogRequest.props.opCode {
                streamHistory(start: readU32(cargo, 0), count: Int(cargo[4]))
            }
        }
    }

    /// What the pump does with a request, and the reply it makes. Nil when it has no reply for it.
    private func respond(_ c: Characteristic, _ opCode: UInt8, _ cargo: [UInt8]) -> (any ResponseMessage)? {
        pump.settleBolus()
        switch (c, opCode) {
        // A 6-digit pump doesn't answer the legacy pairing (unconfirmed: it may answer differently).
        case (.authorization, _) where pump.jpakeCode != nil:
            return nil
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
            // The capture of bolus 3's layout: status 2 while pending, then 1, the request's time and then the
            // delivery start's at 5, the request at 9, source 8 and the type bits at 13 and 14.
            var v = [UInt8](repeating: 0, count: 15)
            if let b = pump.activeBolus {
                let pending = clock.now < b.deliversFrom
                v[0] = pending ? 2 : 1
                v.replaceSubrange(1..<3, with: le16(b.id))
                v.replaceSubrange(
                    5..<9, with: le32(pump.wallClockAtStart &+ UInt32(pending ? b.startedAt : b.deliversFrom)))
                v.replaceSubrange(9..<13, with: le32(b.requestedMilliunits))
                v[13] = b.source
                v[14] = UInt8(b.typeBitmask & 0xFF)
            }
            return CurrentBolusStatusResponse(cargo: v)
        case (.currentStatus, LastBolusStatusV2Request.props.opCode):
            // The capture of bolus 3's layout: the time it ended at 5, the completion status at 13, the
            // source and type bits at 14 and 15.
            var v = [UInt8](repeating: 0, count: 24)
            if let b = pump.completed.last, let ended = b.ended {
                v[0] = 1
                v.replaceSubrange(1..<3, with: le16(b.id))
                v.replaceSubrange(5..<9, with: le32(pump.wallClockAtStart &+ UInt32(ended.at)))
                v.replaceSubrange(9..<13, with: le32(pump.deliveredMilliunits(b)))
                v[13] = UInt8(ended.completionStatus & 0xFF)
                v[14] = b.source
                v[15] = UInt8(b.typeBitmask & 0xFF)
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
            pump.acceptBolus(
                ScriptedPump.Bolus(
                    id: id, requestedMilliunits: total, startedAt: clock.now,
                    deliversFrom: clock.now + pump.pendingSeconds, source: 8, carbs: readU16(cargo, 17),
                    bg: readU16(cargo, 19), typeBitmask: Int(cargo[8]), foodMilliunits: readU32(cargo, 9),
                    correctionMilliunits: readU32(cargo, 13), iobMilliunits: readU32(cargo, 21)))
            return InitiateBolusResponse(cargo: [0] + le16(id) + [0, 0, 0])
        case (.control, CancelBolusRequest.props.opCode):
            let id = readU16(cargo, 0)
            guard var b = pump.activeBolus, b.id == id else {
                return CancelBolusResponse(cargo: [1] + le16(id) + [2, 0])
            }
            b.stop = ScriptedPump.Stop(
                at: clock.now, completionStatus: ScriptedPump.CompletionStatus.cancelledFromPhone)
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

    /// Frames, signs and reports a reply, damaged as `fault` says.
    private func send(_ message: any ResponseMessage, txId: UInt8, fault: ScriptedPump.Answer = .normal) {
        var signingKey = message.signed ? key : []
        var replyTxId = txId
        switch fault {
        case .badSignature:
            precondition(message.signed, "badSignature is for a request whose reply is signed")
            signingKey = signingKey.reversed()
        case .wrongTxId: replyTxId = txId ^ 0x80
        default: break
        }
        // swiftlint:disable:next force_try - the pump's replies are well-formed
        var packets = try! Packetize.packetize(
            message, authenticationKey: signingKey, txId: replyTxId, pumpTimeSinceReset: pump.wallClock,
            maxChunkSize: 18
        ).map { $0.build() }
        if case .badCRC = fault, var last = packets.popLast(), !last.isEmpty {
            last[last.count - 1] ^= 0xFF
            packets.append(last)
        }
        let copies = if case .duplicate = fault { 2 } else { 1 }
        for _ in 0..<copies {
            for packet in packets { report?(.notified(message.characteristic, packet)) }
        }
    }

    // MARK: J-PAKE

    /// The pump side of the 6-digit pairing, against TandemKit's client: EC-JPAKE rounds 1a, 1b and 2
    /// (secp256r1, the code as the shared secret), then the session key (a nonce) and key confirmation
    /// (HMAC-SHA256 with HKDF(nonce, secret)), whose key then signs every reply. The layout follows the
    /// client's; what a t:slim checks and answers when a round or the confirmation fails is unconfirmed,
    /// so this pump answers a failed confirmation with one that can't verify.
    private final class JpakeExchange {
        let context: EcJpakeContext?
        var clientRound1a: [UInt8] = []
        var pumpRound1b: [UInt8] = []
        var derivedSecret: [UInt8]?
        var serverNonce: [UInt8]?
        init(context: EcJpakeContext?) { self.context = context }
    }

    private static let jpakeOpCodes: Set<UInt8> = [
        Jpake1aRequest.props.opCode, Jpake1bRequest.props.opCode, Jpake2Request.props.opCode,
        Jpake3SessionKeyRequest.props.opCode, Jpake4KeyConfirmationRequest.props.opCode
    ]

    private func answerJpake(_ opCode: UInt8, _ cargo: [UInt8], txId: UInt8, answer: ScriptedPump.Answer) {
        switch answer {
        case .silent:
            return
        case .drop(let acted):
            if acted { _ = jpakeReply(opCode, cargo) }
            return drop()
        case .actedWithoutReply:
            _ = jpakeReply(opCode, cargo)
        case .error(let code, let drops):
            sendError(.authorization, request: opCode, code: code, txId: txId)
            if drops { _ = clock.schedule(after: 0.09) { [weak self] in self?.drop() } }
        case .cargo, .badCRC, .badSignature, .wrongTxId, .duplicate:
            preconditionFailure("this fault isn't modelled for a J-PAKE request")
        case .normal, .notice:
            guard let (replyOpCode, payload) = jpakeReply(opCode, cargo) else {
                return sendError(.authorization, request: opCode, code: 6, txId: txId)
            }
            sendFrame(.authorization, opCode: replyOpCode, txId: txId, cargo: [0, 0] + payload)
        }
    }

    /// What the pump does with a J-PAKE request, and its reply's opcode and payload (after the app
    /// instance ID). Nil when it has nothing to answer with.
    private func jpakeReply(_ opCode: UInt8, _ cargo: [UInt8]) -> (UInt8, [UInt8])? {
        // Every request's cargo is the app instance ID (2 bytes), then its payload.
        let payload = Array(cargo.dropFirst(2))
        do {
            switch opCode {
            case Jpake1aRequest.props.opCode:
                guard let code = pump.jpakeCode else { return nil }
                let context = try EcJpakeContext(role: .server, secret: JpakeAuth.pairingCodeToBytes(code))
                let round1 = try context.writeRoundOne()
                let half = Self.keyKPLength(round1)
                let exchange = JpakeExchange(context: context)
                exchange.clientRound1a = Array(payload.prefix(165))
                exchange.pumpRound1b = Array(round1[half...])
                jpake = exchange
                return (33, Array(round1[..<half]))
            case Jpake1bRequest.props.opCode:
                guard let exchange = jpake, let context = exchange.context else { return nil }
                try context.readRoundOne(exchange.clientRound1a + payload.prefix(165))
                return (35, exchange.pumpRound1b)
            case Jpake2Request.props.opCode:
                guard let exchange = jpake, let context = exchange.context else { return nil }
                let round2 = try context.writeRoundTwo()
                try context.readRoundTwo(Array(payload.prefix(165)))
                exchange.derivedSecret = try context.deriveSecret()
                return (37, round2)
            case Jpake3SessionKeyRequest.props.opCode:
                // A finished full pairing continues its exchange; a reconnect starts here, with the kept
                // secret, and so does a full pairing that never reached its derived secret.
                let ongoing = jpake.flatMap { $0.context == nil || $0.derivedSecret != nil ? $0 : nil }
                let exchange = ongoing ?? JpakeExchange(context: nil)
                let nonce = Self.randomBytes(8)
                exchange.serverNonce = nonce
                jpake = exchange
                return (39, nonce + [UInt8](repeating: 0, count: 8))
            case Jpake4KeyConfirmationRequest.props.opCode:
                guard let exchange = jpake, let serverNonce = exchange.serverNonce else { return nil }
                jpake = nil
                let clientNonce = Array(payload.prefix(8))
                let clientHash = Array(payload.dropFirst(16).prefix(32))
                let nonce4 = Self.randomBytes(8)
                let reserved = [UInt8](repeating: 0, count: 8)
                guard let secret = exchange.derivedSecret ?? pump.jpakeSecret else {
                    return (41, nonce4 + reserved + [UInt8](repeating: 0, count: 32))
                }
                let key = Crypto.hkdf(nonce: serverNonce, keyMaterial: secret)
                guard Crypto.isValidHmacSha256(mac: clientHash, data: clientNonce, key: key) else {
                    return (41, nonce4 + reserved + [UInt8](repeating: 0, count: 32))
                }
                pump.jpakeSecret = secret
                sessionKey = key
                return (41, nonce4 + reserved + Crypto.hmacSha256(data: nonce4, key: key))
            default:
                return nil
            }
        } catch {
            jpake = nil
            return nil
        }
    }

    /// The length of the first KeyKP in an EC-JPAKE round: three length-prefixed fields (X, V, r).
    private static func keyKPLength(_ round: [UInt8]) -> Int {
        var i = 0
        for _ in 0..<3 { i += 1 + Int(round[i]) }
        return i
    }

    private static func randomBytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    /// A frame of `cargo` (with any signed trailer already in it) and its CRC, in 18-byte packets.
    private func sendFrame(_ c: Characteristic, opCode: UInt8, txId: UInt8, cargo: [UInt8]) {
        var frame: [UInt8] = [opCode, txId, UInt8(cargo.count)] + cargo
        frame += Bytes.calculateCRC16(frame)
        let chunks = stride(from: 0, to: frame.count, by: 18).map { Array(frame[$0..<min($0 + 18, frame.count)]) }
        for (n, chunk) in chunks.enumerated() { report?(.notified(c, [UInt8(chunks.count - 1 - n), txId] + chunk)) }
    }

    /// An op-77, on the request's characteristic. On CONTROL the pump signs it.
    private func sendError(_ c: Characteristic, request: UInt8, code: UInt8, txId: UInt8) {
        guard c == .control else {
            return sendFrame(c, opCode: ErrorResponse.props.opCode, txId: txId, cargo: [0, code])
        }
        // The signed trailer (pump time and HMAC-SHA1) covers the header, whose length counts it.
        let cargo: [UInt8] = [request, code]
        let header: [UInt8] = [ErrorResponse.props.opCode, txId, UInt8(cargo.count + 24)]
        let time = le32(pump.wallClock)
        let hmac = Packetize.doHmacSha1(header + cargo + time, key: key)
        sendFrame(c, opCode: ErrorResponse.props.opCode, txId: txId, cargo: cargo + time + hmac)
    }
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
func float(_ v: Float) -> [UInt8] { le32(v.bitPattern) }
func readU16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
func readU32(_ b: [UInt8], _ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[i + $1]) << (8 * UInt32($1)) } }
