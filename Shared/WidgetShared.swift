import Foundation

/// The widget island's mirror of `faBolusCore.GlucoseThresholds`. As of Phase 09.1 (D-01/D-02) the
/// widget/complication extension targets DO transitively link `faBolusCore` via `faBolusDesign` (for
/// the shared band-color tokens + `BandIndicator` primitive) — but this mirror is intentionally
/// RETAINED rather than retired this phase, to keep the diff scoped to color/primitive routing (see
/// the phase's scoped-out note). `WidgetGlucoseThresholdsMirrorTests` (app target, which links BOTH)
/// asserts these equal the canonical `GlucoseThresholds`, so the two can't drift silently. See
/// `GlucoseThresholds` for the clinical source (Battelino 2019 international TIR consensus, §13).
public enum WidgetGlucoseThresholds {
    public static let low = 70  // == GlucoseThresholds.low
    public static let high = 180  // == GlucoseThresholds.high
    public static let veryHigh = 250  // == GlucoseThresholds.veryHigh
}

/// The widget island's mirror of `faBolusCore.GlucoseUnit` (Phase 04-03, mmol/L display-unit
/// support). RETAINED as-is post-Phase-09.1 for the same reason as `WidgetGlucoseThresholds` above
/// (the extensions now link faBolusCore transitively via faBolusDesign, but retiring this mirror is
/// out of scope this phase), so this carries the same two-case shape, the same 18.0182
/// factor, and the same 1-decimal mmol format. The unit rides the App Group as a plain `String?`
/// wire token ("mgdl"|"mmol") on `WidgetSnapshot.displayUnit` — never this enum directly (Pitfall
/// 6: a raw enum on the wire risks a silent encoding drift if a case is ever added); a nil or
/// unrecognized token resolves to `.mgdl` (legacy-safe, matches D-03's mg/dL default).
/// `WidgetGlucoseUnitMirrorTests` (app target, which links BOTH) pins this to the canonical
/// `faBolusCore.GlucoseUnit` so the two can't drift silently (T-04-06).
public enum WidgetGlucoseUnit: String {
    case mgdl, mmol

    /// mg/dL per mmol/L (D-05, locked) — mirrors `faBolusCore.GlucoseUnit.mgdlPerMmol` exactly;
    /// pinned equal by the drift-guard test, not re-derived independently.
    public static let mgdlPerMmol = 18.0182

    /// Resolve the App-Group wire token ("mgdl"|"mmol") to a unit. `nil` or an unrecognized token
    /// (e.g. a future third case from a newer phone build) falls back to `.mgdl` — behavior-
    /// preserving, never a crash, never a silently-wrong conversion.
    public init(wireToken: String?) {
        self = wireToken.flatMap(WidgetGlucoseUnit.init(rawValue:)) ?? .mgdl
    }

    /// mg/dL → a display string in this unit. Identical shape/rounding to
    /// `faBolusCore.GlucoseUnit.format(mgdl:)`: `.mgdl` is the plain integer, `.mmol` is ALWAYS
    /// exactly 1 decimal.
    public func format(mgdl: Int) -> String {
        switch self {
        case .mgdl: return "\(mgdl)"
        case .mmol: return String(format: "%.1f", Double(mgdl) / Self.mgdlPerMmol)
        }
    }

    /// The unit suffix shown next to a formatted value, same convention as the phone's
    /// `StatusRingView.unitLabel`.
    public var unitLabel: String { self == .mmol ? "mmol/L" : "mg/dL" }
}

