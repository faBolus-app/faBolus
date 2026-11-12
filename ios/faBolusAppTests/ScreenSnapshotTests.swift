import PhoneApp
import SnapshotTesting
import SwiftUI
import Testing
import faBolusCore

@testable import faBolus

/// Every screen, light and dark, recorded on iPhone 17 at iOS 27.2 (scripts/test-ios.sh). A failure here is a
/// screen that changed: re-record deliberately (`SNAPSHOT_TESTING_RECORD=all`) and look at the new images.
@MainActor
@Suite(.serialized) struct ScreenSnapshotTests {
    static let precision: Float = 0.99
    static let perceptual: Float = 0.98

    func check<V: View>(
        _ name: String, _ view: V, height: CGFloat? = nil, fileID: StaticString = #fileID,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column
    ) {
        for dark in [false, true] {
            var config = ViewImageConfig.iPhone13Pro(.portrait)
            if let height { config.size = CGSize(width: config.size!.width, height: height) }
            assertSnapshot(
                of: view.hosted(dark: dark),
                as: .image(on: config, precision: Self.precision, perceptualPrecision: Self.perceptual),
                named: "\(name)-\(dark ? "dark" : "light")", fileID: fileID, file: file, testName: testName, line: line,
                column: column)
        }
    }

    @Test func dashboard() async {
        let model = await SnapshotFixture.model()
        check("connected", DashboardView(model: model), height: 1700)
    }

    /// A bolus delivering and a cancel the pump hasn't answered after 5 s: the line says to use the pump to
    /// stop it now.
    @Test func dashboardCancelling() async {
        let model = await SnapshotFixture.model { $0.pump.startBolus(id: 12, milliunits: 5000) }
        check("cancelling", DashboardView(model: model, cancelMessage: PumpMessages.cancelSlow), height: 1700)
    }

    @Test func dashboardWithNoPump() async {
        let model = await SnapshotFixture.model(paired: false)
        check("unpaired", DashboardView(model: model))
    }

    @Test func bolus() async {
        let model = await SnapshotFixture.model()
        check("empty", NavigationStack { BolusEntryView(model: model) })
        let flow = BolusFlow(model: model)
        flow.carbsText = "45"
        flow.entryChanged()
        check("carbs", NavigationStack { BolusEntryView(model: model, initialFlow: flow) })
        // A typed low: the suggestion is reduced and the screen says to eat carbs.
        let low = BolusFlow(model: model)
        low.carbsText = "45"
        low.glucoseText = "60"
        low.entryChanged()
        check("low", NavigationStack { BolusEntryView(model: model, initialFlow: low) })
        // A typed glucose above target: the screen asks whether to correct, a card for each whole dose.
        let asked = BolusFlow(model: model)
        asked.carbsText = "45"
        asked.glucoseText = "220"
        asked.entryChanged()
        check("correction", NavigationStack { BolusEntryView(model: model, initialFlow: asked) })
        asked.chooseCorrection(apply: true)
        check("corrected", NavigationStack { BolusEntryView(model: model, initialFlow: asked) })
        // The glucose moves after the choice: the cards change, the choice clears, the screen says which way.
        asked.glucoseText = "200"
        asked.entryChanged()
        check("correction-changed", NavigationStack { BolusEntryView(model: model, initialFlow: asked) })
        // A dose typed by hand: no card chosen, and the way back to them.
        asked.unitsTyped("5")
        check("own-dose", NavigationStack { BolusEntryView(model: model, initialFlow: asked) })
        // Below target from 70 up: whether to reduce.
        let reduce = BolusFlow(model: model)
        reduce.carbsText = "45"
        reduce.glucoseText = "90"
        reduce.entryChanged()
        check("reduce", NavigationStack { BolusEntryView(model: model, initialFlow: reduce) })
        // A CGM reading too old to include: the screen says carbs only, and Confirm asks nothing.
        let staleModel = await SnapshotFixture.model { $0.pump.glucose = (180, 30 * 60) }
        let stale = BolusFlow(model: staleModel)
        stale.carbsText = "45"
        stale.entryChanged()
        check("carbs-only-stale", NavigationStack { BolusEntryView(model: staleModel, initialFlow: stale) })
        // A reading the pump flags (a Libre's Check BG icon): the screen says why, and Confirm asks nothing.
        let flaggedModel = await SnapshotFixture.model { $0.pump.trendIcon = 9 }
        let flagged = BolusFlow(model: flaggedModel)
        flagged.carbsText = "45"
        flagged.entryChanged()
        check("carbs-only-flagged", NavigationStack { BolusEntryView(model: flaggedModel, initialFlow: flagged) })
        // Carbs off on the pump: the food field takes insulin units, and the glucose still corrects.
        let carbsOffModel = await SnapshotFixture.model { $0.pump.carbEntryEnabled = false }
        let carbsOff = BolusFlow(model: carbsOffModel)
        carbsOff.carbsText = "3"
        carbsOff.carbsEdited()
        check("carbs-off", NavigationStack { BolusEntryView(model: carbsOffModel, initialFlow: carbsOff) })
        // And above target: the question's second card is "No correction", there being no carbs in it.
        let carbsOffHighModel = await SnapshotFixture.model {
            $0.pump.carbEntryEnabled = false
            $0.pump.glucose = (250, 60)
        }
        let carbsOffHigh = BolusFlow(model: carbsOffHighModel)
        carbsOffHigh.carbsText = "3"
        carbsOffHigh.carbsEdited()
        check(
            "carbs-off-question",
            NavigationStack { BolusEntryView(model: carbsOffHighModel, initialFlow: carbsOffHigh) })
    }

