import Foundation

/// A value with the time it was measured, by the phone's clock (epoch seconds). The watch judges how old a
/// value is as `status.sentAt - at` plus the time since the status arrived, so a difference between the two
/// clocks doesn't make a value look fresher or older than it is.
public struct Timed<Value: Sendable & Hashable>: Sendable, Hashable {
    public var value: Value
    public var at: Int
    public init(_ value: Value, at: Int) {
        self.value = value
        self.at = at
    }
}

public struct GlucoseReading: Sendable, Hashable {
    public var mgdl: Int
    public var trend: TrendToken?
    /// From the backup CGM source rather than the pump.
    public var backup: Bool
    public init(mgdl: Int, trend: TrendToken?, backup: Bool) {
        self.mgdl = mgdl
        self.trend = trend
        self.backup = backup
    }
}

public struct BatteryReading: Sendable, Hashable {
    public var percent: Int
    /// `nil` when the pump didn't say.
    public var charging: Bool?
    public init(percent: Int, charging: Bool?) {
        self.percent = percent
        self.charging = charging
    }
}

public enum BasalReading: Sendable, Hashable {
    case active(milliunitsPerHour: Int)
    case suspended
}

/// The pump calculator's settings for its active profile and time segment.
public struct CalculatorSettings: Sendable, Hashable {
    /// Grams of carbohydrate per unit, times 1000 (a ratio of 7.5 g/U is 7500).
    public var carbRatioMilligramsPerUnit: Int
    /// mg/dL lowered per unit.
    public var correctionFactor: Int
    public var targetMgdl: Int
    public var maxBolusMilliunits: Int
    public init(carbRatioMilligramsPerUnit: Int, correctionFactor: Int, targetMgdl: Int, maxBolusMilliunits: Int) {
        self.carbRatioMilligramsPerUnit = carbRatioMilligramsPerUnit
        self.correctionFactor = correctionFactor
        self.targetMgdl = targetMgdl
        self.maxBolusMilliunits = maxBolusMilliunits
    }
}

public struct ControlIQReading: Sendable, Hashable {
    public var enabled: Bool
    public var activity: ActivityToken
    public init(enabled: Bool, activity: ActivityToken) {
        self.enabled = enabled
        self.activity = activity
    }
}

/// The bolus the pump says it is delivering, whichever surface started it. A remote may always cancel it.
public struct ActiveBolus: Sendable, Hashable {
    public var requestedMilliunits: Int
    public var deliveredMilliunits: Int?
    /// When delivery started.
    public var startedAt: Int
    public init(requestedMilliunits: Int, deliveredMilliunits: Int?, startedAt: Int) {
        self.requestedMilliunits = requestedMilliunits
        self.deliveredMilliunits = deliveredMilliunits
        self.startedAt = startedAt
    }
}

/// An alert the phone holds and has announced. The watch mirrors exactly this list.
public struct AlertItem: Sendable, Hashable {
    /// The phone's identifier; a dismiss names it.
    public var id: String
    public var title: String
    public var body: String
    public var severity: SeverityToken
    public var intent: WatchIntentToken
    /// A pump alert the pump may let a remote dismiss.
    public var dismissable: Bool
    public init(
        id: String, title: String, body: String, severity: SeverityToken, intent: WatchIntentToken, dismissable: Bool
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.severity = severity
        self.intent = intent
        self.dismissable = dismissable
    }
}

/// The frequent message: every live value with its measurement time. Sent on every change, as the answer to
/// a poll, and when the watch connects. It names no request: the watch takes any status.
public struct StatusPayload: Sendable, Hashable {
    /// When the phone built it, by the phone's clock.
    public var sentAt: Int
    /// The revision of the config the phone holds now. A watch holding another one asks for the config.
    public var configRevision: String
    public var pumpLink: PumpLinkToken
    public var glucose: Timed<GlucoseReading>?
    public var insulinOnBoardMilliunits: Timed<Int>?
    public var reservoirMilliunits: Timed<Int>?
    public var battery: Timed<BatteryReading>?
    public var basal: Timed<BasalReading>?
    /// The last bolus the pump reports, measured at when it was given.
    public var lastBolusMilliunits: Timed<Int>?
    public var calculator: Timed<CalculatorSettings>?
    public var controlIQ: Timed<ControlIQReading>?
    public var maxBasalMilliunitsPerHour: Timed<Int>?
    /// `nil` when a remote may start a bolus now.
    public var bolusBlock: BolusBlockToken?
    public var activeBolus: ActiveBolus?
    public var alerts: [AlertItem]
    /// The user's remote bolus size limit, when one is set.
    public var remoteLimitMilliunits: Int?