/// Data shared from the app to its WidgetKit extension via an App Group. The app writes a
/// `WidgetSnapshot` on every pump update; Lock Screen / Home Screen widgets read the latest one.
/// Widgets can't drive Bluetooth themselves, so they show the last-published values plus an age.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    // Hashable (Phase 5, D-06): originally required by the Live Activity `ContentState`
    // (`ActivityAttributes.ContentState` protocol constraint), which carried `[Point]` verbatim
    // (removed Phase 7, 07-01, FEAT-01). Kept — harmless and still additive; `Date`/`Int` are both
    // Hashable, so this doesn't change `Point`'s existing Equatable/Codable behavior.
    public struct Point: Codable, Sendable, Equatable, Hashable {
        public var t: Date
        public var mgdl: Int
        public init(t: Date, mgdl: Int) {
            self.t = t
            self.mgdl = mgdl
        }
    }

    public var glucose: Int?
    public var glucoseDate: Date?  // when the reading was taken (for 6-min staleness)
    public var trendArrow: String  // Unicode trend arrow (→ ↑ ↓ ⇈ ⇊ ↗ ↘), same as the app HUD
    public var iobUnits: Double
    public var reservoirUnits: Double
    public var batteryPercent: Int
    /// Phase 09.27-02 (D-04/D-05) — whether the pump is currently charging (op-145
    /// `chargingStatus == 1`, mirrored verbatim from `PumpSnapshot.batteryCharging`). Additive,
    /// fail-closed default `false` (matches `deliverySuspended`'s own non-optional shape):
    /// absent/legacy key ⇒ never a fabricated charging badge on an old widget/complication snapshot
    /// (D-05). Routed through `BatteryChargingPresentation` at render — never re-derived inline.
    public var batteryCharging: Bool
    public var lastBolusUnits: Double?
    public var lastBolusDate: Date?
    public var connected: Bool
    public var updatedAt: Date
    /// Recent readings for a sparkline (oldest→newest, capped small for App Group size).
    public var recentPoints: [Point]
    /// Active pump alert titles (for the read-only Siri "alerts" query).
    public var activeAlerts: [String]
    // Extra pump settings/status exposed to Siri + Apple Shortcuts.
    public var cgmActive: Bool
    public var carbRatio: Double  // g/U (0 = unknown)
    public var isf: Int  // mg/dL per U (0 = unknown)
    public var targetBg: Int  // mg/dL (0 = unknown)
    public var maxBolusUnits: Double  // pump's configured max
    // The publisher's freshness policy (from the phone), so a widget in its own process greys/hides
    // exactly like the app instead of assuming the 6-min default. Optional for back-compat / iOS.
    public var staleAfterSec: TimeInterval?  // grey after this age
    public var hideAfterSec: TimeInterval?  // hide ("--") after this age; nil = never hide
    /// The active glucose display unit, mirrored from `AppSettings.glucoseDisplayUnit` (Phase
    /// 04-03). A wire token ("mgdl"|"mmol"), never `WidgetGlucoseUnit` itself (Pitfall 6). `nil` ⇒
    /// mgdl — an older app version's snapshot (before this field existed) decodes fine via
    /// `Codable`'s default-on-missing-key behavior and renders mg/dL, matching D-03's default.
    public var displayUnit: String?

    /// Owner-requested "Show unit labels" toggle, mirrored from `AppSettings.showGlucoseUnitLabels`.
    /// Additive-optional: `nil`/missing-key on a legacy snapshot decodes to **false** (labels hidden),
    /// matching the setting's own default-OFF — a widget built before this field existed never starts
    /// showing a caption it wasn't told to. Gates ONLY the persistent mg/dL·mmol/L CAPTION on the
    /// widget/complication ambient surfaces; the glucose number itself is unaffected.
    public var showUnitLabel: Bool

    // Phase 5 pump surfaces (D-17, 05-02) — the five faBolus-differentiator fields originally
    // projected alongside glucose by the Live Activity (removed Phase 7, 07-01, FEAT-01); kept
    // compiled as general PumpSnapshot mirrors (AppModel.swift's write path is byte-identity
    // protected). All additive-optional, defaulted below AND in the custom `init(from:)` decoder
    // (see Codable conformance) so an old JSON snapshot missing every one of these still decodes.
    // `iobDate` is the op-109 stamp IOB greys/ages off (mirrors `PumpSnapshot.iobDate`); the other
    // four are dateless.
    /// When `iobUnits` was last received from the pump (op-109). `nil` ⇒ unknown age ⇒ always stale.
    public var iobDate: Date?
    /// Effective basal delivery rate (U/hr) — never an invented temp-rate percent.
    public var basalRateUnitsPerHour: Double
    /// Whether basal delivery is currently suspended.
    public var deliverySuspended: Bool
    /// Control-IQ user mode: 0 = normal, 1 = sleep, 2 = exercise.
    public var controlIQMode: Int
    /// Whether Control-IQ automation is enabled.
    public var controlIQEnabled: Bool
    /// Phase 5 (D-18, 05-05) — true when at least one currently-active pump alert is snooze-eligible
    /// (`PumpAlertKind.isAutoRuleEligible`, i.e. NOT `.alarm`). Computed app-side from
    /// `AppModel.activeNotifications` (which carries the per-alert `kind` this wire type doesn't) —
    /// the same "app computes the gate, the extension/intent only reads it" pattern as
    /// `iobStale`/`pumpLinkStale` (D-17, §13 Rule 1). Originally gated the Live Activity's "Snooze"
    /// button visibility + its `LiveActivityIntentBridge.snoozeAlertIfSafe` action re-check (both
    /// removed Phase 7, 07-01, FEAT-01) — kept compiled as a general PumpSnapshot mirror
    /// (AppModel.swift's write path is byte-identity protected).
    public var hasSnoozeEligibleAlert: Bool

    /// Phase 09.9-04 (D-05) — the pump's cartridge-ready DISPLAY signal. Additive, mirroring
    /// `deliverySuspended`: default **true** ("ready") is the SAFE decode default for a legacy
    /// widget-extension binary that predates this field — an ABSENT key must never render as a false
    /// "cartridge not ready" scare, matching the RemoteCommand.cartridgeReady precedent.
    /// WR-04 (debug pump-pairing-loop-api25, deep review): `WidgetPublisher.makeSnapshot` now sets this
    /// from `PumpSnapshot.cartridgeReadiness == .ready` (a CONFIRMED reply), not the fail-open
    /// `cartridgeReadyForBolus`, so a `.unknown` state (op-20 auto-excluded / never read) maps to the
    /// non-positive `false` — the widget never presents a fail-open "ready" from a state that was never
    /// read. The Bool can only carry two states (not a third "unknown"), so `false` here means "omit the
    /// positive badge". Absent-key legacy decode still defaults to `true` (below), unchanged.
    public var cartridgeReady: Bool

    public init(
        glucose: Int? = nil, glucoseDate: Date? = nil, trendArrow: String = "", iobUnits: Double = 0,
        reservoirUnits: Double = 0, batteryPercent: Int = 0, batteryCharging: Bool = false,
        lastBolusUnits: Double? = nil,
        lastBolusDate: Date? = nil, connected: Bool = false, updatedAt: Date = Date(),
        recentPoints: [Point] = [], activeAlerts: [String] = [], cgmActive: Bool = false,
        carbRatio: Double = 0, isf: Int = 0, targetBg: Int = 0, maxBolusUnits: Double = 0,
        staleAfterSec: TimeInterval? = nil, hideAfterSec: TimeInterval? = nil,
        displayUnit: String? = nil, iobDate: Date? = nil, basalRateUnitsPerHour: Double = 0,
        deliverySuspended: Bool = false, controlIQMode: Int = 0, controlIQEnabled: Bool = false,
        hasSnoozeEligibleAlert: Bool = false, showUnitLabel: Bool = false,
        cartridgeReady: Bool = true
    ) {
        self.glucose = glucose
        self.glucoseDate = glucoseDate
        self.trendArrow = trendArrow
        self.iobUnits = iobUnits
        self.reservoirUnits = reservoirUnits
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
        self.lastBolusUnits = lastBolusUnits
        self.lastBolusDate = lastBolusDate
        self.connected = connected
        self.updatedAt = updatedAt
        self.recentPoints = recentPoints
        self.activeAlerts = activeAlerts
        self.cgmActive = cgmActive
        self.carbRatio = carbRatio
        self.isf = isf
        self.targetBg = targetBg
        self.maxBolusUnits = maxBolusUnits
        self.staleAfterSec = staleAfterSec
        self.hideAfterSec = hideAfterSec
        self.displayUnit = displayUnit
        self.iobDate = iobDate
        self.basalRateUnitsPerHour = basalRateUnitsPerHour
        self.deliverySuspended = deliverySuspended
        self.controlIQMode = controlIQMode
        self.controlIQEnabled = controlIQEnabled
        self.hasSnoozeEligibleAlert = hasSnoozeEligibleAlert
        self.showUnitLabel = showUnitLabel
        self.cartridgeReady = cartridgeReady
    }

    private enum CodingKeys: String, CodingKey {
        case glucose, glucoseDate, trendArrow, iobUnits, reservoirUnits, batteryPercent, batteryCharging,
            lastBolusUnits,
            lastBolusDate, connected, updatedAt, recentPoints, activeAlerts, cgmActive, carbRatio, isf,
            targetBg, maxBolusUnits, staleAfterSec, hideAfterSec, displayUnit, iobDate,
            basalRateUnitsPerHour, deliverySuspended, controlIQMode, controlIQEnabled, hasSnoozeEligibleAlert,
            showUnitLabel, cartridgeReady
    }

    /// Custom decode so EVERY field (not just the `Optional`-typed ones synthesis already tolerates)
    /// falls back to its `init` default on a missing key — proven necessary because Swift's
    /// synthesized `Decodable` only auto-tolerates a missing key for `Optional`-typed properties; a
    /// non-optional stored property (e.g. `basalRateUnitsPerHour: Double`) throws `keyNotFound` on a
    /// legacy payload despite having a default in the memberwise `init` above. This keeps the additive-
    /// optional wire contract for the Phase 5 pump fields (and every earlier field) actually true.
    /// `encode(to:)` stays compiler-synthesized (unaffected by a custom `init(from:)`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glucose = try c.decodeIfPresent(Int.self, forKey: .glucose)
        glucoseDate = try c.decodeIfPresent(Date.self, forKey: .glucoseDate)
        trendArrow = try c.decodeIfPresent(String.self, forKey: .trendArrow) ?? ""
        iobUnits = try c.decodeIfPresent(Double.self, forKey: .iobUnits) ?? 0
        reservoirUnits = try c.decodeIfPresent(Double.self, forKey: .reservoirUnits) ?? 0
        batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent) ?? 0
        // Phase 09.27-02 (D-05): a legacy/missing key falls back to `false` (not charging) — mirrors
        // `deliverySuspended`'s own fail-closed default; an older widget-extension binary never shows
        // a fabricated charging badge from a missing key.
        batteryCharging = try c.decodeIfPresent(Bool.self, forKey: .batteryCharging) ?? false
        lastBolusUnits = try c.decodeIfPresent(Double.self, forKey: .lastBolusUnits)
        lastBolusDate = try c.decodeIfPresent(Date.self, forKey: .lastBolusDate)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        recentPoints = try c.decodeIfPresent([Point].self, forKey: .recentPoints) ?? []
        activeAlerts = try c.decodeIfPresent([String].self, forKey: .activeAlerts) ?? []
        cgmActive = try c.decodeIfPresent(Bool.self, forKey: .cgmActive) ?? false
        carbRatio = try c.decodeIfPresent(Double.self, forKey: .carbRatio) ?? 0
        isf = try c.decodeIfPresent(Int.self, forKey: .isf) ?? 0
        targetBg = try c.decodeIfPresent(Int.self, forKey: .targetBg) ?? 0
        maxBolusUnits = try c.decodeIfPresent(Double.self, forKey: .maxBolusUnits) ?? 0
        staleAfterSec = try c.decodeIfPresent(TimeInterval.self, forKey: .staleAfterSec)
        hideAfterSec = try c.decodeIfPresent(TimeInterval.self, forKey: .hideAfterSec)
        displayUnit = try c.decodeIfPresent(String.self, forKey: .displayUnit)
        iobDate = try c.decodeIfPresent(Date.self, forKey: .iobDate)
        basalRateUnitsPerHour = try c.decodeIfPresent(Double.self, forKey: .basalRateUnitsPerHour) ?? 0
        deliverySuspended = try c.decodeIfPresent(Bool.self, forKey: .deliverySuspended) ?? false
        controlIQMode = try c.decodeIfPresent(Int.self, forKey: .controlIQMode) ?? 0
        controlIQEnabled = try c.decodeIfPresent(Bool.self, forKey: .controlIQEnabled) ?? false
        hasSnoozeEligibleAlert = try c.decodeIfPresent(Bool.self, forKey: .hasSnoozeEligibleAlert) ?? false
        // Owner-requested toggle: a legacy snapshot missing the key ⇒ false (labels hidden), matching
        // the setting's own default-OFF — mirrors every other additive-optional field's fallback above.
        showUnitLabel = try c.decodeIfPresent(Bool.self, forKey: .showUnitLabel) ?? false
        // Phase 09.9-04 (D-05): a legacy snapshot missing the key ⇒ true (safe "ready" default) — an
        // older widget extension binary never shows a false cartridge-not-ready scare.
        cartridgeReady = try c.decodeIfPresent(Bool.self, forKey: .cartridgeReady) ?? true
    }

    /// modern glucose bands. 0 = low, 1 = in-range, 2 = high, 3 = urgent-high, -1 = unknown.
    /// Uses the same **closed clinical convention** as `faBolusCore.GlucoseRange` (70…180 in-range,
    /// 181…250 high, > 250 urgent); the boundaries come from `WidgetGlucoseThresholds` (the widget
    /// island's mirror of the canonical constants). Kept in lockstep with the core classifier by
    /// `WidgetGlucoseThresholdsMirrorTests`.
    public static func rangeCategory(_ mgdl: Int?) -> Int {
        guard let g = mgdl else { return -1 }
        switch g {
        case ..<WidgetGlucoseThresholds.low: return 0  // < 70
        case WidgetGlucoseThresholds.low...WidgetGlucoseThresholds.high: return 1  // 70…180
        case (WidgetGlucoseThresholds.high + 1)...WidgetGlucoseThresholds.veryHigh: return 2  // 181…250
        default: return 3  // > 250
        }
    }
    public var rangeCategory: Int { Self.rangeCategory(glucose) }

    /// Clock-skew tolerance for **future-dated** readings — mirrors `faBolusCore.GlucoseFreshness.
    /// futureSkewTolerance` (5 min). The widget/complication extensions deliberately don't link
    /// faBolusCore (see the note on `WidgetGlucoseThresholds`), so the value is carried here; the app
    /// test target links both and pins this equal to the canonical one so they can't drift silently. A
    /// reading dated more than this far in the FUTURE came from a source with a fast clock — its true
    /// age is unknowable, so it is treated as stale and never shown as the live value (loop-comms audit
    /// fix #1). Without the guard a future-dated reading has negative elapsed time and reads "fresh"
    /// forever, so the widget/complication would render it as the current value.
    public static let futureSkewTolerance: TimeInterval = 5 * 60

    /// True when the reading is stale — older than 6 minutes, or dated more than `futureSkewTolerance`
    /// in the future (a fast source clock) — so the number must not be shown as the live value.
    public var isGlucoseStale: Bool {
        guard let d = glucoseDate else { return glucose != nil }
        let elapsed = Date().timeIntervalSince(d)
        if elapsed < -Self.futureSkewTolerance { return true }  // future-dated beyond skew → stale
        return elapsed > 6 * 60
    }

    // Time-parameterized freshness honoring the publisher's policy — evaluated against the widget
    // entry's date (not wall-clock `Date()`, which in a widget is prep time, not the display time).
    private var staleLimit: TimeInterval { staleAfterSec ?? 6 * 60 }
    /// Stale (show greyed) at `now`, per the published stale threshold — or future-dated beyond the
    /// clock-skew tolerance, which is likewise never presented as the live value.
    public func isStale(asOf now: Date) -> Bool {
        guard let d = glucoseDate else { return glucose != nil }
        let elapsed = now.timeIntervalSince(d)
        if elapsed < -Self.futureSkewTolerance { return true }  // future-dated beyond skew → stale
        return elapsed > staleLimit
    }
    /// Hidden ("--") at `now`: past the published hide delay (nil delay = never hide). A future-dated
    /// reading is stale (shown greyed with its age), not hidden — matching the shared policy's `.stale`.
    public func isHidden(asOf now: Date) -> Bool {
        guard glucose != nil, let d = glucoseDate, let hide = hideAfterSec else { return false }
        let elapsed = now.timeIntervalSince(d)
        if elapsed < -Self.futureSkewTolerance { return false }  // future-dated → stale, not hidden
        return elapsed >= Swift.max(hide, staleLimit)
    }
    /// WR-02 (R2-09) TTL for the `connected` flag + the dateless pump metrics (iob/reservoir/battery/
    /// basal). Unlike glucose (keyed off `glucoseDate`, the sample time), those values carry no intrinsic
    /// timestamp — they age ONLY against `updatedAt` (publish time). If the host is killed, no publish
    /// re-stamps `updatedAt`, so past this TTL the persisted snapshot's connection state is no longer
    /// trustworthy. Chosen to mirror the glucose stale window (well beyond the ~20 s publish heartbeat, so
    /// normal operation never trips it) while greying a host-killed snapshot within a few minutes.
    public static let connectionStaleAfter: TimeInterval = 6 * 60

    /// True when the snapshot's publish time (`updatedAt`) is older than `connectionStaleAfter` at `now` —
    /// i.e. the host stopped re-publishing (killed/suspended long enough). Keyed off `updatedAt`, NOT
    /// `glucoseDate`. Callers treat `!connected || isConnectionStale(asOf:)` as not-connected so the
    /// connection chip stops reading "connected" and the dateless pump metrics grey once the snapshot ages.
    public func isConnectionStale(asOf now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.connectionStaleAfter
    }

    /// Glucose string, or "--" when missing/stale. A non-positive value is treated as "no reading"
    /// (defends the complication against ever rendering a literal "0").
    public var displayGlucose: String {
        guard let g = glucose, g > 0, !isGlucoseStale else { return "--" }
        return "\(g)"
    }

    public static let placeholder = WidgetSnapshot(
        glucose: 124, glucoseDate: Date(), trendArrow: "→", iobUnits: 1.2, reservoirUnits: 142, batteryPercent: 80,
        lastBolusUnits: 2.5, lastBolusDate: Date().addingTimeInterval(-1800), connected: true,
        recentPoints: (0..<24).map {
            .init(t: Date().addingTimeInterval(Double($0 - 24) * 300), mgdl: 110 + ($0 % 6) * 8)
        })
}

