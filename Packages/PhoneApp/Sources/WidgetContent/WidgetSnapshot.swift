import Foundation
import faBolusCore

/// What the app publishes for its widgets, through the App Group. Widgets can't reach the pump, and they
/// render ahead of time, so every value carries its measurement time and the snapshot carries the phone's
/// freshness windows: a widget decides at its entry's date, exactly as the phone would at that moment,
/// whether a value is still current. A value the pump never reported is absent, never zero.
public struct WidgetSnapshot: Codable, Sendable, Hashable {
    public struct Point: Codable, Sendable, Hashable {
        public var t: Date
        public var mgdl: Int
        public init(t: Date, mgdl: Int) {
            self.t = t
            self.mgdl = mgdl
        }
    }

    /// The glucose the phone shows: the pump's, or the backup source's when the pump's is stale.
    public var glucose: Observed<PumpGlucose>?
    /// The backup source's name while it supplies `glucose`.
    public var glucoseSourceName: String?
    public var insulinOnBoard: Observed<Double>?
    public var reservoirUnits: Observed<Double>?
    public var battery: Observed<PumpBattery>?
    public var basal: Observed<BasalDeliveryState>?
    public var controlIQ: Observed<ControlIQStatus>?
    public var lastBolus: Observed<Double>?
    /// When Control-IQ last auto-corrected, from the pump's history; `nil` when none is known.
    public var lastAutoCorrection: Date?
    /// The pump link was up when this was published.
    public var connected: Bool
    public var publishedAt: Date
    /// Recent readings, oldest first, for a sparkline.
    public var recent: [Point]
    public var freshness: FreshnessThresholds
    public var unit: GlucoseUnit
    public var showUnitLabel: Bool

    public init(
        glucose: Observed<PumpGlucose>? = nil, glucoseSourceName: String? = nil,
        insulinOnBoard: Observed<Double>? = nil, reservoirUnits: Observed<Double>? = nil,
        battery: Observed<PumpBattery>? = nil, basal: Observed<BasalDeliveryState>? = nil,
        controlIQ: Observed<ControlIQStatus>? = nil, lastBolus: Observed<Double>? = nil,
        lastAutoCorrection: Date? = nil, connected: Bool = false, publishedAt: Date, recent: [Point] = [],
        freshness: FreshnessThresholds = .standard, unit: GlucoseUnit = .mgdl, showUnitLabel: Bool = false
    ) {
        self.glucose = glucose
        self.glucoseSourceName = glucoseSourceName
        self.insulinOnBoard = insulinOnBoard
        self.reservoirUnits = reservoirUnits
        self.battery = battery
        self.basal = basal
        self.controlIQ = controlIQ
        self.lastBolus = lastBolus
        self.lastAutoCorrection = lastAutoCorrection
        self.connected = connected
        self.publishedAt = publishedAt
        self.recent = recent
        self.freshness = freshness
        self.unit = unit
        self.showUnitLabel = showUnitLabel
    }

    // MARK: Glucose

    /// How the glucose reads at `now`: current, stale (shown marked), or hidden (past the hide window,
    /// shown as "--"). Staleness is from the measurement time, never the time it was published.
    public enum GlucosePresentation: Sendable, Hashable {
        case none
        case current(PumpGlucose)
        case stale(PumpGlucose, measuredAt: Date)
        case hidden
    }

    public func glucosePresentation(asOf now: Date) -> GlucosePresentation {
        guard let glucose else { return .none }
        guard glucose.isStale(after: freshness.glucoseStaleAfter, now: now) else { return .current(glucose.value) }
        if let hide = freshness.glucoseHideAfter, let age = glucose.age(now: now),
            age >= max(hide, freshness.glucoseStaleAfter)
        {
            return .hidden
        }
        // A reading whose age can't be known (dated in the future) is stale, never hidden: its age is shown.
        return .stale(glucose.value, measuredAt: glucose.measuredAt)
    }

    // MARK: Pump values

