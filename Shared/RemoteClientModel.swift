import Foundation
import faBolusCore
import Observation
import WidgetKit

/// Transport-agnostic remote-client state shared by every faBolus remote that mirrors the phone
/// (Apple Watch over `RemoteLink`, Mac/iPhone over `BLELink`). It is a *dumb remote*: it never touches the
/// pump (TandemKit runs on the phone). It sends bolus/cancel/dismiss/status commands and reflects the
/// status the phone echoes back, and publishes the latest glucose/pump state to the App Group for
/// this device's widgets/complication.
///
/// Not `final` so a platform can subclass it to add device-specific behavior (e.g. the watch's
/// direct-CGM failover); override `reachabilityDidChange(_:)` and call `super`.
@MainActor
@Observable
class RemoteClientModel {
    // Glucose
    var glucose: Int?
    var glucoseDate: Date?             // for staleness
    var trend: String = "→"           // Unicode arrow
    var history: [Int] = []            // recent mg/dL, oldest→newest (for the chart)
    var historyDates: [Date] = []      // real timestamp per history point (same length), when the host sends them
    // Pump status
    var iobUnits: Double = 0
    var reservoirUnits: Double = 0
    var batteryPercent: Int = 0
    var lastBolusUnits: Double?
    var basalRate: Double = 0          // units/hr, mirrored from the host
    var connection: String = ""
    // Calculator settings (mirrored from the phone)
    var carbRatio: Double = 0
    var isf: Int = 0
    var targetBg: Int = 0
    var maxBolusUnits: Double = 25
    /// DIF-ux — the pump's own read times of the calc inputs, relayed as immutable source epochs
    /// (`iobEpochSec` / `therapyEpochSec`), so this remote greys/ages its IOB + therapy rows and PRE-WARNS
    /// exactly like the host. `nil` ⇒ the host didn't send one (legacy host) ⇒ age UNKNOWN ⇒ stale, never
    /// fresh. A remote only VIEWS these — it never offers an include-last-known override and never sends one;
    /// the host stays the authoritative dose gate.
    var iobDate: Date?
    var therapyDate: Date?
    // Entry prefs (from phone Settings — the remote increments)
    var bolusIncrement: Double = 0.05
    var carbIncrement: Double = 5
    var defaultMode: String = "carbs"
    // Customization mirrored from the phone.
    var detailsOrder: [String] = ["iob", "reservoir", "battery", "cgm", "lastBolus", "carbRatio", "isf", "target", "maxBolus"]
    var chartRanges: [Int] = [3, 6, 12, 24]
    /// Read-only mode pushed from the phone (watch/Garmin view-only): hide the bolus affordance.
    var readOnly: Bool = false
    /// P13 capability channel: whether the pump honors a REMOTE alert dismissal (Mobi yes, t:slim no).
    /// Drives the alert action label ("Clear" vs "Snooze"). Safe default false ⇒ "Snooze" (honest — a
    /// t:slim dismiss only snoozes locally); set by the first statusRead that carries any alert anyway.
    var canDismissAlertOnPump: Bool = false
    /// P14 S4: the phone's active app mode, so this remote can HIDE an affordance the phone's mode would
    /// deny (e.g. an extended/combo bolus needs Advanced) instead of showing-then-failing. Default
    /// `.advanced` (most-permissive): an absent field means a LEGACY host that never mode-gates, so the
    /// remote must not over-hide. The host remains the enforcement point on every actual write.
    var activeMode: AppMode = .advanced
    /// P15 §2.3: whether the phone has enabled bolusing from the Apple Watch (`watchBolusEnabled`) — the
    /// watch consumes this. `garminBolusEnabled` is carried for completeness (the Garmin app parses its own
    /// copy). **Default false ⇒ fail-closed**: a cold launch / glance with no push yet keeps bolus hidden
    /// until a push arms it. The host also refuses a deliver from a disabled surface (AccessPolicy).
    var watchBolusEnabled: Bool = false
    var garminBolusEnabled: Bool = false
    /// P15 §2.3: whether the phone requires a 4-digit passcode to confirm a remote bolus.
    var bolusPasscodeRequired: Bool = false
    /// B2 (S1+O3): the pump's automated-controller identity, mirrored from the phone so this remote can
    /// reconstruct the `ControllerDescriptor` and render the auto-correction disclosure locally. Safe
    /// default `.none` ⇒ a legacy host (or none-controller pump) shows nothing controller-specific.
    var controllerVariant: ControllerVariant = .none
    /// B2 (S1+O3): whether Control-IQ is ON at runtime, mirrored from the phone. The disclosure renders only
    /// when the variant can auto-correct AND this is true. Safe default false ⇒ render no disclosure.
    var controlIQEnabled: Bool = false