/// App Group–backed store for the widget snapshot. Both the app and the widget read/write here.
public enum WidgetStore {
    /// The shared App Group container id. Read from the target's Info.plist (`AppGroupIdentifier`,
    /// build-substituted from `group.$(APP_BUNDLE_ID)`) so it always matches the entitlement — even
    /// when a self-compiler overrides `APP_BUNDLE_ID`. Falls back to the default id if the key is
    /// somehow absent. Every target that touches this container carries the key (see project.yml).
    public static let appGroup: String =
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)
        .flatMap { $0.isEmpty ? nil : $0 } ?? "group.com.fabolus.app"
    private static let key = "widgetSnapshot"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    public static func save(_ s: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        defaults?.set(data, forKey: key)
    }

    // Phase 7 (07-03, FEAT-05, D-08): `requestOpenBolus()`/`takeOpenBolusRequest()` are removed —
    // their entire reason to exist was a Shortcuts "Open Bolus Screen" action (the deleted
    // `OpenBolusScreenIntent` in the now-git-rm'd Intents surface), which was `requestOpenBolus()`'s
    // ONLY caller anywhere in the app (confirmed via repo-wide grep — a Rule 1/2 dangling-round-trip
    // finding, not in RESEARCH's file list). `AppModel.swift`'s `openBolusRequested` flag and
    // `RootTabView.swift`'s consumer of it are UNTOUCHED — they stay legitimately live, fed by the
    // separate, still-present `fabolus://bolus` URL-scheme trigger (`App.swift`).
    public static func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

