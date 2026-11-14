import Alerts
import Foundation
import PumpSession
import RemoteHost
import WidgetContent
import faBolusCore

/// The Live Activity's bolus and alert screens, in the app: the watch's bolus flow (the amount with − and
/// +, the calculator's questions, a review, the 1 → 2 → 3 confirm, the phone's confirmations, the result
/// with Cancel) and its alert screen.
///
/// The Live Activity is a remote (`AccessPolicy.Surface.liveActivity`): its doses are composed by
/// `DoseComposer.composeRemote`, as the watch's are, and delivered through `AppModel.deliver`, the phone's
/// path into the ledger and the pump session. This holds only the screens and the user's answers; every
/// dose check is the composer's and the session's.
///
/// The Live Activity draws `panel`, a picture that may be out of date by the time it's tapped, so every tap
/// names the screen it was drawn on and one from any other screen is ignored. IDs are unique to this run of
/// the app, so a tap drawn before a relaunch never matches.
@MainActor
final class LiveActivityFlow {
    /// The ledger peer of the Live Activity's boluses.
    static let peerId = "liveActivity"
    /// A review is sent only this long after it appeared. The composer refuses a request over
    /// `RemoteRequestFreshness.maxAgeSec` old; this leaves time for the fresh pump read after the last tap.
    static let reviewLifetime: TimeInterval = 90
    /// A delivered result goes back to the card by itself after this long.
    static let deliveredLinger: TimeInterval = 60
    /// A cancel with no definite answer this long says to use the pump.
    static let cancelSlowAfter: TimeInterval = 5
    /// A cleared alert stays hidden this long, until the pump's list catches up.
    static let clearedAlertHide: TimeInterval = 60
    static let maxCarbsGrams = 200
    /// The dial's top when neither the remote limit nor the pump's max is known: not a dose limit.
    static let fallbackDialMaxMilliunits = 25_000
    static let coarseUnitsMilliunits = 1000
    static let coarseCarbsGrams = 10

    enum State {
        case idle
        case entry(Entry)
        case question(Question)
        case review(Review)
        case confirm(Review, [DoseConfirmation], units: Double)
        case result(Result)
        case alert(index: Int)
    }

    struct Entry: Equatable {
        var mode: BolusEntryMode
        /// Food entered as insulin units, with carbs off on the pump when it was started.
        var foodIsInsulin: Bool
        /// Milliunits, or grams for carbs.
        var value: Int
    }

    /// A choice between two whole doses, as the watch asks it.
    struct Question: Equatable {
        enum Kind: Equatable {
            case correction(above: Bool, targetMgdl: Int)
            case staleReading(measuredAt: Date)
        }
        var kind: Kind
        var entry: Entry
        var mgdl: Int
        var yesUnits: Double
        var noUnits: Double
    }

    /// What the user reviews, and what is sent if they confirm it.
    struct Review: Equatable {
        var entry: Entry
        var units: Double
        var split: String?
        var glucoseMgdl: Int?
        var includeStaleGlucose = false
        var declineCorrection = false
        var confirmed: Set<DoseConfirmation.Kind> = []
        /// Asked from this question: Back returns to it.
        var question: Question?
        /// When it appeared: the request's time, so a bolus from anywhere after it refuses it.
        var shownAt: Date
        var taps = 0

        var food: CalculatorFood? {
            switch entry.mode {
            case .units: nil
            case .carbs:
                entry.foodIsInsulin ? .insulin(units: Double(entry.value) / 1000) : .carbs(grams: Double(entry.value))
            }
        }
    }

    struct Result {
        enum Stage {
            /// Composing, then handing to the session.
            case sending
            case outcome(BolusOutcome)
            /// Nothing was sent, and why.
            case notSent(headline: String, reason: String)
        }
        var stage: Stage
        var units: Double?
        var key: RemoteBolusLedger.Key?
        var settledAt: Date?
    }

