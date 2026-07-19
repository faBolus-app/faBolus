using Toybox.WatchUi as Ui;
using Toybox.Lang;
using Toybox.System;
using Toybox.Math;

// Bolus entry input — tap buttons (onTap fires with coordinates on this device). Tap − / + to
// adjust, the mode chip to toggle Units/Carbs, Deliver to go to the 1-2-3 confirm screen.
class BolusEntryDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    private function inRect(c, r) {
        return c[0] >= r[0] && c[0] <= r[0] + r[2] && c[1] >= r[1] && c[1] <= r[1] + r[3];
    }
    private function nearCircle(c, center, radius) {
        var dx = c[0] - center[0], dy = c[1] - center[1];
        return Math.sqrt(dx * dx + dy * dy) <= radius * 1.3;   // a little forgiving
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
        if (inRect(c, BolusEntryView.deliverRect(w, h))) {
            AppState.deliverUnits = AppState.computeUnits();
            if (AppState.deliverUnits < 0.05) { return true; }   // nothing to deliver
            var v = new HoldView();
            Ui.pushView(v, new HoldDelegate(v), Ui.SLIDE_LEFT);
            return true;
        }
        return true;
    }
}