/// A bolus the Quick-Bolus widget has confirmed (1-2-3) and handed to the app to deliver through
/// the validated signed path. The widget can't drive Bluetooth, so it writes this to the App Group
/// and opens the app, which delivers it (like a Garmin remote bolus) and shows progress + cancel.
public struct WidgetBolusRequest: Codable, Sendable, Equatable {
    /// The amount as entered: units when `mode == "units"`, grams of carbs when `"carbs"`. The app
    /// converts carbs→units with the pump's calculator before delivering.
    public var amount: Double
    public var mode: String
    public var requestId: String
    public var createdAt: Date
    public init(amount: Double, mode: String, requestId: String, createdAt: Date) {
        self.amount = amount
        self.mode = mode
        self.requestId = requestId
        self.createdAt = createdAt
    }
}

/// Live delivery status the app writes back so the widget can show progress + a cancel button in
/// place (without opening the app).
///
/// CX-F-09: `.expired` is an explicit "the host never finalized this" outcome, distinct from `.idle`. A
/// `.delivering` status the host process never got to finalize (killed mid-delivery, before
/// `WidgetBolusReceiver` writes `.delivered`/`.cancelled`/`.failed`) is stuck forever from the widget's
/// point of view. Silently reverting that to `.idle` erases the request identity/units and re-presents the
/// 1-2-3 pad as if nothing had happened — inviting a fresh, possibly-duplicate re-bolus while the
/// ORIGINAL dose's outcome is genuinely unknown. `.expired` preserves identity/units and reads as "check
/// the pump/history," never as an automatically-safe retry. See `WidgetBolusStore.status()`.
public enum WidgetBolusPhase: String, Codable, Sendable { case idle, delivering, delivered, cancelled, failed, expired }
public struct WidgetBolusStatus: Codable, Sendable, Equatable {
    public var phase: WidgetBolusPhase
    public var units: Double  // requested
    public var deliveredUnits: Double
    public var requestId: String
    public var updatedAt: Date
    public var message: String
    public init(
        phase: WidgetBolusPhase, units: Double = 0, deliveredUnits: Double = 0,
        requestId: String = "", updatedAt: Date = Date(), message: String = ""
    ) {
        self.phase = phase
        self.units = units
        self.deliveredUnits = deliveredUnits
        self.requestId = requestId
        self.updatedAt = updatedAt
        self.message = message
    }
    public static let idle = WidgetBolusStatus(phase: .idle)
}

