import AppIntents
import Foundation

/// Value-returning App Intents for **Apple Shortcuts** — they expose every field the app publishes
/// to the App Group so users can build shortcuts/automations (e.g. "if glucose > 180 and no IOB,
/// notify me"). Each returns a typed value AND speaks a dialog, so they also work with Siri. They
/// read the last published snapshot (no Bluetooth), and are read-only. The only actions are the
/// safe "open the bolus screen" (never a headless dose) and acknowledging alerts.

/// Thrown when the app has no snapshot yet (never launched/connected).
struct NoPumpDataError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "No pump data yet — open ControlX2 and connect first." }
}

private func loadSnap() throws -> WidgetSnapshot {
    guard let s = WidgetStore.load() else { throw NoPumpDataError() }
    return s
}

// MARK: - Glucose

struct GetGlucoseValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Glucose"
    static let description = IntentDescription("The latest glucose value in mg/dL.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let s = try loadSnap()
        guard let g = s.glucose else { throw NoPumpDataError() }
        let age = s.isGlucoseStale ? " (stale)" : ""
        return .result(value: g, dialog: "\(g) mg/dL\(age)")
    }
}

struct GetGlucoseTrendIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Glucose Trend"
    static let description = IntentDescription("The glucose trend, e.g. rising, steady, falling.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let s = try loadSnap()
        let word = SiriFormat.trendWord(s.trendArrow)
        let out = word.isEmpty ? "unknown" : word
        return .result(value: out, dialog: IntentDialog(stringLiteral: out))
    }
}

struct GetGlucoseAgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Glucose Age (minutes)"
    static let description = IntentDescription("How many minutes ago the current glucose was read.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let s = try loadSnap()
        guard let d = s.glucoseDate else { throw NoPumpDataError() }
        let m = max(0, Int(Date().timeIntervalSince(d) / 60))
        return .result(value: m, dialog: "\(m) minute\(m == 1 ? "" : "s") ago")
    }
}

struct GetRecentGlucoseIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Glucose Values"
    static let description = IntentDescription("The recent glucose readings (mg/dL), oldest to newest.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<[Int]> {
        let s = try loadSnap()
        return .result(value: s.recentPoints.map { $0.mgdl })
    }
}

// MARK: - Insulin / delivery

struct GetIOBIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Insulin on Board"
    static let description = IntentDescription("Current insulin on board, in units.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Double> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.iobUnits, dialog: "\(String(format: "%.2f", s.iobUnits)) units on board")
    }
}

struct GetLastBolusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Bolus (units)"
    static let description = IntentDescription("The most recent bolus amount, in units.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Double> & ProvidesDialog {
        let s = try loadSnap()
        let u = s.lastBolusUnits ?? 0
        return .result(value: u, dialog: "\(String(format: "%.2f", u)) units")
    }
}

struct GetLastBolusAgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Bolus Age (minutes)"
    static let description = IntentDescription("How many minutes ago the last bolus was delivered.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let s = try loadSnap()
        guard let d = s.lastBolusDate else { throw NoPumpDataError() }
        let m = max(0, Int(Date().timeIntervalSince(d) / 60))
        return .result(value: m, dialog: "\(m) minute\(m == 1 ? "" : "s") ago")
    }
}

// MARK: - Pump status

struct GetReservoirIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Reservoir (units)"
    static let description = IntentDescription("Insulin remaining in the reservoir, in units.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Double> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.reservoirUnits, dialog: "\(Int(s.reservoirUnits)) units in the reservoir")
    }
}

struct GetPumpBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pump Battery"
    static let description = IntentDescription("Pump battery level, in percent.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.batteryPercent, dialog: "\(s.batteryPercent) percent")
    }
}

struct GetConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Pump Connected"
    static let description = IntentDescription("Whether the app is currently connected to the pump.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Bool> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.connected, dialog: s.connected ? "Connected" : "Not connected")
    }
}

struct GetCGMActiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Is CGM Active"
    static let description = IntentDescription("Whether the pump's CGM is reporting.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Bool> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.cgmActive, dialog: s.cgmActive ? "CGM active" : "CGM inactive")
    }
}

// MARK: - Settings read-outs

struct GetCarbRatioIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Carb Ratio"
    static let description = IntentDescription("Insulin-to-carb ratio, in grams per unit.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Double> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.carbRatio, dialog: "\(Int(s.carbRatio)) grams per unit")
    }
}

struct GetCorrectionFactorIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Correction Factor"
    static let description = IntentDescription("Correction factor (ISF), in mg/dL per unit.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.isf, dialog: "\(s.isf) mg/dL per unit")
    }
}

struct GetTargetGlucoseIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Target Glucose"
    static let description = IntentDescription("Target glucose, in mg/dL.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.targetBg, dialog: "\(s.targetBg) mg/dL")
    }
}

struct GetMaxBolusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Max Bolus"
    static let description = IntentDescription("The pump's configured maximum bolus, in units.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Double> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.maxBolusUnits, dialog: "\(String(format: "%.1f", s.maxBolusUnits)) units")
    }
}

// MARK: - Alerts

struct GetActiveAlertsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Active Alerts"
    static let description = IntentDescription("The list of active pump alert titles.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<[String]> {
        .result(value: try loadSnap().activeAlerts)
    }
}

struct GetAlertCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Alert Count"
    static let description = IntentDescription("How many pump alerts are active.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let n = try loadSnap().activeAlerts.count
        return .result(value: n, dialog: "\(n) active alert\(n == 1 ? "" : "s")")
    }
}

// MARK: - Summary

struct GetPumpSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pump Summary"
    static let description = IntentDescription("A one-line summary of glucose, IOB, reservoir and battery.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let s = try loadSnap()
        var parts: [String] = []
        if let g = s.glucose { parts.append("BG \(g)\(s.isGlucoseStale ? " (stale)" : "")") }
        parts.append(String(format: "IOB %.2fU", s.iobUnits))
        parts.append("Res \(Int(s.reservoirUnits))U")
        parts.append("Batt \(s.batteryPercent)%")
        if !s.activeAlerts.isEmpty { parts.append("\(s.activeAlerts.count) alert(s)") }
        if !s.connected { parts.append("disconnected") }
        let out = parts.joined(separator: " · ")
        return .result(value: out, dialog: IntentDialog(stringLiteral: out))
    }
}

// MARK: - Safe action

struct OpenBolusScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Bolus Screen"
    static let description = IntentDescription("Open ControlX2 to the bolus screen (you still confirm the dose in the app).")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        WidgetStore.requestOpenBolus()   // the app routes to the Bolus tab on becoming active
        return .result()
    }
}