    /// B2 (S1+O3) — the pump's controller descriptor, reconstructed locally from the mirrored variant. The
    /// two disclosure strings below are derived from it exactly as the phone's `BolusEntryView` does, so
    /// every surface shows the same facts from one faBolusCore source (no prose crosses the wire).
    var controllerDescriptor: ControllerDescriptor { .for(controllerVariant) }
    /// O3 — the persistent "automatic correction is active" line, or nil when it shouldn't show.
    var autoCorrectionAmbient: String? {
        AutoCorrectionDisclosure.ambientIndicator(descriptor: controllerDescriptor,
                                                  controllerEnabled: controlIQEnabled)
    }
    /// S1 — the high/rising auto-correction lockout disclosure, or nil. Uses the pump's OWN mirrored trend
    /// arrow (C8: read, never synthesized) — `GlucoseTrend(rawValue:)` since the wire trend is the arrow.
    var autoCorrectionLockout: String? {
        AutoCorrectionDisclosure.lockoutMessage(descriptor: controllerDescriptor,
                                                controllerEnabled: controlIQEnabled,
                                                glucoseMgdl: glucose,
                                                trend: GlucoseTrend(rawValue: trend))
    }
    /// P15 §2.3 (watch): the watch may show/permit its bolus affordance only when remotes aren't read-only
    /// AND the phone has enabled watch bolusing. Fail-closed by default (`watchBolusEnabled` starts false).
    /// The Mac has its own gating and does not use this.
    var watchBolusAllowed: Bool { !readOnly && watchBolusEnabled }
    // Alerts + link
    var alerts: [RemoteCommand.RemoteAlert] = []
    /// Identities (kind+id) of the previous alert set, to detect a newly-arrived alert. `nil` until the
    /// first status push arrives, so the priming load doesn't fire the interrupt (S8).
    private var lastAlertIdentities: Set<String>?
    var reachable: Bool = false
    var lastStatus: RemoteCommand.Status?
    var statusMessage: String?
    var pendingRequestId: String?
    /// A bolus the host started that's awaiting THIS remote's approval (reverse approval): (id, units).
    var incomingApproval: (requestId: String, units: Double)?

    /// Whether the phone has been seen bolusing since this request started — so a lost/late terminal
    /// echo can be recovered from the connection state (see handle(.statusRead)).
    @ObservationIgnored private var sawPhoneBolusing = false

    @ObservationIgnored let link: any RemoteTransport

    init(link: any RemoteTransport) {
        self.link = link
        link.onReachabilityChange = { [weak self] r in self?.reachabilityDidChange(r) }
        link.onReceive = { [weak self] cmd in self?.handle(cmd) }
        link.onUndeliverable = { [weak self] cmd in self?.sendDidFail(cmd) }
        reachable = link.isReachable
    }

    /// A pump-mutating command never reached the host. These are deliberately not queued (a bolus that
    /// lands minutes late is a double-dose hazard), so the only safe thing is to tell the user it was
    /// **not sent** — never to leave the screen on "Delivering…" waiting for an echo that cannot come.
    /// Nothing was sent, so there is nothing to reconcile: this is a true `.failed`, not `.unknown`.
    private func sendDidFail(_ cmd: RemoteCommand) {
        switch cmd.kind {
        case .bolusRequest:
            guard cmd.requestId == pendingRequestId else { return }
            pendingRequestId = nil
            sawPhoneBolusing = false
            lastStatus = .failed
            statusMessage = "Not sent — the phone wasn't reachable. Nothing was delivered."
        case .cancelBolus:
            statusMessage = "Cancel not sent — the phone wasn't reachable. Check the pump."
        case .dismissAlert, .suspendPump, .resumePump:
            statusMessage = "Not sent — the phone wasn't reachable."
        default:
            break
        }
    }

