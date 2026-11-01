import CryptoKit
import Foundation

/// The watch's preferences, set on the phone. Sent in full when the watch connects, on any change, and
/// whenever the watch reports a revision other than the phone's (which also covers a watch that lost its
/// storage).
///
/// The revision is a digest of the content, not a counter: two configs are the same exactly when their
/// revisions are, so a reinstall on either side can't make an older config look newer.
public struct WatchConfig: Sendable, Hashable {
    /// Bolusing from this watch is turned on. The phone refuses a dose when it's off whatever the watch
    /// shows; this only hides the button.
    public var bolusEnabled: Bool
    /// Remotes are read-only.
    public var readOnly: Bool
    public var defaultBolusMode: BolusModeToken
    /// The step when dialing units, milliunits.
    public var unitsStepMilliunits: Int
    /// The step when dialing carbs, grams.
    public var carbStepGrams: Int
    public var screenOrder: [ScreenToken]
    public var defaultScreen: ScreenToken
    public var detailsOrder: [DetailToken]
    /// The history ranges the chart cycles through, hours.
    public var chartHours: [Int]
    public var complicationSlots: [ComplicationSlotToken]
    /// The slots' labels name what they show ("IOB 1.25"); off (the default), the value alone ("1.25 U").
    public var complicationLabels: Bool
    public var glucoseUnit: GlucoseUnitToken
    /// Glucose older than this is shown marked as stale.
    public var glucoseStaleMinutes: Int
    /// IOB, and the calculator's settings, count as current while younger than these: the phone's own windows.
    public var iobStaleMinutes: Int
    public var therapyStaleMinutes: Int
    /// How long after going stale the value is hidden; `nil` never hides it.
    public var glucoseHideDelayMinutes: Int?
    /// The chart's y-axis, mg/dL, already resolved for a small screen.
    public var plotFloorMgdl: Int
    public var plotCeilingMgdl: Int

    public static let allowedChartHours = [3, 6, 12, 24]
    public static let maxComplicationSlots = 3

    public init(
        bolusEnabled: Bool, readOnly: Bool, defaultBolusMode: BolusModeToken, unitsStepMilliunits: Int,
        carbStepGrams: Int, screenOrder: [ScreenToken], defaultScreen: ScreenToken, detailsOrder: [DetailToken],
        chartHours: [Int], complicationSlots: [ComplicationSlotToken],
        complicationLabels: Bool = false, glucoseUnit: GlucoseUnitToken, glucoseStaleMinutes: Int,
        iobStaleMinutes: Int = 5, therapyStaleMinutes: Int = 15,
        glucoseHideDelayMinutes: Int?,
        plotFloorMgdl: Int, plotCeilingMgdl: Int
    ) {
        self.bolusEnabled = bolusEnabled
        self.readOnly = readOnly
        self.defaultBolusMode = defaultBolusMode
        self.unitsStepMilliunits = unitsStepMilliunits
        self.carbStepGrams = carbStepGrams
        self.screenOrder = screenOrder
        self.defaultScreen = defaultScreen
        self.detailsOrder = detailsOrder
        self.chartHours = chartHours
        self.complicationSlots = complicationSlots
        self.complicationLabels = complicationLabels
        self.glucoseUnit = glucoseUnit
        self.glucoseStaleMinutes = glucoseStaleMinutes
        self.iobStaleMinutes = iobStaleMinutes
        self.therapyStaleMinutes = therapyStaleMinutes
        self.glucoseHideDelayMinutes = glucoseHideDelayMinutes
        self.plotFloorMgdl = plotFloorMgdl
        self.plotCeilingMgdl = plotCeilingMgdl
    }

