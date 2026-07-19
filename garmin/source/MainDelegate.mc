using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Glance input: tap the Bolus button (or press START) to open the bolus entry screen.
class MainDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    private function openBolus() as Lang.Boolean {
        AppState.reset();
        Ui.pushView(new BolusEntryView(), new BolusEntryDelegate(), Ui.SLIDE_LEFT);
        return true;
    }

    function onTap(evt as Ui.ClickEvent) as Lang.Boolean { return openBolus(); }
    function onSelect() as Lang.Boolean { return openBolus(); }
    function onKey(evt as Ui.KeyEvent) as Lang.Boolean {
        var k = evt.getKey();
        if (k == Ui.KEY_ENTER || k == Ui.KEY_START) { return openBolus(); }
        return false;
    }
}