    /// True when the host reports the pump actively connected (or mid-delivery) — the gate for any
    /// action that needs the pump. Mirrors the host's `pumpReady`; the strings are
    /// `PumpConnectionState.rawValue` ("Connected" / "Delivering…").
    var pumpConnected: Bool { connection == "Connected" || connection == "Delivering…" }

    /// True when the host reports the pump mid-delivery — a dose is already in flight, so no remote may
    /// start another (the `BolusGate` in-flight gate, v3 defect group D). This is the relayed twin of the
    /// phone's `PumpSnapshot.bolusInFlight`: `.bolusing` is still "linked" (`pumpConnected` is true), so a
    /// caller reads link health and in-flight as separate axes and feeds both to `BolusGate.evaluate`.
    var bolusInFlight: Bool { connection == PumpConnectionState.bolusing.rawValue }

    /// The shared `BolusGate` decision for THIS remote, fed from the relayed pump state so every mirroring
    /// remote agrees (v3 defect group D): reachability, link health (`pumpConnected`), a dose already in
    /// flight (`bolusInFlight`), and the phone-pushed read-only flag (→ `.deny(.remotesReadOnly)` — the
    /// remote judges read-only locally pre-wire; the semantic `canBolus` over the wire is a later
    /// increment). `amount`/`minimum` are in insulin units; the max is the relayed `maxBolusUnits`.
    /// (The Mac feeds `BolusGate` inline instead, because its single control spans carbs grams + units.)
    func bolusGate(amount: Double, minimum: Double) -> (canBolus: Bool, reason: BolusBlockReason?) {
        let access: AccessPolicy.AccessDecision = readOnly ? .deny(.remotesReadOnly) : .allow
        return BolusGate.evaluate(reachable: reachable, linked: pumpConnected, bolusInFlight: bolusInFlight,
                                  amount: amount, minimum: minimum,
                                  maximum: maxBolusUnits > 0 ? maxBolusUnits : 25, access: access)
    }

    /// Whether this remote may start a bolus AT ALL right now — reachability + pump link + not-in-flight +
    /// not read-only — independent of any entered amount, for gating the "open bolus" affordance. Amount
    /// bounds are then checked on the entry screen via `bolusGate(amount:minimum:)`. (`amount`/`minimum`
    /// both 0 so the bounds always pass and only the surface gates decide.)
    var bolusAvailability: (canBolus: Bool, reason: BolusBlockReason?) { bolusGate(amount: 0, minimum: 0) }

    /// Called when the link's reachability changes. Base updates `reachable`; subclasses override to
    /// add behavior (e.g. start/stop a direct-CGM failover) and must call `super`.
    func reachabilityDidChange(_ r: Bool) { reachable = r }

    /// Called when a status push carries an alert identity (kind+id) not present in the previous push — a
    /// newly-arrived pump alert. Base is a no-op; platform subclasses override to actively surface it
    /// (watch haptic, Mac sound), since these surfaces otherwise render alerts as a silent list (S8).
    func didSurfaceNewAlerts(_ newAlerts: [RemoteCommand.RemoteAlert]) {}

    // MARK: Derived display

