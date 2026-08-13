import AppIntents
import faBolusCore
import Foundation

/// Value-returning App Intents for **Apple Shortcuts** — they expose every field the app publishes
/// to the App Group so users can build shortcuts/automations (e.g. "if glucose > 180 and no IOB,
/// notify me"). Each returns a typed value AND speaks a dialog, so they also work with Siri. They
/// read the last published snapshot (no Bluetooth), and are read-only. The only actions are the
/// safe "open the bolus screen" (never a headless dose) and acknowledging alerts.

/// Thrown when the app has no snapshot yet (never launched/connected).
struct NoPumpDataError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "No pump data yet — open faBolus and connect first." }
}

private func loadSnap() throws -> WidgetSnapshot {
    guard let s = WidgetStore.load() else { throw NoPumpDataError() }
    return s
}

// MARK: - Glucose

struct GetGlucoseValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Glucose"
    /// Phase 04-06 (D-10, Open Question 2 / A4): the returned value is ALWAYS mg/dL, regardless of
    /// the app's display-unit setting — so existing Shortcuts automations comparing against a
    /// mg/dL threshold (e.g. "if Glucose > 180") never silently change scale. Only the spoken
    /// dialog below honors the display unit.
    static let description = IntentDescription("The latest glucose value, always in mg/dL regardless of the app's display-unit setting. The spoken dialog uses your display unit.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let s = try loadSnap()
        guard let g = s.glucose else { throw NoPumpDataError() }
        let age = s.isGlucoseStale ? " (stale)" : ""
        let unit = await AppSettings.shared.glucoseDisplayUnit
        let spoken = "\(unit.format(mgdl: g)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
        return .result(value: g, dialog: "\(spoken)\(age)")
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
    /// Phase 04-06 (A4): no dialog exists on this intent — the returned array is the whole payload,
    /// so it stays mg/dL always, same rationale as `GetGlucoseValueIntent.result(value:)`.
    static let description = IntentDescription("The recent glucose readings, always in mg/dL regardless of the app's display-unit setting, oldest to newest.")
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
        return .result(value: s.connected, dialog: IntentDialog(stringLiteral: s.connected ? "Connected" : "Not connected"))
    }
}

struct GetCGMActiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Is CGM Active"
    static let description = IntentDescription("Whether the pump's CGM is reporting.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Bool> & ProvidesDialog {
        let s = try loadSnap()
        return .result(value: s.cgmActive, dialog: IntentDialog(stringLiteral: s.cgmActive ? "CGM active" : "CGM inactive"))
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
    /// Phase 04-06 (D-10, A4): the returned value is ALWAYS mg/dL per unit, regardless of the
    /// app's display-unit setting — only the spoken dialog below converts.
    static let description = IntentDescription("Correction factor (ISF), always in mg/dL per unit regardless of the app's display-unit setting. The spoken dialog uses your display unit.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let s = try loadSnap()
        let unit = await AppSettings.shared.glucoseDisplayUnit
        let spoken = "\(unit.format(mgdl: s.isf)) \(unit == .mmol ? "mmol/L" : "mg/dL") per unit"
        return .result(value: s.isf, dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct GetTargetGlucoseIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Target Glucose"
    /// Phase 04-06 (D-10, A4): the returned value is ALWAYS mg/dL, regardless of the app's
    /// display-unit setting — only the spoken dialog below converts.
    static let description = IntentDescription("Target glucose, always in mg/dL regardless of the app's display-unit setting. The spoken dialog uses your display unit.")
    static let openAppWhenRun = false
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let s = try loadSnap()
        let unit = await AppSettings.shared.glucoseDisplayUnit
        let spoken = "\(unit.format(mgdl: s.targetBg)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
        return .result(value: s.targetBg, dialog: IntentDialog(stringLiteral: spoken))
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
        if let g = s.glucose {
            // Phase 04-06 (D-10): this summary's returned value IS the spoken dialog (both are the
            // same String, unlike the Int-returning intents above), so the BG figure here honors the
            // display unit with an explicit unit label (there is no separate mg/dL numeric payload
            // for an automation to compare against, unlike GetGlucoseValueIntent's .result(value:)).
            let unit = await AppSettings.shared.glucoseDisplayUnit
            let bg = "\(unit.format(mgdl: g)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
            parts.append("BG \(bg)\(s.isGlucoseStale ? " (stale)" : "")")
        }
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
    static let description = IntentDescription("Open faBolus to the bolus screen (you still confirm the dose in the app).")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        WidgetStore.requestOpenBolus()   // the app routes to the Bolus tab on becoming active
        return .result()
    }
}
