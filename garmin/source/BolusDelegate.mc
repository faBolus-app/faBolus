using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Bolus entry input, using the venu3s's real gesture model (confirmed from the device profile):
//   • swipe up  = onNextPage      → increase
//   • swipe down = onPreviousPage → decrease
//   • tap / top button = onSelect → Deliver (go to hold-to-confirm)
//   • hold top button = onMenu    → toggle Units / Carbs
// A screen tap on this device fires onSelect (not onTap), which is why coordinate-based tap
// buttons never worked; adjustment is done by swiping.
class BolusEntryDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    function onNextPage() as Lang.Boolean { AppState.adjust(1); Ui.requestUpdate(); return true; }
    function onPreviousPage() as Lang.Boolean { AppState.adjust(-1); Ui.requestUpdate(); return true; }
    function onMenu() as Lang.Boolean { AppState.toggleMode(); Ui.requestUpdate(); return true; }

    function onSelect() as Lang.Boolean {
        AppState.deliverUnits = AppState.computeUnits();
        if (AppState.deliverUnits < 0.05) { return true; }   // nothing to deliver
        AppState.holdProgress = 0.0;
        Ui.pushView(new HoldView(), new HoldDelegate(), Ui.SLIDE_LEFT);
        return true;
    }
}
