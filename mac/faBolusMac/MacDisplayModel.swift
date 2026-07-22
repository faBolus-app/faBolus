import Foundation
import WidgetKit

/// Observable wrapper over `DisplaySettings` for the Mac app: SwiftUI Toggles bind to these, and the
/// menu-bar view re-renders when they change (every getter reads `revision`, which each setter bumps).
/// Setters persist to the App Group and refresh the widgets so both surfaces stay in sync.
@MainActor
@Observable
final class MacDisplayModel {
    /// Bumped on every change so observers (menu bar) re-render; each getter reads it to subscribe.
    private var revision = 0
    private func bump() { revision &+= 1; WidgetCenter.shared.reloadAllTimelines() }

    var menuBarHideStale: Bool {
        get { _ = revision; return DisplaySettings.menuBarHideStale }
        set { DisplaySettings.menuBarHideStale = newValue; bump() }
    }
    var menuBarShowTrend: Bool {
        get { _ = revision; return DisplaySettings.menuBarShowTrend }
        set { DisplaySettings.menuBarShowTrend = newValue; bump() }
    }
    var menuBarColorByRange: Bool {
        get { _ = revision; return DisplaySettings.menuBarColorByRange }
        set { DisplaySettings.menuBarColorByRange = newValue; bump() }
    }
    var menuBarShowIOB: Bool {
        get { _ = revision; return DisplaySettings.menuBarShowIOB }
        set { DisplaySettings.menuBarShowIOB = newValue; bump() }
    }
    var menuBarShowDelta: Bool {
        get { _ = revision; return DisplaySettings.menuBarShowDelta }
        set { DisplaySettings.menuBarShowDelta = newValue; bump() }
    }
    var menuBarShowUnits: Bool {
        get { _ = revision; return DisplaySettings.menuBarShowUnits }
        set { DisplaySettings.menuBarShowUnits = newValue; bump() }
    }

    var showIOB: Bool {
        get { _ = revision; return DisplaySettings.showIOB }
        set { DisplaySettings.showIOB = newValue; bump() }
    }
    var showReservoir: Bool {
        get { _ = revision; return DisplaySettings.showReservoir }
        set { DisplaySettings.showReservoir = newValue; bump() }
    }
    var showBattery: Bool {
        get { _ = revision; return DisplaySettings.showBattery }
        set { DisplaySettings.showBattery = newValue; bump() }
    }
    var showLastBolus: Bool {
        get { _ = revision; return DisplaySettings.showLastBolus }
        set { DisplaySettings.showLastBolus = newValue; bump() }
    }
    var widgetColorByRange: Bool {
        get { _ = revision; return DisplaySettings.widgetColorByRange }
        set { DisplaySettings.widgetColorByRange = newValue; bump() }
    }

    // Appearance
    var solidBackground: Bool {
        get { _ = revision; return DisplaySettings.solidBackground }
        set { DisplaySettings.solidBackground = newValue; bump() }
    }

    // Bolus entry
    var bolusIncrement: Double {
        get { _ = revision; return DisplaySettings.bolusIncrement }
        set { DisplaySettings.bolusIncrement = newValue; bump() }
    }
    var carbIncrement: Double {
        get { _ = revision; return DisplaySettings.carbIncrement }
        set { DisplaySettings.carbIncrement = newValue; bump() }
    }
    var defaultBolusMode: String {
        get { _ = revision; return DisplaySettings.defaultBolusMode }
        set { DisplaySettings.defaultBolusMode = newValue; bump() }
    }
    var carbButtonInUnits: Bool {
        get { _ = revision; return DisplaySettings.carbButtonInUnits }
        set { DisplaySettings.carbButtonInUnits = newValue; bump() }
    }
}