    /// The review of a calculator dose: carbs only, then corrected, as chosen on the screen.
    @Test func bolusReviewCalculator() async {
        let model = await SnapshotFixture.model()
        let flow = BolusFlow(model: model)
        flow.carbsText = "45"
        flow.glucoseText = "220"
        flow.entryChanged()
        guard let q = flow.correctionQuestion else {
            Issue.record("expected the correction question")
            return
        }
        let entry = PhoneDoseEntry(
            id: "snap",
            amount: .calculator(
                carbsGrams: 45, glucose: .typed(mgdl: 220), recommendedUnits: q.applyUnits, enteredUnits: q.applyUnits),
            answers: PhoneDoseAnswers(correction: .init(mgdl: 220, apply: false, units: q.declineUnits)))
        let dose = DoseComposer.composePhone(
            entry,
            context: DoseContext(
                pump: model.display, access: model.access, bolusBlock: nil, inputsRequestedAt: .distantPast,
                lastDeliveryAt: nil, remoteSizeLimitUnits: nil, freshness: model.freshness, now: model.now))
        guard case .deliver(let d) = dose else {
            Issue.record("expected a dose, got \(dose)")
            return
        }
        // At the sheet's height as the app shows it (half the screen).
        check(
            "review-carbs-only",
            BolusReviewSheet(dose: d, notices: BolusFlow.notices(d)) {
            } onCancel: {
            }, height: 470)
        var corrected = entry
        corrected.answers.correction = .init(mgdl: 220, apply: true, units: q.applyUnits)
        guard
            case .deliver(let c) = DoseComposer.composePhone(
                corrected,
                context: DoseContext(
                    pump: model.display, access: model.access, bolusBlock: nil, inputsRequestedAt: .distantPast,
                    lastDeliveryAt: nil, remoteSizeLimitUnits: nil, freshness: model.freshness, now: model.now))
        else {
            Issue.record("expected the corrected dose")
            return
        }
        check(
            "review-corrected",
            BolusReviewSheet(dose: c, notices: BolusFlow.notices(c)) {
            } onCancel: {
            }, height: 470)
    }

    @Test func bolusReview() async {
        let model = await SnapshotFixture.model()
        let flow = BolusFlow(model: model)
        flow.mode = .units
        flow.unitsTyped("1.5")
        let dose = DoseComposer.composePhone(
            PhoneDoseEntry(id: "snap", amount: .units(1.5)),
            context: DoseContext(
                pump: model.display, access: model.access, bolusBlock: nil, inputsRequestedAt: .distantPast,
                lastDeliveryAt: nil, remoteSizeLimitUnits: nil, freshness: model.freshness, now: model.now))
        if case .deliver(let d) = dose {
            check(
                "review",
                BolusReviewSheet(dose: d, notices: BolusFlow.notices(d)) {
                } onCancel: {
                }, height: 470)
        }
    }

    @Test func alerts() async {
        let model = await SnapshotFixture.model()
        check("pumpAlert", AlertsScreenView(model: model))
    }

    @Test func logbook() async {
        let model = await SnapshotFixture.model()
        check("events", LogbookView(model: model))
    }

    @Test func settings() async {
        let model = await SnapshotFixture.model()
        check("root", SettingsView(model: model))
        check("pump", NavigationStack { PumpSettingsView(model: model) })
        check("bolus", NavigationStack { BolusSettingsView(settings: model.settings) })
        check("cgm", NavigationStack { CgmSettingsView(model: model) })
        check("freshness", NavigationStack { FreshnessSettingsView(settings: model.settings) })
        check("notifications", NavigationStack { NotificationSettingsView(model: model) })
        check("display", NavigationStack { DisplaySettingsView(settings: model.settings) })
        check("watch", NavigationStack { RemotesSettingsView(model: model) }, height: 1500)
        check("safety", NavigationStack { SafetySettingsView(settings: model.settings) })
        check("about", NavigationStack { AboutSettingsView(model: model) })
        check("privacy", NavigationStack { PrivacyDataView(model: model) })
    }

    @Test func liveActivitySettings() async {
        let model = await SnapshotFixture.model()
        model.settings.liveActivityEnabled = true
        check("liveActivity", NavigationStack { LiveActivitySettingsView(settings: model.settings) }, height: 1300)
    }

    @Test func onboardingAndPairing() async {
        let model = await SnapshotFixture.model(paired: false)
        check("onboarding", ConnectPumpOnboardingView(model: model))
        check("disclosure", NotificationDisclosureView {})
    }
}