    public init(
        sentAt: Int, configRevision: String, pumpLink: PumpLinkToken, glucose: Timed<GlucoseReading>? = nil,
        insulinOnBoardMilliunits: Timed<Int>? = nil, reservoirMilliunits: Timed<Int>? = nil,
        battery: Timed<BatteryReading>? = nil, basal: Timed<BasalReading>? = nil,
        lastBolusMilliunits: Timed<Int>? = nil, calculator: Timed<CalculatorSettings>? = nil,
        controlIQ: Timed<ControlIQReading>? = nil, maxBasalMilliunitsPerHour: Timed<Int>? = nil,
        bolusBlock: BolusBlockToken?, activeBolus: ActiveBolus? = nil, alerts: [AlertItem] = [],
        remoteLimitMilliunits: Int? = nil
    ) {
        self.sentAt = sentAt
        self.configRevision = configRevision
        self.pumpLink = pumpLink
        self.glucose = glucose
        self.insulinOnBoardMilliunits = insulinOnBoardMilliunits
        self.reservoirMilliunits = reservoirMilliunits
        self.battery = battery
        self.basal = basal
        self.lastBolusMilliunits = lastBolusMilliunits
        self.calculator = calculator
        self.controlIQ = controlIQ
        self.maxBasalMilliunitsPerHour = maxBasalMilliunitsPerHour
        self.bolusBlock = bolusBlock
        self.activeBolus = activeBolus
        self.alerts = alerts
        self.remoteLimitMilliunits = remoteLimitMilliunits
    }
}

