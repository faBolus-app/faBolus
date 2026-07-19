using Toybox.WatchUi as Ui;
using Toybox.Lang;
using Toybox.System;

// Bolus entry input: top/bottom buttons adjust the value; tap the mode chip to switch
// Units/Carbs; tap Deliver to go to hold-to-confirm.
class BolusEntryDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    function onKey(evt as Ui.KeyEvent) as Lang.Boolean {
        var k = evt.getKey();
        if (k == Ui.KEY_UP) { AppState.adjust(1); Ui.requestUpdate(); return true; }
        if (k == Ui.KEY_DOWN) { AppState.adjust(-1); Ui.requestUpdate(); return true; }
        return false;
    }

    function onTap(evt as Ui.ClickEvent) as Lang.Boolean {
        var y = evt.getCoordinates()[1];
        var h = System.getDeviceSettings().screenHeight;
        if (y <= BolusEntryView.modeZoneMaxY(h)) {
            AppState.toggleMode(); Ui.requestUpdate(); return true;
        }
        if (y >= BolusEntryView.deliverZoneMinY(h)) {
            AppState.deliverUnits = AppState.computeUnits();
            if (AppState.deliverUnits < 0.05) { return true; }   // nothing to deliver
            AppState.holdProgress = 0.0;
            Ui.pushView(new HoldView(), new HoldDelegate(), Ui.SLIDE_LEFT);
            return true;
        }
        return false;
    }
}