    unowned let model: AppModel
    private(set) var state: State = .idle {
        didSet { screenNumber += 1 }
    }
    private var screenNumber = 0
    /// Unique to this run of the app.
    private let runToken = String(UUID().uuidString.prefix(6))
    private var cancelling: (since: Date, answered: Bool)?
    /// A cancel tapped while one was with the session: it runs again once that one returns, because the
    /// first may have found nothing to stop before a delivery started (as the watch host does).
    private var cancelAgain = false
    /// A cancel tapped while the dose was still being composed: it's never handed to the session.
    private var cancelledBeforeStart = false
    private var clearNote: (alertId: String, note: String)?
    private var hiddenAlerts: [String: Date] = [:]

    init(model: AppModel) {
        self.model = model
    }

    var screenID: String { "\(runToken)-\(screenNumber)" }

    // MARK: Taps

    /// One tap from the Live Activity, once its step is done (through to the session's answer for a send).
    /// - Parameter unlocked: it came through the intent that needs an unlocked device.
    func handle(_ tap: LiveActivityTap, unlocked: Bool) async {
        defer { model.publishSurfaces() }
        // Cancel stops insulin: honoured from any screen, even one out of date.
        if tap.action == .cancelBolus {
            await cancelBolus()
            return
        }
        if tap.action == .cycleSpan {
            let options = LiveActivityLayout.plotRangeOptions
            let current = model.settings.liveActivityLayout.plotRangeHours
            let next = options.first { $0 > current } ?? options[0]
            model.settings.liveActivityLayout.plotRangeHours = next
            return
        }
        guard !tap.action.needsUnlock || unlocked else { return }
        guard tap.screen == screenID else {
            // Drawn before the app's last change, or before it relaunched: redrawn, nothing done. A send
            // asked of a screen this run never drew says so.
            if case .idle = state, tap.action == .tap(3) || tap.action == .goOn {
                state = .result(
                    Result(
                        stage: .notSent(headline: "Not sent", reason: Self.expiredScreenText), units: nil, key: nil,
                        settledAt: model.now))
            }
            return
        }
        await apply(tap.action)
    }

    static let expiredScreenText = "That screen had expired. Nothing was sent."

    private func apply(_ action: LiveActivityAction) async {
        switch (state, action) {
        case (.idle, .startBolus):
            if let refusal = availability {
                state = .result(
                    Result(
                        stage: .notSent(headline: "Can't bolus", reason: refusal.userMessage), units: nil, key: nil,
                        settledAt: model.now))
                return
            }
            state = .entry(Entry(mode: model.settings.defaultBolusMode, foodIsInsulin: model.screenCarbsOff, value: 0))
        case (.idle, .showAlerts):
            if !alerts.isEmpty { state = .alert(index: 0) }

        case (.entry(var entry), .switchMode):
            entry.mode = entry.mode == .units ? .carbs : .units
            entry.foodIsInsulin = model.screenCarbsOff
            entry.value = 0
            state = .entry(entry)
        case (.entry(var entry), .adjust(let up, let coarse)):
            let step = coarse ? coarseStep(entry) : fineStep(entry)
            entry.value = min(max(0, entry.value + (up ? step : -step)), dialMax(entry))
            state = .entry(entry)
        case (.entry(let entry), .review):
            startReview(entry)
        case (.entry, .back), (.entry, .close):
            state = .idle

        case (.question(let q), .answer(let yes)):
            let dose = yes ? q.yesUnits : q.noUnits
            var review = Review(
                entry: q.entry, units: dose, split: split(q.entry, units: dose, glucoseMgdl: yes ? q.mgdl : nil),
                glucoseMgdl: q.mgdl, question: q, shownAt: model.now)
            switch q.kind {
            case .correction:
                // The reading goes with the answer: the composer applies "no" only to this same reading.
                review.declineCorrection = !yes
            case .staleReading:
                review.includeStaleGlucose = yes
                // Carbs only names no glucose: the stale reading had no part in the dose.
                if !yes { review.glucoseMgdl = nil }
            }
            state = .review(review)
        case (.question(let q), .back):
            state = .entry(q.entry)
        case (.question, .close):
            state = .idle

        case (.review(var review), .tap(let n)):
            guard model.now < review.shownAt.addingTimeInterval(Self.reviewLifetime) else { return }
            if n == review.taps + 1 {
                review.taps = n
            } else {
                // Out of order: the count starts again, from this tap if it was 1.
                review.taps = n == 1 ? 1 : 0
            }
            if review.taps == 3 {
                await send(review)
            } else {
                // The same screen: only the count moved, so a tap drawn a moment ago still counts.
                replaceKeepingScreen(.review(review))
            }
        case (.review(let review), .back):
            if let q = review.question { state = .question(q) } else { state = .entry(review.entry) }
        case (.review, .close):
            state = .idle

        case (.confirm(var review, let needed, _), .goOn):
            // Back to the 1 → 2 → 3 confirm, now carrying what the user confirmed; a new request.
            review.confirmed.formUnion(needed.map(\.kind))
            review.taps = 0
            review.shownAt = model.now
            state = .review(review)
        case (.confirm(let review, _, _), .back):
            state = .entry(review.entry)
        case (.confirm, .close):
            state = .idle

        case (.result(let r), .close):
            // A dose that may still be delivering keeps its screen, as it keeps its Cancel.
            if r.isSettled { state = .idle }

        case (.alert(let index), .nextAlert):
            let count = alerts.count
            state = count == 0 ? .idle : .alert(index: (index + 1) % count)
        case (.alert(let index), .clearAlert):
            await clearAlert(at: index)
        case (.alert, .close), (.alert, .back):
            state = .idle

        default:
            break
        }
    }

