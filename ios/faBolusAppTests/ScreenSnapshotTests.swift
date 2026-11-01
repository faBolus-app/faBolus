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
                })
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