    /// Stale per the shared `GlucoseFreshness` threshold (default 6 min). A stale reading is shown
    /// but marked (grayed + age), never hidden — "old is worse than nothing".
    var isGlucoseStale: Bool {
        guard let d = glucoseDate else { return glucose != nil }
        return GlucoseFreshness.isStale(d)
    }
    var displayGlucose: String { glucose.map { "\($0)" } ?? "—" }
    /// True when the reading is old enough that the phone's hide policy (`glucoseHideDelayMinutes`)
    /// says to hide it ("—") rather than show it greyed — mirrors the phone/watch presentation.
    var glucoseHidden: Bool { glucose != nil && GlucoseFreshness.presentation(of: glucoseDate) == .hidden }
    var cgmActive: Bool { glucose != nil && !isGlucoseStale }
    /// P15 Addendum B: whether a carb bolus should present the three-way stale-CGM choice before it is
    /// composed — i.e. a stale-but-REAL reading exists (there is something to include or drop). No reading
    /// at all is simply carbs-only (nothing to include); a fresh reading composes normally. Delegates to
    /// the shared `StaleBolusPrompt.shouldWarn` so every surface (iPhone/Watch/Mac/Garmin) agrees.
    var staleCarbWarnNeeded: Bool {
        StaleBolusPrompt.shouldWarn(glucoseMgdl: glucose, glucoseDate: glucoseDate)
    }
    var ageMinutes: Int? {
        guard let d = glucoseDate else { return nil }
        return max(0, Int(Date().timeIntervalSince(d) / 60))
    }
    /// Relative age label ("now", "3 min ago"), or nil when there's no reading yet.
    var ageLabel: String? { glucoseDate.map { GlucoseFreshness.ageLabel(for: $0) } }

    // DIF-ux calc-input freshness (view/pre-warn only — a remote never overrides). `nil` date ⇒ stale (age
    // unknown), mirroring `PumpSnapshot.isIobStale` / `isTherapyStale` and the host's `CalcInputFreshness`.
    var isIobStale: Bool { CalcInputFreshness.isIobStale(iobDate) }
    var isTherapyStale: Bool { CalcInputFreshness.isTherapyStale(therapyDate) }
    /// Compact age labels ("now", "7 min ago") for the IOB / therapy rows, or nil when the host sent no
    /// source epoch (legacy host).
    var iobAgeLabel: String? { iobDate.map { CalcInputFreshness.ageLabel(for: $0) } }
    var therapyAgeLabel: String? { therapyDate.map { CalcInputFreshness.ageLabel(for: $0) } }

    static func arrow(fromToken t: String?) -> String {
        switch t {
        case "up": return "↑"; case "upup": return "⇈"; case "up45": return "↗"
        case "down": return "↓"; case "downdown": return "⇊"; case "down45": return "↘"
        default: return "→"
        }
    }

    // MARK: Inbound

