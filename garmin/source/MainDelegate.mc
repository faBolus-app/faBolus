using Toybox.WatchUi as Ui;
using Toybox.System;
using Toybox.Lang;

// Glance input: tap the Bolus button (only) to open bolus entry. The top physical button
// (SELECT) is also a shortcut. Tapping elsewhere on the glance does nothing.
class MainDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    private function openBolus() as Lang.Boolean {
        AppState.reset();
        Ui.pushView(new BolusEntryView(), new BolusEntryDelegate(), Ui.SLIDE_LEFT);
        return true;
    }

    // Only a tap inside the Bolus button opens the bolus screen (matches MainView geometry).
    function onTap(evt as Ui.ClickEvent) as Lang.Boolean {
        var c = evt.getCoordinates();
        var s = System.getDeviceSettings();
        var w = s.screenWidth, h = s.screenHeight;
        var bw = w * 0.52, bh = h * 0.17;
        var bx = (w - bw) / 2, by = h * 0.68;
        if (c[0] >= bx && c[0] <= bx + bw && c[1] >= by && c[1] <= by + bh) {
            return openBolus();
        }
        return true;   // swallow taps elsewhere so the glance doesn't jump to bolus
    }

    function onSelect() as Lang.Boolean { return openBolus(); }
    function onKey(evt as Ui.KeyEvent) as Lang.Boolean {
        var k = evt.getKey();
        if (k == Ui.KEY_ENTER || k == Ui.KEY_START) { return openBolus(); }
        return false;
    }

    // Swipe up → Alerts (one swipe from the glance), then up again for history, then details.
    function onNextPage() as Lang.Boolean {
        Ui.pushView(new AlertsListView(), new AlertsListDelegate(), Ui.SLIDE_UP);
        return true;
    }
}