    /// Sixteen hex digits of the SHA-256 of the content's canonical JSON.
    public var revision: String {
        let digest = SHA256.hash(data: Data(contentWire.canonicalJSON.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Everything but the revision.
    var contentWire: WireValue {
        var w = FieldWriter()
        var bolus = FieldWriter()
        bolus.set("enabled", bolusEnabled)
        bolus.set("readOnly", readOnly)
        bolus.set("defaultMode", defaultBolusMode.rawValue)
        bolus.set("unitsStepMU", unitsStepMilliunits)
        bolus.set("carbStepG", carbStepGrams)
        w.set("bolus", bolus.value)
        var screens = FieldWriter()
        screens.set("order", strings: screenOrder.map(\.rawValue))
        screens.set("default", defaultScreen.rawValue)
        w.set("screens", screens.value)
        w.set("details", strings: detailsOrder.map(\.rawValue))
        w.set("chartHours", ints: chartHours)
        var complication = FieldWriter()
        complication.set("slots", strings: complicationSlots.map(\.rawValue))
        complication.set("labels", complicationLabels)
        w.set("complication", complication.value)
        var glucose = FieldWriter()
        glucose.set("unit", glucoseUnit.rawValue)
        glucose.set("staleMinutes", glucoseStaleMinutes)
        glucose.set("hideDelayMinutes", glucoseHideDelayMinutes)
        glucose.set("plotFloor", plotFloorMgdl)
        glucose.set("plotCeiling", plotCeilingMgdl)
        w.set("glucose", glucose.value)
        var freshness = FieldWriter()
        freshness.set("iobMinutes", iobStaleMinutes)
        freshness.set("therapyMinutes", therapyStaleMinutes)
        w.set("freshness", freshness.value)
        return w.value
    }

    var wire: WireValue {
        guard case .object(var o) = contentWire else { return contentWire }
        o["revision"] = .string(revision)
        return .object(o)
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        let bolus = try r.object("bolus")
        bolusEnabled = try bolus.bool("enabled")
        readOnly = try bolus.bool("readOnly")
        defaultBolusMode = try bolus.token("defaultMode", as: BolusModeToken.self)
        unitsStepMilliunits = try bolus.int("unitsStepMU", in: 10...10_000)
        carbStepGrams = try bolus.int("carbStepG", in: 1...50)
        let screens = try r.object("screens")
        screenOrder = try Self.tokens(screens, "order", as: ScreenToken.self)
        defaultScreen = try screens.token("default", as: ScreenToken.self)
        guard screenOrder.contains(defaultScreen) else { throw .outOfRange(field: "payload.screens.default") }
        detailsOrder = try Self.tokens(r, "details", as: DetailToken.self)
        chartHours = try r.intArray("chartHours", maxCount: Self.allowedChartHours.count, in: 1...24)
        guard !chartHours.isEmpty, chartHours.allSatisfy(Self.allowedChartHours.contains),
            Set(chartHours).count == chartHours.count
        else { throw .outOfRange(field: "payload.chartHours") }
        let complication = try r.object("complication")
        complicationSlots = try Self.tokens(complication, "slots", as: ComplicationSlotToken.self)
        complicationLabels = try complication.bool("labels")
        guard complicationSlots.count <= Self.maxComplicationSlots else {
            throw .tooLong(field: "payload.complication.slots")
        }
        let glucose = try r.object("glucose")
        glucoseUnit = try glucose.token("unit", as: GlucoseUnitToken.self)
        glucoseStaleMinutes = try glucose.int("staleMinutes", in: 1...60)
        glucoseHideDelayMinutes = try glucose.optionalInt("hideDelayMinutes", in: 0...1440)
        plotFloorMgdl = try glucose.int("plotFloor", in: 0...400)
        plotCeilingMgdl = try glucose.int("plotCeiling", in: 100...600)
        guard plotFloorMgdl < plotCeilingMgdl else { throw .outOfRange(field: "payload.glucose.plotFloor") }
        let freshness = try r.object("freshness")
        iobStaleMinutes = try freshness.int("iobMinutes", in: 1...60)
        therapyStaleMinutes = try freshness.int("therapyMinutes", in: 1...240)
        // A revision that doesn't match the content is a corrupt message, not a config to adopt.
        let sent = try r.id("revision")
        guard sent == revision else { throw .outOfRange(field: "payload.revision") }
    }

    private static func tokens<T: RawRepresentable & Hashable>(_ r: FieldReader, _ key: String, as: T.Type)
        throws(DecodeError) -> [T] where T.RawValue == String
    {
        var out: [T] = []
        for s in try r.stringArray(key, maxCount: WireLimits.maxListCount) {
            guard let t = T(rawValue: s) else { throw .unknownToken(field: "\(r.path).\(key)", token: s) }
            guard !out.contains(t) else { throw .outOfRange(field: "\(r.path).\(key)") }
            out.append(t)
        }
        return out
    }
}