    func handle(_ cmd: RemoteCommand) {
        switch cmd.kind {
        case .bolusStatus:
            if cmd.requestId == pendingRequestId {
                lastStatus = cmd.status
                statusMessage = cmd.message
                // Reflect the actual delivered amount from the outcome echo immediately, so the
                // Details "Last bolus" shows the just-delivered value (e.g. 0.05 U) right away
                // instead of the previous bolus until the next status push arrives.
                if (cmd.status == .delivered || cmd.status == .cancelled), let d = cmd.deliveredUnits {
                    lastBolusUnits = d
                }
            }
        case .statusRead:
            // Treat a non-positive relayed value as "no reading" (nil) so the UI shows "—" instead of
            // a literal 0; a missing bgMgdl leaves the current value untouched.
            if let g = cmd.bgMgdl { glucose = g > 0 ? Int(g) : nil }
            // Group A: prefer the immutable source timestamp. Deriving the date from an age means
            // re-stamping relative to *our* clock at receive time, which silently discounts the time
            // the message spent in flight. Fall back to the age only for a host that doesn't send an
            // epoch yet. If neither is present the age stays unknown — `isGlucoseStale` then treats
            // the reading as stale rather than letting it read as fresh.
            if let e = cmd.glucoseEpochSec {
                glucoseDate = Date(timeIntervalSince1970: TimeInterval(e))
            } else if let age = cmd.glucoseAgeSec {
                glucoseDate = Date().addingTimeInterval(-age)
            }
            if let t = cmd.trend { trend = Self.arrow(fromToken: t) }
            if let iob = cmd.units { iobUnits = iob }
            if let r = cmd.reservoirUnits { reservoirUnits = r }
            if let b = cmd.batteryPercent { batteryPercent = Int(b) }
            if let cr = cmd.carbRatio { carbRatio = cr }
            if let i = cmd.isf { isf = Int(i) }
            if let tb = cmd.targetBg { targetBg = Int(tb) }
            // DIF-ux: adopt the immutable source epochs of the calc inputs, exactly like `glucoseEpochSec`.
            // Absent ⇒ leave nil ⇒ `isIobStale`/`isTherapyStale` treat the age as unknown ⇒ stale (never
            // fresh), so a legacy host that predates the fields can never make a remote render these fresh.
            iobDate = cmd.iobEpochSec.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            therapyDate = cmd.therapyEpochSec.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            if let mx = cmd.maxBolusUnits, mx > 0 { maxBolusUnits = mx }
            if let bi = cmd.bolusIncrement, bi > 0 { bolusIncrement = bi }
            if let ci = cmd.carbIncrement, ci > 0 { carbIncrement = ci }
            if let m = cmd.bolusMode { defaultMode = m }
            if let d = cmd.detailsOrder, !d.isEmpty { detailsOrder = d }
            if let r = cmd.watchChartRanges, !r.isEmpty { chartRanges = r }
            if let msg = cmd.message { connection = msg }
            // Recover from a lost/late terminal echo: once the phone has reported bolusing and then
            // reports it's no longer bolusing, the bolus is done even if the delivered/cancelled echo
            // never arrived — so we don't stay stuck in .delivering (which would also freeze "last
            // bolus"). Guarded by sawPhoneBolusing so the pre-bolus status push (phone not yet
            // bolusing) doesn't clear it prematurely.
            if connection == PumpConnectionState.bolusing.rawValue {
                sawPhoneBolusing = true
            } else if lastStatus == .delivering && sawPhoneBolusing {
                lastStatus = .delivered
            }
            if let h = cmd.history {
                history = h
                // Real per-point timestamps when the host sends them (accurate plot, honors gaps); else
                // clear so the chart falls back to the uniform-spacing estimate.
                historyDates = cmd.historyEpochs.map { $0.map { Date(timeIntervalSince1970: TimeInterval($0)) } } ?? []
            }
            // Don't overwrite last-bolus from a routine status push while a bolus is genuinely in
            // progress — that value is still the PREVIOUS bolus mid-delivery and would flicker
            // (e.g. 1.9 → 0.05). The .delivered/.cancelled echo (or the recovery above) settles it.
            if lastStatus != .delivering { lastBolusUnits = cmd.lastBolusUnits }
            if let b = cmd.basalRate { basalRate = b }
            if let ro = cmd.remotesReadOnly { readOnly = ro }
            if let d = cmd.supportsRemoteAlertDismiss { canDismissAlertOnPump = d }   // P13 capability channel
            // P14 S4: adopt the phone's active mode (absent ⇒ legacy host ⇒ stays the permissive default).
            if let m = cmd.activeMode { activeMode = AppMode(rawValue: m) ?? .advanced }
            // P15 §2.3: adopt the per-surface bolus enables + passcode requirement. Absent ⇒ legacy host ⇒
            // stays the safe default (false = bolus hidden), so an old host can never leave a remote armed.
            if let w = cmd.watchBolusEnabled { watchBolusEnabled = w }
            if let g = cmd.garminBolusEnabled { garminBolusEnabled = g }
            if let p = cmd.bolusPasscodeRequired { bolusPasscodeRequired = p }
            // B2 (S1+O3): adopt the pump's controller identity + runtime on/off. Absent ⇒ legacy host ⇒
            // stays the safe default (.none / false ⇒ no disclosure). Unknown token ⇒ .none (never crash).
            if let v = cmd.controllerVariant { controllerVariant = ControllerVariant(rawValue: v) ?? .none }
            if let e = cmd.controlIQEnabled { controlIQEnabled = e }
            if let a = cmd.alerts {
                // S8: watch/Mac otherwise render alerts as a silent list. Detect a newly-arrived alert by
                // identity (so an equal-count replacement still counts) and actively surface it — but not
                // on the priming first push (lastAlertIdentities == nil).
                let fresh = RemoteCommand.newAlertIdentities(previous: lastAlertIdentities ?? [], current: a)
                if lastAlertIdentities != nil, !fresh.isEmpty {
                    didSurfaceNewAlerts(a.filter { fresh.contains($0.identity) })
                }
                lastAlertIdentities = Set(a.map(\.identity))
                alerts = a
            }
            // Mirror the phone's staleness policy so the remote marks/hides + stops using stale
            // readings for carb→unit exactly like the phone.
            if let s = cmd.glucoseStaleMinutes { GlucoseFreshness.staleAfter = TimeInterval(s) * 60 }
            GlucoseFreshness.hideAfter = cmd.glucoseHideDelayMinutes.map { GlucoseFreshness.staleAfter + TimeInterval($0) * 60 }
            publishSnapshot()
        case .bolusApprovalRequest:
            incomingApproval = (cmd.requestId, cmd.units ?? 0)
        default:
            break
        }
    }