/// App Group–backed state for the Quick-Bolus widget's 1-2-3 confirmation. The widget records tap
/// progress (reset on a wrong/late tap) and, on completing 1→2→3, a pending request + a Darwin
/// notification the app (running in the background with the pump connected) picks up to deliver —
/// writing status back so the widget shows progress + cancel in place. Mirrors the Garmin
/// hold/tap confirm: the widget confirms, the phone delivers.
public enum WidgetBolusStore {
    private static var d: UserDefaults? { UserDefaults(suiteName: WidgetStore.appGroup) }
    /// Seconds allowed to complete the 1-2-3 sequence before it resets (a stray tap can't linger).
    public static let confirmTTL: TimeInterval = 20
    /// The app must consume a completed request within this window (else it's ignored as stale).
    public static let pendingTTL: TimeInterval = 120
    /// VA-26: only DELIVER a units-mode widget bolus in place when it's this fresh (a live Darwin
    /// handoff, age ~0). Older-but-still-within-`pendingTTL` requests (a suspended-app foreground
    /// fallback) are converted to an in-app re-confirm rather than auto-dosing up to ~2 min late.
    public static let promptTTL: TimeInterval = 15
    /// Darwin notification names that wake the app to deliver / cancel a widget bolus.
    public static let darwinPending = "com.fabolus.app.widgetBolus"
    public static let darwinCancel = "com.fabolus.app.widgetBolusCancel"