    /// The state changed but the screen is the same one (the confirm's count): its ID is kept.
    private func replaceKeepingScreen(_ next: State) {
        let number = screenNumber
        state = next
        screenNumber = number
    }

    // MARK: Entry

    private func fineStep(_ entry: Entry) -> Int {
        switch entry.mode {
        case .units: return max(1, Int((model.settings.bolusIncrement * 1000).rounded()))
        case .carbs:
            return entry.foodIsInsulin
                ? max(1, Int((model.settings.bolusIncrement * 1000).rounded())) : max(1, model.settings.carbIncrement)
        }
    }

    private func coarseStep(_ entry: Entry) -> Int {
        entry.mode == .carbs && !entry.foodIsInsulin ? Self.coarseCarbsGrams : Self.coarseUnitsMilliunits
    }

    /// The most the dial goes to: the lower of the remote limit and the pump's max, as the watch's does.
    private func dialMax(_ entry: Entry) -> Int {
        if entry.mode == .carbs && !entry.foodIsInsulin { return Self.maxCarbsGrams }
        return doseLimitMilliunits ?? Self.fallbackDialMaxMilliunits
    }

    /// The lower of the remote limit and the pump's max bolus, when either is known.
    private var doseLimitMilliunits: Int? {
        let pumpMax = model.display.bolusCalculator.flatMap {
            $0.value.maxBolusUnits.isFinite && $0.value.maxBolusUnits > 0 ? $0.value.maxBolusUnits : nil
        }
        let limits = [model.settings.remoteBolusLimitUnits, pumpMax].compactMap { $0 }
        return limits.min().map { Int(($0 * 1000).rounded(.down)) }
    }

    /// What the calculator gives for this entry now, from what the screen shows.
    struct Preview {
        var units: Double?
        var question: Question?
        var glucoseMgdl: Int?
        var text: String?
        var message: String?
    }