    /// Reservoir units while the pump's report is current at `now` (the pump-status window).
    public func reservoirIfFresh(asOf now: Date) -> Double? {
        reservoirUnits?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now)
    }

    /// Battery while the pump's report is current at `now` (the pump-status window).
    public func batteryIfFresh(asOf now: Date) -> PumpBattery? {
        battery?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now)
    }

    /// Basal delivery while the pump's report is current at `now` (the pump-status window).
    public func basalIfFresh(asOf now: Date) -> BasalDeliveryState? {
        basal?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now)
    }

    /// Control-IQ's state while the pump's report is current at `now` (the pump-status window).
    public func controlIQIfFresh(asOf now: Date) -> ControlIQStatus? {
        controlIQ?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now)
    }

    /// Active insulin on its own window, the one the dose path uses, so the widget never shows an IOB the
    /// phone would refuse to dose from.
    public func insulinOnBoardIfFresh(asOf now: Date) -> Double? {
        insulinOnBoard?.valueIfFresh(within: freshness.insulinOnBoardStaleAfter, now: now)
    }

    /// When each value shown stops being current, so a widget timeline re-renders at the moment it should.
    /// A value with no trustworthy time has no crossing: it is already shown as unknown.
    public func decayCrossings(asOf now: Date) -> [Date] {
        func crossing<V>(_ o: Observed<V>?, _ window: TimeInterval) -> Date? {
            guard let o, o.age(now: now) != nil, window.isFinite else { return nil }
            return o.measuredAt.addingTimeInterval(window)
        }
        var out = [
            crossing(glucose, freshness.glucoseStaleAfter),
            crossing(reservoirUnits, freshness.pumpStatusStaleAfter),
            crossing(battery, freshness.pumpStatusStaleAfter),
            crossing(basal, freshness.pumpStatusStaleAfter),
            crossing(controlIQ, freshness.pumpStatusStaleAfter),
            crossing(insulinOnBoard, freshness.insulinOnBoardStaleAfter)
        ]
        if let hide = freshness.glucoseHideAfter {
            out.append(crossing(glucose, max(hide, freshness.glucoseStaleAfter)))
        }
        return out.compactMap { $0 }.filter { $0 > now }.sorted()
    }

    /// The app stopped publishing long enough ago that "connected" can't be believed. A live app publishes
    /// at least every minute, so this only trips once the app has been killed or suspended for a while.
    public func isPublisherStale(asOf now: Date) -> Bool {
        now.timeIntervalSince(publishedAt) > Self.publisherStaleAfter
    }

    public static let publisherStaleAfter: TimeInterval = 6 * 60

    /// The link was up at the last publish and the app is still publishing.
    public func isConnected(asOf now: Date) -> Bool { connected && !isPublisherStale(asOf: now) }

    /// Sample data for the widget gallery.
    public static func placeholder(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(
            glucose: Observed(PumpGlucose(mgdl: 124, trend: .flat), measuredAt: now, receivedAt: now),
            insulinOnBoard: Observed(1.2, measuredAt: now, receivedAt: now),
            reservoirUnits: Observed(142, measuredAt: now, receivedAt: now),
            battery: Observed(PumpBattery(percent: 80, isCharging: false), measuredAt: now, receivedAt: now),
            lastBolus: Observed(2.5, measuredAt: now.addingTimeInterval(-1800), receivedAt: now),
            connected: true, publishedAt: now,
            recent: (0..<24).map {
                Point(t: now.addingTimeInterval(Double($0 - 24) * 300), mgdl: 110 + ($0 % 6) * 8)
            })
    }
}

extension WidgetSnapshot {
    /// What a widget or the Live Activity draws from the snapshot: without the times values were received
    /// or the snapshot was published, so a re-read of an unchanged value isn't a change.
    public var drawn: WidgetSnapshot {
        var s = self
        s.glucose = glucose?.withoutReceiveTime
        s.insulinOnBoard = insulinOnBoard?.withoutReceiveTime
        s.reservoirUnits = reservoirUnits?.withoutReceiveTime
        s.battery = battery?.withoutReceiveTime
        s.basal = basal?.withoutReceiveTime
        s.controlIQ = controlIQ?.withoutReceiveTime
        s.lastBolus = lastBolus?.withoutReceiveTime
        s.publishedAt = .distantPast
        return s
    }
}

extension Observed {
    /// The value with its receive time set to its measurement time.
    public var withoutReceiveTime: Observed {
        var o = self
        o.receivedAt = measuredAt
        return o
    }
}

/// The widgets' copy of the snapshot in the App Group.
/// `@unchecked Sendable`: UserDefaults is thread-safe.
public struct WidgetStore: @unchecked Sendable {
    public static let snapshotKey = "widgetSnapshot.v2"
    /// The App Group, from the target's Info.plist (`AppGroupIdentifier`, set from the bundle ID), so a
    /// self-builder's own bundle ID needs no code change.
    public static var appGroupID: String {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "group.com.fabolus.app"
    }

    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: WidgetStore.appGroupID)) { self.defaults = defaults }

    public func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: Self.snapshotKey)
    }

    public func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: Self.snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

/// The app's URLs the widgets and Live Activity open.
public enum DeepLink {
    public static let scheme = "fabolus"
    /// Opens the bolus screen. Navigation only: nothing is delivered from a widget.
    public static let bolus = URL(string: "fabolus://bolus")!
    public static let open = URL(string: "fabolus://open")!
}
