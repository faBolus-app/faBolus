using Toybox.WatchUi as Ui;
using Toybox.Lang;
using Toybox.System;

// Bolus entry input (touch). Big full-screen zones so a tap always lands somewhere reachable
// (edge touches are eaten by the watch's swipe gestures, so we rely on generous bands):
//   • top band    → toggle Units/Carbs
//   • middle-left → −   middle-right → +
//   • bottom band → Deliver
// No onSelect override: taps must reach onTap, and the physical buttons can't dial on venu3s.
class BolusEntryDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    private function goDeliver() as Lang.Boolean {
        AppState.deliverUnits = AppState.computeUnits();
        if (AppState.deliverUnits < 0.05) { return true; }   // nothing to deliver
        AppState.holdProgress = 0.0;
        Ui.pushView(new HoldView(), new HoldDelegate(), Ui.SLIDE_LEFT);
        return true;
    }

    function onTap(evt as Ui.ClickEvent) as Lang.Boolean {
        var c = evt.getCoordinates();
        var x = c[0], y = c[1];
        var s = System.getDeviceSettings();
        var w = s.screenWidth, h = s.screenHeight;

        if (y >= BolusEntryView.deliverBandMinY(h)) { return goDeliver(); }
        if (y <= BolusEntryView.topBandMaxY(h)) { AppState.toggleMode(); Ui.requestUpdate(); return true; }
        // Middle band: left half decreases, right half increases.
        AppState.adjust(x < w / 2 ? -1 : 1);
        Ui.requestUpdate();
        return true;
    }
}