    func preview(_ entry: Entry) -> Preview {
        guard let food = Review(entry: entry, units: 0, shownAt: model.now).food else { return Preview() }
        let carbsOff = model.screenCarbsOff
        if entry.value > 0, entry.foodIsInsulin != carbsOff {
            return Preview(text: carbsOff ? "Carbs now off: dial in U" : "Carbs now on: dial in g")
        }
        let without = model.recommendation(food, glucoseMgdl: nil)
        guard without.displaysNumericDose || without.calculation != nil else {
            return Preview(text: "Waiting for pump settings")
        }
        if without.settingsUnusable { return Preview(text: "Calculator unavailable") }
        let noCorrection = carbsOff ? "no correction" : "carbs only"
        let display = model.display
        if let fresh = display.glucoseForCorrection(thresholds: model.freshness, now: model.now) {
            let mgdl = fresh.mgdl
            guard CalculatorGlucose.isValid(mgdl: mgdl) else {
                return Preview(
                    text: mgdl < CalculatorMessage.lowGlucoseMgdl
                        ? "Too low for a carb dose" : "Too high for a carb dose"
                )
            }
            let with = model.recommendation(food, glucoseMgdl: mgdl)
            if mgdl >= CalculatorMessage.lowGlucoseMgdl, with.displaysNumericDose, without.displaysNumericDose,
                with.units > 0, without.units > 0, abs(with.units - without.units) > 1e-9,
                let target = with.inputs.settings?.value.targetMgdl
            {
                let q = Question(
                    kind: .correction(above: mgdl > target, targetMgdl: target), entry: entry, mgdl: mgdl,
                    yesUnits: with.units, noUnits: without.units)
                return Preview(
                    units: nil, question: q, glucoseMgdl: mgdl,
                    text: "\(formatUnits(with.units)) or \(formatUnits(without.units))",
                    message: mgdl > target ? "Correction asked next" : "Reduction asked next")
            }
            return Preview(
                units: with.displaysNumericDose ? with.units : nil, glucoseMgdl: mgdl,
                text: with.displaysNumericDose ? formatUnits(with.units) : "Calculator unavailable",
                message: with.message.map(Self.shortText))
        }
        // No current reading: a stale one the composer may include is asked about, as the watch asks it.
        if let reading = display.glucose, model.staleReadingIncludable,
            CalculatorGlucose.isValid(mgdl: reading.value.mgdl)
        {
            let with = model.recommendation(food, glucoseMgdl: reading.value.mgdl)
            if with.displaysNumericDose, without.displaysNumericDose, with.units > 0, without.units > 0,
                abs(with.units - without.units) > 1e-9
            {
                let q = Question(
                    kind: .staleReading(measuredAt: reading.measuredAt), entry: entry, mgdl: reading.value.mgdl,
                    yesUnits: with.units, noUnits: without.units)
                return Preview(
                    question: q, text: "\(formatUnits(with.units)) or \(formatUnits(without.units))",
                    message: "Stale CGM: asked next")
            }
        }
        let message: String
        if let caution = model.screenGlucoseCaution, caution != .cgmStateNotRead {
            message = Self.cautionText(caution, noCorrection: noCorrection)
        } else if display.glucose == nil {
            message = "No CGM: \(noCorrection)"
        } else {
            message = "Stale CGM: \(noCorrection)"
        }
        return Preview(
            units: without.displaysNumericDose ? without.units : nil,
            text: without.displaysNumericDose ? formatUnits(without.units) : "Calculator unavailable",
            message: without.message.map(Self.shortText) ?? message)
    }

    private func startReview(_ entry: Entry) {
        switch entry.mode {
        case .units:
            guard canReview(entry) else { return }
            state = .review(Review(entry: entry, units: Double(entry.value) / 1000, shownAt: model.now))
        case .carbs:
            let p = preview(entry)
            if let q = p.question {
                // Asked only while one of its doses may be sent; the composer refuses the other.
                let limit = doseLimitMilliunits.map(Double.init) ?? .infinity
                guard min(q.yesUnits, q.noUnits) * 1000 <= limit + 1e-6 else { return }
                state = .question(q)
                return
            }
            guard canReview(entry), let units = p.units else { return }
            state = .review(
                Review(
                    entry: entry, units: units, split: split(entry, units: units, glucoseMgdl: p.glucoseMgdl),
                    glucoseMgdl: p.glucoseMgdl, shownAt: model.now))
        }
    }

    /// - Parameter preview: the entry's preview when the caller already has it.
    func canReview(_ entry: Entry, preview known: Preview? = nil) -> Bool {
        guard availability == nil else { return false }
        switch entry.mode {
        case .units:
            return entry.value >= Int((BolusVolume.minimumUnits * 1000).rounded())
        case .carbs:
            let p = known ?? preview(entry)
            if p.question != nil { return true }
            guard let units = p.units, units >= BolusVolume.minimumUnits else { return false }
            return doseLimitMilliunits.map { units * 1000 <= Double($0) + 1e-6 } ?? true
        }
    }

