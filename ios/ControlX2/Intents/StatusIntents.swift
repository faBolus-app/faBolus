import AppIntents
import Foundation

/// Read-only Siri intents. They answer status questions ("What's my glucose?", "How much insulin
/// on board?", "Check my pump") by reading the last snapshot the app published to the App Group —
/// the same data the widgets show. They never touch Bluetooth and never deliver a bolus: a voice
/// bolus is intentionally out of scope (per the safety rule, dosing is CarPlay-only, and CarPlay
/// isn't built), so nothing here can dispense insulin.
///
/// Each intent runs without opening the app (`openAppWhenRun = false`) and speaks a dialog.

// MARK: - Shared formatting

enum SiriFormat {
    /// Spoken word for the Unicode trend arrow stored in the snapshot.
    static func trendWord(_ arrow: String) -> String {
        switch arrow {
        case "↑":  return "rising"
        case "⇈":  return "rising quickly"
        case "↗":  return "rising slightly"
        case "→":  return "steady"
        case "↘":  return "falling slightly"
        case "↓":  return "falling"
        case "⇊":  return "falling quickly"
        default:    return ""
        }
    }

    /// "just now" / "3 minutes ago" / "2 hours ago" for a reading time.
    static func age(_ date: Date?) -> String {
        guard let date else { return "" }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        let mins = secs / 60
        if mins < 60 { return "\(mins) minute\(mins == 1 ? "" : "s") ago" }
        let hrs = mins / 60
        return "\(hrs) hour\(hrs == 1 ? "" : "s") ago"
    }

    static func units(_ u: Double) -> String {
        let s = String(format: "%.2f", u)
        return "\(s) unit\(u == 1 ? "" : "s")"
    }

    static let noData = "I don't have any pump data yet. Open ControlX2 and connect to your pump first."
}

// MARK: - Glucose

struct GlucoseQueryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Glucose"
    static let description = IntentDescription("Ask for your latest glucose reading and trend.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = WidgetStore.load() else { return .result(dialog: IntentDialog(stringLiteral: SiriFormat.noData)) }
        guard let g = s.glucose, !s.isGlucoseStale else {
            return .result(dialog: "I don't have a recent glucose reading. The last one is more than six minutes old.")
        }
        let trend = SiriFormat.trendWord(s.trendArrow)
        let trendPhrase = trend.isEmpty ? "" : " and \(trend)"
        let age = SiriFormat.age(s.glucoseDate)
        return .result(dialog: "Your glucose is \(g)\(trendPhrase), \(age).")
    }
}

// MARK: - Insulin on board

struct InsulinOnBoardIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Insulin on Board"
    static let description = IntentDescription("Ask how much insulin is currently on board.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = WidgetStore.load() else { return .result(dialog: IntentDialog(stringLiteral: SiriFormat.noData)) }
        if s.iobUnits <= 0 { return .result(dialog: "You have no insulin on board.") }
        return .result(dialog: "You have \(SiriFormat.units(s.iobUnits)) of insulin on board.")
    }
}

// MARK: - Combined pump status

struct PumpStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Pump Status"
    static let description = IntentDescription("A quick summary: glucose, insulin on board, reservoir and battery.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = WidgetStore.load() else { return .result(dialog: IntentDialog(stringLiteral: SiriFormat.noData)) }
        var parts: [String] = []
        if let g = s.glucose, !s.isGlucoseStale {
            let trend = SiriFormat.trendWord(s.trendArrow)
            parts.append(trend.isEmpty ? "Glucose \(g)" : "Glucose \(g) and \(trend)")
        }
        parts.append(s.iobUnits > 0 ? "\(SiriFormat.units(s.iobUnits)) on board" : "no insulin on board")
        if s.reservoirUnits > 0 { parts.append("reservoir \(Int(s.reservoirUnits)) units") }
        if s.batteryPercent > 0 { parts.append("battery \(s.batteryPercent) percent") }
        var dialog = parts.joined(separator: ", ") + "."
        if !s.connected { dialog += " The pump isn't connected right now, so this may be out of date." }
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - Last bolus

struct LastBolusQueryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Last Bolus"
    static let description = IntentDescription("Ask about the most recent bolus.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = WidgetStore.load() else { return .result(dialog: IntentDialog(stringLiteral: SiriFormat.noData)) }
        guard let u = s.lastBolusUnits, u > 0 else { return .result(dialog: "I don't have a recent bolus on record.") }
        let age = s.lastBolusDate.map { " " + SiriFormat.age($0) } ?? ""
        return .result(dialog: "Your last bolus was \(SiriFormat.units(u))\(age).")
    }
}

// MARK: - Alerts

struct AlertsQueryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Alerts"
    static let description = IntentDescription("Ask what pump alerts or alarms are active.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = WidgetStore.load() else { return .result(dialog: IntentDialog(stringLiteral: SiriFormat.noData)) }
        let alerts = s.activeAlerts
        if alerts.isEmpty { return .result(dialog: "You have no active pump alerts.") }
        if alerts.count == 1 { return .result(dialog: "You have one active alert: \(alerts[0]).") }
        let list = alerts.prefix(5).joined(separator: ", ")
        return .result(dialog: "You have \(alerts.count) active alerts: \(list).")
    }
}

// MARK: - Shortcut phrases

struct ControlX2Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GlucoseQueryIntent(), phrases: [
            "What's my glucose in \(.applicationName)",
            "Check my glucose in \(.applicationName)",
            "\(.applicationName) glucose",
        ], shortTitle: "Glucose", systemImageName: "drop.fill")

        AppShortcut(intent: InsulinOnBoardIntent(), phrases: [
            "How much insulin on board in \(.applicationName)",
            "\(.applicationName) insulin on board",
            "Check insulin on board in \(.applicationName)",
        ], shortTitle: "Insulin on Board", systemImageName: "syringe")

        AppShortcut(intent: PumpStatusIntent(), phrases: [
            "Check my pump in \(.applicationName)",
            "\(.applicationName) pump status",
            "How's my pump in \(.applicationName)",
        ], shortTitle: "Pump Status", systemImageName: "cross.case")

        AppShortcut(intent: LastBolusQueryIntent(), phrases: [
            "What was my last bolus in \(.applicationName)",
            "\(.applicationName) last bolus",
        ], shortTitle: "Last Bolus", systemImageName: "clock.arrow.circlepath")

        AppShortcut(intent: AlertsQueryIntent(), phrases: [
            "Any alerts in \(.applicationName)",
            "\(.applicationName) alerts",
            "Check alerts in \(.applicationName)",
        ], shortTitle: "Alerts", systemImageName: "bell.badge")
    }
}