extension StatusPayload {
    var wire: WireValue {
        var w = FieldWriter()
        w.set("sentAt", sentAt)
        w.set("configRevision", configRevision)
        w.set("pumpLink", pumpLink.rawValue)
        w.set(
            "glucose",
            glucose.map {
                timed($0) { g, w in
                    w.set("mgdl", g.mgdl)
                    w.set("trend", g.trend?.rawValue)
                    w.set("backup", g.backup)
                }
            })
        w.set("iob", insulinOnBoardMilliunits.map { timed($0) { v, w in w.set("mU", v) } })
        w.set("reservoir", reservoirMilliunits.map { timed($0) { v, w in w.set("mU", v) } })
        w.set(
            "battery",
            battery.map {
                timed($0) { b, w in
                    w.set("percent", b.percent)
                    w.set("charging", b.charging)
                }
            })
        w.set(
            "basal",
            basal.map {
                timed($0) { b, w in
                    switch b {
                    case .active(let rate):
                        w.set("suspended", false)
                        w.set("mUPerHour", rate)
                    case .suspended:
                        w.set("suspended", true)
                    }
                }
            })
        w.set("lastBolus", lastBolusMilliunits.map { timed($0) { v, w in w.set("mU", v) } })
        w.set(
            "calculator",
            calculator.map {
                timed($0) { c, w in
                    w.set("carbRatioMg", c.carbRatioMilligramsPerUnit)
                    w.set("isf", c.correctionFactor)
                    w.set("target", c.targetMgdl)
                    w.set("maxBolusMU", c.maxBolusMilliunits)
                }
            })
        w.set(
            "controlIQ",
            controlIQ.map {
                timed($0) { c, w in
                    w.set("enabled", c.enabled)
                    w.set("activity", c.activity.rawValue)
                }
            })
        w.set("maxBasal", maxBasalMilliunitsPerHour.map { timed($0) { v, w in w.set("mUPerHour", v) } })
        var bolus = FieldWriter()
        bolus.set("canBolus", bolusBlock == nil)
        bolus.set("blockReason", bolusBlock?.rawValue)
        if let active = activeBolus {
            var a = FieldWriter()
            a.set("requestedMU", active.requestedMilliunits)
            a.set("deliveredMU", active.deliveredMilliunits)
            a.set("startedAt", active.startedAt)
            bolus.set("active", a.value)
        }
        bolus.set("remoteLimitMU", remoteLimitMilliunits)
        w.set("bolus", bolus.value)
        w.set("alerts", .array(alerts.map(\.wire)))
        return w.value
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        sentAt = try r.int("sentAt", in: epochRange)
        configRevision = try r.id("configRevision")
        pumpLink = try r.token("pumpLink", as: PumpLinkToken.self)
        glucose = try r.optionalObject("glucose").map { g throws(DecodeError) in
            Timed(
                GlucoseReading(
                    mgdl: try g.int("mgdl", in: glucoseRange), trend: try g.optionalToken("trend", as: TrendToken.self),
                    backup: try g.bool("backup")), at: try g.int("at", in: epochRange))
        }
        insulinOnBoardMilliunits = try r.optionalObject("iob").map { o throws(DecodeError) in
            Timed(try o.int("mU", in: milliunitRange), at: try o.int("at", in: epochRange))
        }
        reservoirMilliunits = try r.optionalObject("reservoir").map { o throws(DecodeError) in
            Timed(try o.int("mU", in: milliunitRange), at: try o.int("at", in: epochRange))
        }
        battery = try r.optionalObject("battery").map { o throws(DecodeError) in
            Timed(
                BatteryReading(percent: try o.int("percent", in: 0...100), charging: try o.optionalBool("charging")),
                at: try o.int("at", in: epochRange))
        }
        basal = try r.optionalObject("basal").map { o throws(DecodeError) in
            let reading: BasalReading =
                try o.bool("suspended")
                ? .suspended : .active(milliunitsPerHour: try o.int("mUPerHour", in: milliunitRange))
            return Timed(reading, at: try o.int("at", in: epochRange))
        }
        lastBolusMilliunits = try r.optionalObject("lastBolus").map { o throws(DecodeError) in
            Timed(try o.int("mU", in: milliunitRange), at: try o.int("at", in: epochRange))
        }
        calculator = try r.optionalObject("calculator").map { o throws(DecodeError) in
            Timed(
                CalculatorSettings(
                    carbRatioMilligramsPerUnit: try o.int("carbRatioMg", in: WireLimits.carbRatioMilligrams),
                    correctionFactor: try o.int("isf", in: WireLimits.calculatorMgdl),
                    targetMgdl: try o.int("target", in: WireLimits.calculatorMgdl),
                    maxBolusMilliunits: try o.int("maxBolusMU", in: milliunitRange)),
                at: try o.int("at", in: epochRange))
        }
        controlIQ = try r.optionalObject("controlIQ").map { o throws(DecodeError) in
            Timed(
                ControlIQReading(
                    enabled: try o.bool("enabled"), activity: try o.token("activity", as: ActivityToken.self)),
                at: try o.int("at", in: epochRange))
        }
        maxBasalMilliunitsPerHour = try r.optionalObject("maxBasal").map { o throws(DecodeError) in
            Timed(try o.int("mUPerHour", in: milliunitRange), at: try o.int("at", in: epochRange))
        }
        let bolus = try r.object("bolus")
        let canBolus = try bolus.bool("canBolus")
        let block = try bolus.optionalToken("blockReason", as: BolusBlockToken.self)
        // Both say the same thing; a message where they disagree is refused rather than guessed at.
        guard canBolus == (block == nil) else { throw .outOfRange(field: "payload.bolus.canBolus") }
        bolusBlock = block
        activeBolus = try bolus.optionalObject("active").map { a throws(DecodeError) in
            ActiveBolus(
                requestedMilliunits: try a.int("requestedMU", in: milliunitRange),
                deliveredMilliunits: try a.optionalInt("deliveredMU", in: milliunitRange),
                startedAt: try a.int("startedAt", in: epochRange))
        }
        remoteLimitMilliunits = try bolus.optionalInt("remoteLimitMU", in: milliunitRange)
        var items: [AlertItem] = []
        for (index, element) in try r.array("alerts", maxCount: WireLimits.maxListCount).enumerated() {
            items.append(try AlertItem(wire: element, path: "payload.alerts[\(index)]"))
        }
        alerts = items
    }
}

private func timed<V>(_ t: Timed<V>, _ fill: (V, inout FieldWriter) -> Void) -> WireValue {
    var w = FieldWriter()
    fill(t.value, &w)
    w.set("at", t.at)
    return w.value
}

extension AlertItem {
    var wire: WireValue {
        var w = FieldWriter()
        w.set("id", id)
        w.set("title", title)
        w.set("body", body)
        w.set("severity", severity.rawValue)
        w.set("intent", intent.rawValue)
        w.set("dismissable", dismissable)
        return w.value
    }

    init(wire: WireValue, path: String) throws(DecodeError) {
        let r = try FieldReader(wire, path: path)
        id = try r.id("id")
        title = try r.string("title", maxLength: WireLimits.maxTitleLength)
        body = try r.string("body", maxLength: WireLimits.maxTextLength)
        severity = try r.token("severity", as: SeverityToken.self)
        intent = try r.token("intent", as: WatchIntentToken.self)
        dismissable = try r.bool("dismissable")
    }
}