    /// The calculator dose's parts, as the watch writes them: the food's share, then the correction or the
    /// reduction that makes up the rest.
    private func split(_ entry: Entry, units: Double, glucoseMgdl: Int?) -> String? {
        guard let food = Review(entry: entry, units: units, shownAt: model.now).food,
            let calculation = model.recommendation(food, glucoseMgdl: glucoseMgdl).calculation
        else { return nil }
        let foodPart = min(max(0, (calculation.fromCarbs * 100).rounded(.down) / 100), units)
        let rest = units - foodPart
        let base = "\(String(format: "%.2f", foodPart)) food"
        if rest > 0.004 { return base + " + \(String(format: "%.2f", rest)) correction" }
        if rest < -0.004 { return base + " - \(String(format: "%.2f", -rest)) reduction" }
        return glucoseMgdl == nil ? base + " · no correction" : base
    }

    // MARK: Send

    private func send(_ review: Review) async {
        cancelledBeforeStart = false
        cancelling = nil
        state = .result(Result(stage: .sending, units: review.units, key: nil, settledAt: nil))
        model.publishSurfaces()
        let amount: RemoteDoseRequest.Amount =
            review.food.map { .calculator(food: $0, estimateUnits: review.units) } ?? .units(review.units)
        let request = RemoteDoseRequest(
            id: UUID().uuidString, peerId: Self.peerId, surface: .liveActivity, sentAt: review.shownAt,
            amount: amount, glucoseMgdl: review.glucoseMgdl, includeStaleGlucose: review.includeStaleGlucose,
            confirmed: review.confirmed, declineCorrection: review.declineCorrection)
        let decision = await model.composeLiveActivityDose(request)
        switch decision {
        case .refused where cancelledBeforeStart:
            notSent("Not delivered", RemoteHost.cancelledMessage, units: review.units)
        case .refused(.needsConfirmation(let needed, let units)):
            state = .confirm(review, needed, units: units)
        case .refused(let refusal):
            notSent("Not delivered", refusal.userMessage, units: review.units)
        case .alreadyRecorded(let outcome):
            show(outcome, key: request.ledgerKey, units: review.units)
        case .deliver(let dose):
            // Checked with no wait before the hand-off: a cancel is either seen here or reaches the delivery.
            if cancelledBeforeStart {
                notSent("Not delivered", RemoteHost.cancelledMessage, units: dose.units)
                return
            }
            switch await model.deliver(dose) {
            case .started(let key, let outcome):
                show(outcome, key: key, units: dose.units)
            case .alreadyRecorded(let outcome):
                show(outcome, key: dose.request.ledgerKey, units: dose.units)
            case .notStarted(let refusal):
                notSent("Not delivered", RemoteHost.message(refusal), units: dose.units)
            }
        }
    }

    private func notSent(_ headline: String, _ reason: String, units: Double?) {
        state = .result(
            Result(stage: .notSent(headline: headline, reason: reason), units: units, key: nil, settledAt: model.now))
    }

    private func show(_ outcome: BolusOutcome, key: RemoteBolusLedger.Key, units: Double) {
        state = .result(
            Result(
                stage: .outcome(outcome), units: units, key: key,
                settledAt: outcome.isFinal || outcome.isUnknown ? model.now : nil))
    }

    /// A bolus outcome from the session. One for the dose this screen shows moves its result; the screen
    /// keeps its ID so its buttons still count.
    func outcomeChanged(_ key: RemoteBolusLedger.Key, _ outcome: BolusOutcome) {
        guard case .result(var r) = state, r.key == key else { return }
        r.stage = .outcome(outcome)
        if outcome.isFinal || outcome.isUnknown { r.settledAt = model.now }
        if outcome.isFinal || outcome.isUnknown { cancelling = nil }
        replaceKeepingScreen(.result(r))
    }

    // MARK: Cancel