    /// Approve or deny a host-initiated bolus (reverse approval).
    func respondToApproval(_ approved: Bool) {
        guard let a = incomingApproval else { return }
        var cmd = RemoteCommand(kind: .bolusApprovalResponse, requestId: a.requestId)
        cmd.approved = approved
        cmd.sentAt = Int(Date().timeIntervalSince1970)   // group B (P11): freshness-gated (a late approval could dose)
        link.send(cmd)
        incomingApproval = nil
    }

    /// Publish the latest glucose/pump state to the App Group so this device's widgets/complication
    /// can show it. Reuses `WidgetSnapshot`/`WidgetStore` (a device-local App Group container).
    func publishSnapshot() {
        let snap = WidgetSnapshot(glucose: glucose, glucoseDate: glucoseDate, trendArrow: trend,
                                  iobUnits: iobUnits, reservoirUnits: reservoirUnits,
                                  batteryPercent: batteryPercent, lastBolusUnits: lastBolusUnits,
                                  connected: reachable, updatedAt: Date(),
                                  cgmActive: cgmActive, carbRatio: carbRatio, isf: isf,
                                  targetBg: targetBg, maxBolusUnits: maxBolusUnits)
        WidgetStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Outbound

    /// Send a units bolus the remote already confirmed (hold-to-deliver). The phone delivers it
    /// directly through the validated signed path (like the Garmin remote).
    func deliverUnits(_ units: Double) {
        startPending(RemoteCommand(kind: .bolusRequest, units: units))
    }

    /// The correction-term BG (mg/dL) a carb bolus should use, honoring the caller's per-attempt stale
    /// choice (P15 Addendum B). A FRESH reading is always used; a STALE reading is included only when the
    /// user has explicitly chosen `includeStale` for THIS attempt (insulin-INCREASING), otherwise dropped
    /// (today's carbs-only behavior); no reading at all is always `nil`. With `includeStale == false` this
    /// reduces exactly to the prior rule (`isGlucoseStale ? nil : glucose`).
    private func bgForBolus(includeStale: Bool) -> Int? {
        guard let g = glucose else { return nil }
        if !isGlucoseStale { return g }          // fresh: always used
        return includeStale ? g : nil            // stale: only on the explicit per-attempt choice
    }

    /// Send a carbs bolus; the host (phone) is the single calculator — it recomputes the authoritative
    /// dose from these carbs and delivers. We also include THIS client's own estimate so the host can
    /// reject the bolus if the two diverge (a stale-settings guard). A stale CGM value is normally never
    /// sent for the correction (matches the phone's rule) — but Addendum B lets the user explicitly
    /// include a stale-but-real reading for this one attempt (`includeStaleBG`, insulin-INCREASING). When
    /// it is a genuine stale-include we set the explicit `includeStaleBG` intent on the wire so the host
    /// can tell an acknowledged stale reading apart from a coincidentally-stale one. The host honors that
    /// intent only once it recomputes from its OWN matching stale reading (PR-2); until then — and on any
    /// legacy host that ignores the field — it fails closed to a carbs-only dose, so an included-stale
    /// estimate carrying a correction diverges and the host's guard rejects it. Covers Watch + Mac +
    /// remote-iPhone (shared base).
    func deliverCarbs(_ grams: Double, includeStaleBG: Bool = false) {
        let bg: Double? = bgForBolus(includeStale: includeStaleBG).map(Double.init)
        var cmd = RemoteCommand(kind: .bolusRequest, carbsGrams: grams, bgMgdl: bg)
        cmd.remoteEstimateUnits = estimatedUnits(forCarbs: grams, includeStaleBG: includeStaleBG)
        // Addendum B: carry the explicit per-attempt include-stale INTENT only when this genuinely IS a
        // stale-include — the user chose it AND the reading is stale-but-present. Never on a fresh reading,
        // never sticky; absent otherwise ⇒ the host fails closed to carbs-only.
        cmd.includeStaleBG = (includeStaleBG && isGlucoseStale && glucose != nil) ? true : nil
        startPending(cmd)
    }

    /// Preview of the units the phone would deliver for a carb amount — uses the single oracle-backed
    /// `BolusMath` calculator (audit C-01), so this estimate matches the host's authoritative recompute
    /// and the wrist-vs-host divergence guard rarely trips on identical inputs. Returns nil until the
    /// carb ratio is known. A stale CGM value isn't used for the correction (matches `deliverCarbs`)
    /// unless the caller passes `includeStaleBG` (Addendum B) — then the same stale value the dose will
    /// be composed with is used here too, so the preview and the host's divergence guard stay consistent.
    func estimatedUnits(forCarbs grams: Double, includeStaleBG: Bool = false) -> Double? {
        guard carbRatio > 0, grams > 0 else { return carbRatio > 0 ? 0 : nil }
        let bg: Int? = bgForBolus(includeStale: includeStaleBG)
        let profile = BolusMath.Profile(carbRatioGramsPerUnit: carbRatio, isfMgdlPerUnit: isf,
                                        targetBgMgdl: targetBg, iobUnits: iobUnits)
        let units = BolusMath.recommendedUnits(carbsGrams: grams, bgMgdl: bg, profile: profile)
        return (units * 20).rounded() / 20   // snap to 0.05 u for display/divergence parity
    }

    /// Send a bolus command and enter the pending/delivering state, correlating future echoes by its
    /// `requestId`. Internal so a subclass can drive it with a caller-supplied requestId (e.g. the
    /// Mac's widget quick-bolus, which must correlate the phone's echo to the widget request).
    func startPending(_ cmd: RemoteCommand) {
        var cmd = cmd
        cmd.sentAt = Int(Date().timeIntervalSince1970)   // group B (P11): stamp send time so the host refuses a stale/late delivery command
        pendingRequestId = cmd.requestId
        lastStatus = .delivering
        statusMessage = "Delivering…"
        sawPhoneBolusing = false
        link.send(cmd)
    }

    /// Send an extended (combo) bolus the remote already confirmed: `nowUnits` up front, the rest over
    /// `durationMinutes`. The host runs it through the same signed path as a standard bolus.
    func deliverExtended(totalUnits: Double, nowUnits: Double, durationMinutes: Int) {
        var cmd = RemoteCommand(kind: .bolusRequest, units: totalUnits)
        cmd.extendedNowUnits = nowUnits
        cmd.extendedMinutes = durationMinutes
        startPending(cmd)
    }

    func cancel() {
        guard let id = pendingRequestId else { return }
        link.send(RemoteCommand(kind: .cancelBolus, requestId: id))
    }

    func dismissAlert(_ a: RemoteCommand.RemoteAlert) {
        link.send(RemoteCommand(kind: .dismissAlert, alertId: a.id, alertKind: a.kind))
        alerts.removeAll { $0.id == a.id && $0.kind == a.kind }
    }

    func requestStatus() { link.send(RemoteCommand(kind: .statusRead)) }
    /// Request status and (optionally) ask the host to force a fresh CGM read first — used when opening
    /// the bolus screen so the estimate is off the newest value.
    func requestStatus(forceGlucose: Bool) {
        var c = RemoteCommand(kind: .statusRead); c.forceGlucose = forceGlucose; link.send(c)
    }
}
