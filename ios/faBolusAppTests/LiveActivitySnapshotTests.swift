import SnapshotTesting
import SwiftUI
import Testing
import UIKit
import WidgetContent
import faBolusCore

/// The Live Activity's card and every bolus and alert screen, light and dark, at the Lock Screen card's
/// size, plus the small layout CarPlay and the Apple Watch show. The screens carry the words the app's
/// `LiveActivityFlow` sends (its tests check those); these check how they're drawn.
@MainActor
@Suite(.serialized) struct LiveActivitySnapshotTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static var snapshot: WidgetSnapshot {
        var s = WidgetSnapshot.placeholder(now: now)
        s.glucose = Observed(
            PumpGlucose(mgdl: 142, trend: .flat), measuredAt: now.addingTimeInterval(-120), receivedAt: now)
        s.recent = (0..<24).map {
            WidgetSnapshot.Point(
                t: now.addingTimeInterval(Double($0 - 24) * 300), mgdl: 120 + Int(40 * sin(Double($0) / 4)))
        }
        return s
    }

    static func content(_ screen: LiveActivityPanel.Screen?, alerts: LiveActivityAlerts? = nil) -> LiveActivityContent {
        LiveActivityContent(
            snapshot: snapshot, layout: LiveActivityLayout(fields: [.glucose, .iob, .reservoir, .lastBolus]),
            panel: screen.map { LiveActivityPanel(screen: "snap-1", view: $0) }, alerts: alerts)
    }

    static func view(_ content: LiveActivityContent) -> LAView {
        LAView(content: content, systemStale: false, now: now, ticking: false)
    }

    func check<V: View>(
        _ name: String, _ view: V, width: CGFloat = 370, height: CGFloat = 170, fileID: StaticString = #fileID,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column
    ) {
        for dark in [false, true] {
            let card = view.frame(width: width, height: height)
                .background(Color(.systemBackground).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(10)
                .background(Color(white: dark ? 0.1 : 0.75))
                .environment(\.colorScheme, dark ? .dark : .light)
            assertSnapshot(
                of: card,
                as: .image(
                    precision: 0.99, perceptualPrecision: 0.98, layout: .fixed(width: width + 20, height: height + 20),
                    traits: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)),
                named: "\(name)-\(dark ? "dark" : "light")", fileID: fileID, file: file, testName: testName, line: line,
                column: column)
        }
    }

    func card(
        _ name: String, _ screen: LiveActivityPanel.Screen?, alerts: LiveActivityAlerts? = nil,
        testName: String = #function, line: UInt = #line
    ) {
        check(
            name, LockScreenView(view: Self.view(Self.content(screen, alerts: alerts))), testName: testName,
            line: line)
    }

    @Test func idle() {
        card("bolus", .idle(.bolus))
        card("unavailable", .idle(.unavailable("Check last bolus")))
        card("cancel", .idle(.cancel))
        card("alert", .idle(.bolus), alerts: LiveActivityAlerts(topTitle: "Low insulin", topCritical: false, count: 2))
        card("off", .idle(.none))
    }

    @Test func entry() {
        card(
            "units", .entry(.init(mode: .units, value: "0.95 U", canDecrease: true, canIncrease: true, canReview: true))
        )
        card(
            "carbs",
            .entry(
                .init(
                    mode: .carbs, value: "30 g", canDecrease: true, canIncrease: true, preview: "5.25 U or 3.00 U",
                    message: "Correction asked next", canReview: true)))
        card(
            "waiting",
            .entry(
                .init(
                    mode: .carbs, value: "0 g", canDecrease: false, canIncrease: true,
                    preview: "Waiting for pump settings", canReview: false)))
        card(
            "blocked",
            .entry(
                .init(
                    mode: .units, value: "1.00 U", canDecrease: true, canIncrease: false, message: "Pump not connected",
                    canReview: false)))
    }

    @Test func questions() {
        card(
            "correction",
            .question(
                .init(
                    title: "BG 220 mg/dL", detail: "above target 110 mg/dL", ask: "Add a correction?", yes: "Corrected",
                    yesUnits: "5.25 U", no: "Carbs only", noUnits: "3.00 U")))
        card(
            "stale",
            .question(
                .init(
                    title: "BG 142 mg/dL", detail: "Stale CGM · 9 min ago", ask: "Include it?", yes: "Include",
                    yesUnits: "3.50 U", no: "Carbs only", noUnits: "3.00 U")))
    }

    @Test func review() {
        let expires = Self.now.addingTimeInterval(72)
        for taps in 0...2 {
            card(
                "taps-\(taps)",
                .review(.init(units: "3.00 U", split: "3.00 food · no correction", taps: taps, expiresAt: expires)))
        }
        card("expired", .review(.init(units: "0.95 U", taps: 1, expiresAt: Self.now, expired: true)))
        card(
            "confirm",
            .confirm(.init(title: "Low insulin", message: "Low insulin: 1.00 U left.", goOn: "Go on: 0.50 U")))
    }

    @Test func results() {
        card("sending", .result(.init(headline: "Sending…", tone: .working, line: "0.95 U", button: .cancel)))
        card("delivering", .result(.init(headline: "Delivering…", tone: .working, line: "2.00 U", button: .cancel)))
        card(
            "cancelling",
            .result(
                .init(
                    headline: "Delivering…", tone: .working, line: "2.00 U", button: .cancelling,
                    note: "No answer yet. To stop it now, use the pump.")))
        card("delivered", .result(.init(headline: "Delivered", tone: .good, line: "0.95 U delivered", button: .done)))
        card(
            "stopped",
            .result(.init(headline: "Stopped", tone: .caution, line: "0.80 U of 2.00 U delivered", button: .done)))
        card(
            "notDelivered",
            .result(
                .init(
                    headline: "Not delivered", tone: .bad,
                    line: "This dose is above your remote limit of 1.00 U — lower it and try again.", button: .done)))
        card(
            "unknown",
            .result(
                .init(
                    headline: "Outcome unknown", tone: .caution, line: "Check the pump before dosing again.",
                    button: .done)))
    }

    @Test func alert() {
        card(
            "clearable",
            .alert(
                .init(
                    title: "Low insulin", body: "The cartridge has 20 U left. Change it soon.", critical: false,
                    position: "1 of 2", canClear: true, note: "Pump didn't clear it")))
        card(
            "malfunction",
            .alert(
                .init(
                    title: "Malfunction 16-0", body: "Call Tandem customer support. Insulin delivery has stopped.",
                    critical: true, canClear: false)))
    }

    /// The Slim style: one row on the iPhone and on the Mac when its pill is clicked.
    @Test func slim() {
        var content = Self.content(
            .idle(.bolus), alerts: LiveActivityAlerts(topTitle: "Low insulin", topCritical: false, count: 1))
        content.layout.style = .slim
        check("idle", LockScreenView(view: Self.view(content)), height: 80)
    }

    /// The compact view, as the Mac's menu bar draws it: each choice beside the glucose, a bolus's status
    /// over the choice, and the alert mark.
    @Test func pill() {
        func pill(_ content: LiveActivityContent) -> some View {
            let v = Self.view(content)
            return HStack(spacing: 8) {
                CompactLeading(view: v)
                CompactTrailing(view: v)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.black.opacity(0.85), in: Capsule())
            .environment(\.colorScheme, .dark)
        }
        for choice in LiveActivityCompact.allCases {
            var content = Self.content(.idle(.bolus))
            content.layout.compact = choice
            check(choice.rawValue, pill(content), width: 180, height: 32)
        }
        let delivering = Self.content(
            .result(
                .init(headline: "Delivering…", tone: .working, line: "2.00 U", button: .cancel, compact: "2.00 U")),
            alerts: LiveActivityAlerts(topTitle: "Low insulin", topCritical: false, count: 1))
        check("delivering", pill(delivering), width: 180, height: 32)
        let delivered = Self.content(
            .result(
                .init(headline: "Delivered", tone: .good, line: "2.00 U delivered", button: .done, compact: "2.00 U"))
        )
        check("delivered", pill(delivered), width: 180, height: 32)
    }

    /// The Chips style with every field: two rows of chips at most, so the bottom row still fits.
    @Test func chips() {
        var content = Self.content(
            .idle(.bolus), alerts: LiveActivityAlerts(topTitle: "Low insulin", topCritical: false, count: 1))
        content.layout.style = .classic
        content.layout.fields = LiveActivityField.allCases
        check("idle", LockScreenView(view: Self.view(content)))
    }

    /// The Dynamic Island's expanded bottom: where the bolus stands, in one row.
    @Test func island() {
        func island(_ screen: LiveActivityPanel.Screen) -> some View {
            IslandPanelView(panel: LiveActivityPanel(screen: "snap-1", view: screen)).padding(.horizontal, 16)
        }
        check(
            "delivering",
            island(.result(.init(headline: "Delivering…", tone: .working, line: "2.00 U", button: .cancel))),
            height: 60)
        check(
            "review",
            island(.review(.init(units: "3.00 U", taps: 1, expiresAt: Self.now.addingTimeInterval(60)))),
            height: 60)
    }

    @Test func small() {
        let content = Self.content(
            .result(.init(headline: "Delivering…", tone: .working, line: "2.00 U", button: .cancel)),
            alerts: LiveActivityAlerts(topTitle: "Low insulin", topCritical: false, count: 1))
        check("delivering", SmallActivityView(view: Self.view(content)), width: 170, height: 76)
    }
}
