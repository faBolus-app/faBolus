using Toybox.WatchUi as Ui;
using Toybox.Lang;
using Toybox.System;
using Toybox.Math;

// Bolus entry input (touch): tap the mode chip to switch Units/Carbs, tap − / + to adjust, tap
// Deliver (or press the top button) to go to hold-to-confirm.
class BolusEntryDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    private function inRect(c, r) {
        return c[0] >= r[0] && c[0] <= r[0] + r[2] && c[1] >= r[1] && c[1] <= r[1] + r[3];
    }
    private function nearCircle(c, center, radius) {
        var dx = c[0] - center[0], dy = c[1] - center[1];
        return Math.sqrt(dx * dx + dy * dy) <= radius * 1.25;   // a little forgiving
    }

    private function goDeliver() as Lang.Boolean {
        AppState.deliverUnits = AppState.computeUnits();
        if (AppState.deliverUnits < 0.05) { return true; }   // nothing to deliver
        AppState.holdProgress = 0.0;
        Ui.pushView(new HoldView(), new HoldDelegate(), Ui.SLIDE_LEFT);
        return true;
    }

    function onTap(evt as Ui.ClickEvent) as Lang.Boolean {
        var c = evt.getCoordinates();
        var s = System.getDeviceSettings();
        var w = s.screenWidth, h = s.screenHeight;

        if (nearCircle(c, BolusEntryView.minusCenter(w, h), BolusEntryView.stepRadius(w))) {
            AppState.adjust(-1); Ui.requestUpdate(); return true;
        }
        if (nearCircle(c, BolusEntryView.plusCenter(w, h), BolusEntryView.stepRadius(w))) {
            AppState.adjust(1); Ui.requestUpdate(); return true;
        }
        if (inRect(c, BolusEntryView.chipRect(w, h))) {
            AppState.toggleMode(); Ui.requestUpdate(); return true;
        }
        if (inRect(c, BolusEntryView.deliverRect(w, h))) { return goDeliver(); }
        return true;
    }

    // Top physical button = Deliver shortcut.
    function onSelect() as Lang.Boolean { return goDeliver(); }
    function onKey(evt as Ui.KeyEvent) as Lang.Boolean {
        var k = evt.getKey();
        if (k == Ui.KEY_ENTER || k == Ui.KEY_START) { return goDeliver(); }
        return false;
    }
}
