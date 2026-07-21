import Foundation

/// User display preferences for the Mac remote, shared between the menu-bar app and the Mac widgets
/// via the App Group so both render the same way. Booleans default sensibly when unset (and when the
/// App Group is unavailable, e.g. an ad-hoc local build, reads fall back to the defaults). Keep keys
/// stable.
enum DisplaySettings {
    private static var d: UserDefaults? { UserDefaults(suiteName: WidgetStore.appGroup) }

    private static func flag(_ key: String, _ def: Bool) -> Bool {
        guard let d, d.object(forKey: key) != nil else { return def }
        return d.bool(forKey: key)
    }
    private static func setFlag(_ key: String, _ v: Bool) { d?.set(v, forKey: key) }
    private static func number(_ key: String, _ def: Double) -> Double {
        guard let d, d.object(forKey: key) != nil else { return def }
        let v = d.double(forKey: key); return v > 0 ? v : def
    }
    private static func setNumber(_ key: String, _ v: Double) { d?.set(v, forKey: key) }
    private static func text(_ key: String, _ def: String) -> String { d?.string(forKey: key) ?? def }
    private static func setText(_ key: String, _ v: String) { d?.set(v, forKey: key) }

    // MARK: Appearance
    /// Draw a solid (opaque) popover background instead of the translucent system material.
    static var solidBackground: Bool { get { flag("solidBackground", false) } set { setFlag("solidBackground", newValue) } }

    // MARK: Bolus entry (Mac-local; overrides the increments/mode the phone mirrors)
    static var bolusIncrement: Double { get { number("macBolusIncrement", 0.05) } set { setNumber("macBolusIncrement", newValue) } }
    static var carbIncrement: Double { get { number("macCarbIncrement", 5) } set { setNumber("macCarbIncrement", newValue) } }
    static var defaultBolusMode: String { get { text("macDefaultBolusMode", "carbs") } set { setText("macDefaultBolusMode", newValue) } }

    // MARK: Menu bar
    /// Show the trend arrow next to the glucose value.
    static var menuBarShowTrend: Bool { get { flag("mbShowTrend", true) } set { setFlag("mbShowTrend", newValue) } }
    /// Color the menu-bar value by glucose range (low/in-range/high/urgent).
    static var menuBarColorByRange: Bool { get { flag("mbColorByRange", true) } set { setFlag("mbColorByRange", newValue) } }
    /// Append IOB (e.g. "· 1.2U") to the menu-bar value.
    static var menuBarShowIOB: Bool { get { flag("mbShowIOB", false) } set { setFlag("mbShowIOB", newValue) } }
    /// Append the delta since the previous reading (e.g. "+3").
    static var menuBarShowDelta: Bool { get { flag("mbShowDelta", false) } set { setFlag("mbShowDelta", newValue) } }
    /// Append the "mg/dL" unit label.
    static var menuBarShowUnits: Bool { get { flag("mbShowUnits", false) } set { setFlag("mbShowUnits", newValue) } }

    // MARK: Status details (popover pills + widgets)
    static var showIOB: Bool { get { flag("dispIOB", true) } set { setFlag("dispIOB", newValue) } }
    static var showReservoir: Bool { get { flag("dispReservoir", true) } set { setFlag("dispReservoir", newValue) } }
    static var showBattery: Bool { get { flag("dispBattery", true) } set { setFlag("dispBattery", newValue) } }
    static var showLastBolus: Bool { get { flag("dispLastBolus", true) } set { setFlag("dispLastBolus", newValue) } }
    /// Color glucose by range in the widgets (matches the menu-bar option).
    static var widgetColorByRange: Bool { get { flag("widgetColorByRange", true) } set { setFlag("widgetColorByRange", newValue) } }
}