    /// Never gated. Tried again while the pump gives no definite answer, as the watch host does.
    private func cancelBolus() async {
        if case .result(let r) = state, case .sending = r.stage { cancelledBeforeStart = true }
        guard cancelling == nil || cancelling?.answered == true else {
            cancelAgain = true
            return
        }
        cancelling = (model.now, false)
        model.publishSurfaces()
        var retries = 3
        var result: CancelResult
        repeat {
            cancelAgain = false
            result = await model.cancelBolus()
            // No definite answer, or no pump to ask: a bolus may still be going in, so it's asked again.
            while result == .unconfirmed || result == .notConnected, retries > 0 {
                retries -= 1
                try? await Task.sleep(for: .seconds(2))
                result = await model.cancelBolus()
            }
        } while cancelAgain
        cancelling = result == .unconfirmed || result == .notConnected ? (cancelling?.since ?? model.now, true) : nil
    }

    // MARK: Alerts

    /// The alerts the Live Activity shows: those the watch mirrors, most severe first, less any the pump
    /// just cleared.
    var alerts: [ActiveAlert] {
        let now = model.now
        hiddenAlerts = hiddenAlerts.filter { $0.value > now }
        let shown = (model.alertSnapshot?.active ?? []).filter {
            $0.watchIntent != .off && hiddenAlerts[$0.identifier] == nil
        }
        return shown.enumerated().sorted {
            $0.element.severity != $1.element.severity
                ? $0.element.severity > $1.element.severity : $0.offset < $1.offset
        }.map(\.element)
    }

    /// What the watch offers to clear: the session says the pump can clear it remotely, and it isn't a
    /// malfunction.
    static func canClear(_ alert: ActiveAlert) -> Bool {
        alert.pumpAlert?.remoteClearOffered ?? false
    }

    private func clearAlert(at index: Int) async {
        let list = alerts
        guard list.indices.contains(index), Self.canClear(list[index]), let pump = list[index].pumpAlert else { return }
        let id = list[index].identifier
        clearNote = (id, "Clearing…")
        replaceKeepingScreen(.alert(index: index))
        model.publishSurfaces()
        let outcome = await model.dismiss(pump)
        switch outcome {
        case .cleared:
            clearNote = nil
            hiddenAlerts[id] = model.now.addingTimeInterval(Self.clearedAlertHide)
            state = alerts.isEmpty ? .idle : .alert(index: min(index, alerts.count - 1))
        case .refused: clearNote = (id, "Pump didn't clear it")
        case .unsupported, .notCleared: clearNote = (id, "Clear it on the pump")
        case .unconfirmed: clearNote = (id, "No answer from pump")
        }
    }

    // MARK: What the Live Activity draws

    private var availability: DoseRefusal? {
        DoseComposer.availability(
            surface: .liveActivity, pump: model.display, access: model.access, bolusBlock: model.bolusBlock)
    }

    /// A bolus is going, from any surface.
    private var bolusGoing: Bool {
        if model.bolusBlock == .bolusInProgress { return true }
        if case .inProgress? = model.display.bolusState?.value { return true }
        return false
    }

    /// Built before the ID is read: building it may end a screen whose time is up.
    var panel: LiveActivityPanel {
        let view = view
        return LiveActivityPanel(screen: screenID, view: view)
    }

    var alertSummary: LiveActivityAlerts? {
        let list = alerts
        guard let top = list.first else { return nil }
        return LiveActivityAlerts(
            topTitle: Self.truncated(top.title, 64), topCritical: top.severity == .critical, count: list.count)
    }