    // --- Config mirrored from the app so the widget can build the amount picker ---
    /// Units step for the +/- buttons (from Settings' bolus increment). Defaults to 0.05.
    public static var increment: Double {
        get {
            let v = d?.double(forKey: "wbIncrement") ?? 0
            return v > 0 ? v : 0.05
        }
        set { d?.set(newValue, forKey: "wbIncrement") }
    }
    /// Grams step for the +/- buttons in carbs mode. Defaults to 5 g.
    public static var carbIncrement: Double {
        get {
            let v = d?.double(forKey: "wbCarbIncrement") ?? 0
            return v > 0 ? v : 5
        }
        set { d?.set(newValue, forKey: "wbCarbIncrement") }
    }
    /// The pump's max bolus (clamp for the amount picker). Defaults to 25 U.
    public static var maxBolus: Double {
        get {
            let v = d?.double(forKey: "wbMaxBolus") ?? 0
            return v > 0 ? v : 25.0
        }
        set { d?.set(newValue, forKey: "wbMaxBolus") }
    }
    /// Max carbs entry (grams). Fixed cap mirroring the Garmin remote.
    public static let maxCarbs: Double = 200
    /// Default entry mode ("units"/"carbs") from Settings; the entry starts here.
    public static var defaultMode: String {
        get { d?.string(forKey: "wbDefaultMode") ?? "carbs" }
        set { d?.set(newValue, forKey: "wbDefaultMode") }
    }

    // --- Bolus lock (A-05) — mirrored from the app's single AccessPolicy evaluator ---
    /// Whether bolusing from the Quick-Bolus widget is currently refused (phone read-only, or child mode
    /// with `.bolus` disallowed). The app computes this from `AppModel.accessDecision(.deliverBolus,
    /// from: .quickBolusWidget)` — the evaluator is the single source of truth — and publishes it here so
    /// the widget can grey/disable its entry + confirm pad instead of showing controls that then fail
    /// host-side. The widget MUST only read this flag; it must not re-derive the gate.
    public static var bolusLocked: Bool {
        get { d?.bool(forKey: "wbBolusLocked") ?? false }
        set { d?.set(newValue, forKey: "wbBolusLocked") }
    }
    /// Short, widget-sized reason for the lock (e.g. "Read-only mode"), or "" when unlocked. Presentation
    /// only — a shortened form of the evaluator's `DenialReason`, mapped app-side (see WidgetPublisher).
    public static var bolusLockReason: String {
        get { d?.string(forKey: "wbBolusLockReason") ?? "" }
        set { d?.set(newValue, forKey: "wbBolusLockReason") }
    }

    // --- Entry state: two stages (choose amount → 1-2-3 confirm), like the Garmin flow ---
    /// "amount" (adjust the dose) or "confirm" (the 1-2-3 pad). Defaults to "amount".
    public static var stage: String {
        get { d?.string(forKey: "wbStage") ?? "amount" }
        set { d?.set(newValue, forKey: "wbStage") }
    }
    /// Current entry mode: "units" or "carbs" (togglable on the amount stage).
    public static var mode: String {
        get { d?.string(forKey: "wbMode") ?? defaultMode }
        set { d?.set(newValue, forKey: "wbMode") }
    }
    /// The amount being entered — units when mode == "units", grams when "carbs".
    public static var draft: Double {
        get { d?.double(forKey: "wbDraft") ?? 0 }
        set { d?.set(newValue, forKey: "wbDraft") }
    }
    /// Reset the whole entry back to the amount stage at zero, in the default mode.
    public static func resetEntry() {
        stage = "amount"
        mode = defaultMode
        draft = 0
        resetProgress()
    }