    private var view: LiveActivityPanel.Screen {
        let now = model.now
        switch state {
        case .idle:
            return .idle(idleButton)
        case .entry(let entry):
            return .entry(entryView(entry))
        case .question(let q):
            return .question(questionView(q))
        case .review(let r):
            let expiresAt = r.shownAt.addingTimeInterval(Self.reviewLifetime)
            return .review(
                LiveActivityPanel.Review(
                    units: formatUnits(r.units), split: r.split, taps: r.taps, expiresAt: expiresAt,
                    expired: now >= expiresAt))
        case .confirm(_, let needed, let units):
            return .confirm(
                LiveActivityPanel.Confirm(
                    title: needed.count == 1 ? needed[0].title : "Confirm",
                    message: Self.truncated(needed.map(\.shortMessage).joined(separator: " "), 200),
                    goOn: "Go on: \(formatUnits(units))"))
        case .result(let r):
            if r.isDeliveredLongAgo(now: now) {
                state = .idle
                return .idle(idleButton)
            }
            return .result(resultView(r, now: now))
        case .alert(let index):
            let list = alerts
            guard list.indices.contains(index) else {
                // It went (cleared elsewhere): back to the card, whose buttons then work.
                clearNote = nil
                state = .idle
                return .idle(idleButton)
            }
            let alert = list[index]
            return .alert(
                LiveActivityPanel.AlertCard(
                    title: Self.truncated(alert.title, 64), body: Self.truncated(alert.body, 180),
                    critical: alert.severity == .critical,
                    position: list.count > 1 ? "\(index + 1) of \(list.count)" : nil, canClear: Self.canClear(alert),
                    note: clearNote?.alertId == alert.identifier ? clearNote?.note : nil))
        }
    }

    private var idleButton: LiveActivityPanel.IdleButton {
        if bolusGoing { return cancelling == nil ? .cancel : .cancelling }
        let access = model.access
        guard access.liveActivityBolusEnabled, !access.remotesReadOnly, !access.phoneReadOnly else { return .none }
        if let refusal = availability { return .unavailable(Self.shortText(refusal)) }
        return .bolus
    }

    private func entryView(_ entry: Entry) -> LiveActivityPanel.Entry {
        let mode: LiveActivityPanel.Entry.Mode =
            entry.mode == .units ? .units : entry.foodIsInsulin ? .food : .carbs
        let value =
            mode == .carbs ? "\(entry.value) g" : formatUnits(Double(entry.value) / 1000)
        var preview: Preview?
        if entry.mode == .carbs { preview = self.preview(entry) }
        var text = preview?.text
        if let units = preview?.units, let limit = doseLimitMilliunits, units * 1000 > Double(limit) + 1e-6 {
            text = "Over the \(formatUnits(Double(limit) / 1000)) limit"
        }
        let blocked = availability.map(Self.shortText)
        return LiveActivityPanel.Entry(
            mode: mode, value: value, canDecrease: entry.value > 0, canIncrease: entry.value < dialMax(entry),
            preview: text, message: blocked ?? preview?.message, canReview: canReview(entry, preview: preview))
    }

    private func questionView(_ q: Question) -> LiveActivityPanel.Question {
        let unit = model.settings.glucoseUnit
        let title = "BG \(unit.format(mgdl: q.mgdl)) \(Self.mgdl)"
        let noCorrection = q.entry.foodIsInsulin ? "No correction" : "Carbs only"
        switch q.kind {
        case .correction(let above, let target):
            return LiveActivityPanel.Question(
                title: title, detail: "\(above ? "above" : "below") target \(unit.format(mgdl: target)) \(Self.mgdl)",
                ask: above ? "Add a correction?" : "Reduce the bolus?", yes: above ? "Corrected" : "Reduced",
                yesUnits: formatUnits(q.yesUnits), no: above ? noCorrection : "Not reduced",
                noUnits: formatUnits(q.noUnits))
        case .staleReading(let measuredAt):
            let minutes = max(0, Int(model.now.timeIntervalSince(measuredAt) / 60))
            return LiveActivityPanel.Question(
                title: title, detail: "Stale CGM · \(minutes) min ago", ask: "Include it?", yes: "Include",
                yesUnits: formatUnits(q.yesUnits), no: noCorrection, noUnits: formatUnits(q.noUnits))
        }
    }