    /// Current confirm progress (0/1/2), or 0 if it has timed out.
    public static func progress() -> Int {
        guard let d else { return 0 }
        let at = d.double(forKey: "wbProgAt")
        if at == 0 || Date().timeIntervalSince1970 - at > confirmTTL { return 0 }
        return d.integer(forKey: "wbProg")
    }
    public static func setProgress(_ n: Int) {
        d?.set(n, forKey: "wbProg")
        d?.set(Date().timeIntervalSince1970, forKey: "wbProgAt")
    }
    public static func resetProgress() {
        d?.set(0, forKey: "wbProg")
        d?.set(0.0, forKey: "wbProgAt")
    }

    public static func setPending(_ r: WidgetBolusRequest) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        d?.set(data, forKey: "wbPending")
    }
    /// Read and clear the pending request (returns nil if none or older than `pendingTTL`).
    public static func takePending() -> WidgetBolusRequest? {
        guard let data = d?.data(forKey: "wbPending"),
            let r = try? JSONDecoder().decode(WidgetBolusRequest.self, from: data)
        else { return nil }
        d?.removeObject(forKey: "wbPending")
        return Date().timeIntervalSince(r.createdAt) > pendingTTL ? nil : r
    }

    // --- Cancel authentication (VA-28) — give the cancel path the same App-Group corroboration the
    // deliver path already has via setPending/takePending. A Darwin post is system-wide, unauthenticated,
    // and payload-less, so a co-resident app could otherwise fire cancelBolus with a bare post. The
    // widget's own cancel button writes this single-use, TTL-bounded token BEFORE posting; the receiver
    // consumes it. A co-resident app cannot write the App-Group container, so a blind post finds no token.
    public static func setCancelIntent(requestId: String) {
        d?.set(requestId, forKey: "wbCancelReq")
        d?.set(Date().timeIntervalSince1970, forKey: "wbCancelAt")
    }
    /// Read-and-clear; true only if written within `confirmTTL` (single-use).
    public static func takeCancelIntent() -> Bool {
        guard let d else { return false }
        let at = d.double(forKey: "wbCancelAt")
        d.removeObject(forKey: "wbCancelReq")
        d.removeObject(forKey: "wbCancelAt")  // consume
        return at != 0 && Date().timeIntervalSince1970 - at <= confirmTTL
    }

    /// Delivery status the app writes and the widget renders.
    public static func setStatus(_ s: WidgetBolusStatus) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        d?.set(data, forKey: "wbStatus")
    }
    /// CX-F-09: how long a `.delivering` status can go unfinalized before `status()` surfaces it as
    /// `.expired` instead of silently reverting to `.idle`. Kept at the same 90 s window this file already
    /// used for the (previously silent) "delivering" freshness cutoff — a host mid-delivery legitimately
    /// takes a few seconds, so this stays generous, but a host process killed outright never comes back to
    /// finalize it, and the widget must not hide that indefinitely behind a blank, ready-to-bolus `.idle`.
    public static let deliveringExpiryTTL: TimeInterval = 90
    public static func status() -> WidgetBolusStatus {
        guard let data = d?.data(forKey: "wbStatus"),
            let s = try? JSONDecoder().decode(WidgetBolusStatus.self, from: data)
        else { return .idle }
        let age = Date().timeIntervalSince(s.updatedAt)
        if s.phase == .delivering {
            // CX-F-09: past the expiry window, surface an EXPLICIT `.expired` status — same requestId/units
            // as the stuck `.delivering` one — instead of collapsing to `.idle` (which erased identity and
            // invited a fresh re-bolus while the original outcome was still unknown). Nothing is persisted
            // here; this is computed fresh on every read, so a later app-side finalize (a relaunch that
            // reconciles and calls `setStatus` with a terminal phase) still takes effect immediately.
            guard age > deliveringExpiryTTL else { return s }
            return WidgetBolusStatus(
                phase: .expired, units: s.units, deliveredUnits: s.deliveredUnits,
                requestId: s.requestId, updatedAt: s.updatedAt,
                message: "Outcome unknown — check your pump/history before dosing again")
        }
        // A terminal status (delivered/cancelled/failed) older than 15 s reverts to idle so the widget
        // returns to the 1-2-3 state on its own. `.expired` is synthesized above on every read (never
        // persisted), so it is not reachable here.
        return age > 15 ? .idle : s
    }
}

/// Deep links the widgets use to open the app. `bolus` opens the bolus-entry sheet (tap-to-bolus
/// is a link into the app's confirm flow — never a one-tap dispense).
public enum FaBolusDeepLink {
    public static let scheme = "fabolus"
    public static let bolus = URL(string: "fabolus://bolus")!
    public static let open = URL(string: "fabolus://open")!
}