    private func resultView(_ r: Result, now: Date) -> LiveActivityPanel.Result {
        let note =
            cancelling.flatMap { c in
                c.answered || now.timeIntervalSince(c.since) >= Self.cancelSlowAfter
                    ? "No answer yet. To stop it now, use the pump." : nil
            }
        let cancelButton: LiveActivityPanel.Result.Button = cancelling == nil ? .cancel : .cancelling
        let units = r.units.map { formatUnits($0) } ?? ""
        switch r.stage {
        case .sending:
            return .init(
                headline: "Sending…", tone: .working, line: units, button: cancelButton, note: note,
                compact: units)
        case .notSent(let headline, let reason):
            return .init(headline: headline, tone: .bad, line: reason, button: .done, compact: "Not sent")
        case .outcome(let outcome):
            switch outcome {
            case .requested, .accepted:
                return .init(
                    headline: "Starting…", tone: .working, line: units, button: cancelButton, note: note,
                    compact: units)
            case .delivering:
                return .init(
                    headline: "Delivering…", tone: .working, line: units, button: cancelButton, note: note,
                    compact: units)
            case .delivered(let delivered):
                return .init(
                    headline: "Delivered", tone: .good, line: "\(formatUnits(delivered)) delivered", button: .done,
                    compact: formatUnits(delivered))
            case .stopped(let delivered, let requested):
                return .init(
                    headline: "Stopped", tone: .caution,
                    line: "\(formatUnits(delivered)) of \(formatUnits(requested)) delivered", button: .done,
                    compact: "Stopped")
            case .refused(let reason):
                return .init(headline: "Pump refused", tone: .bad, line: reason, button: .done, compact: "Refused")
            case .failed(let reason):
                return .init(headline: "Not delivered", tone: .bad, line: reason, button: .done, compact: "Not sent")
            case .unknown:
                return .init(
                    headline: "Outcome unknown", tone: .caution, line: "Check the pump before dosing again.",
                    button: .done, compact: "Check")
            }
        }
    }

    // MARK: Words

    /// A refusal in the watch's few words, for the card's greyed button and the entry screen.
    static func shortText(_ refusal: DoseRefusal) -> String {
        switch refusal {
        case .unavailable(let reason):
            switch reason {
            case .pumpNotLinked, .remoteUnreachable: return "Pump not connected"
            case .bolusInFlight: return "Bolus in progress"
            case .noCartridge: return "Cartridge not ready"
            case .accessDenied(.remotesReadOnly), .accessDenied(.phoneReadOnly): return "Read-only"
            case .accessDenied(.remoteBolusDisabled): return "Bolusing off"
            case .accessDenied(.capabilityUnavailable), .belowMinimum, .aboveMax: return "Pump can't bolus"
            }
        case .blocked(let block):
            switch block {
            case .bolusInProgress: return "Bolus in progress"
            case .unknownOutcome: return "Check last bolus"
            case .noDurableStore, .ledgerUnreadable, .outcomeNotSaved: return "Delivery locked"
            }
        default:
            return "Unavailable"
        }
    }

    /// The calculator's message in the watch's words.
    static func shortText(_ message: CalculatorMessage) -> String {
        switch message {
        case .lowGlucose(.noCarbs): return "Glucose low: eat carbs"
        case .lowGlucose(.noBolus): return "Glucose low: no bolus"
        case .lowGlucose(.reduced): return "Glucose low: dose reduced"
        case .reducedToZero: return "Below target: no bolus"
        case .iobMayDropLow: return "IOB may drop you low"
        case .iobCoversCorrection: return "IOB covers the correction"
        }
    }

    static func cautionText(_ caution: PumpGlucoseCaution, noCorrection: String) -> String {
        switch caution {
        case .outOfRange(.low): return "CGM below range: check BG"
        case .outOfRange(.high): return "CGM above range: check BG"
        case .checkBG: return "Check BG: \(noCorrection)"
        case .sensorState: return "CGM not ready: \(noCorrection)"
        case .autoFillOff, .cgmStateNotRead: return "CGM unusable: \(noCorrection)"
        }
    }

    /// The only glucose unit this release offers (`GlucoseUnit`).
    static let mgdl = "mg/dL"

    static func truncated(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

@MainActor
extension LiveActivityFlow.Result {
    var isSettled: Bool {
        switch stage {
        case .sending: return false
        case .notSent: return true
        case .outcome(let outcome): return outcome.isFinal || outcome.isUnknown
        }
    }

    func isDeliveredLongAgo(now: Date) -> Bool {
        guard case .outcome(.delivered) = stage, let settledAt else { return false }
        return now.timeIntervalSince(settledAt) >= LiveActivityFlow.deliveredLinger
    }
}
