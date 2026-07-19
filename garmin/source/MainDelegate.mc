using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Glance HUD input: START/ENTER or a tap opens the bolus flow; a status read is requested to
// refresh the HUD.
class MainDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    function openBolus() as Lang.Boolean {
        AppState.resetBolus();
        Ui.pushView(new BolusView(), new BolusDelegate(), Ui.SLIDE_LEFT);
        return true;
    }

    function onSelect() as Lang.Boolean { return openBolus(); }

    function onKey(evt as Ui.KeyEvent) as Lang.Boolean {
        var key = evt.getKey();
        if (key == Ui.KEY_ENTER || key == Ui.KEY_START) { return openBolus(); }
        return false;
    }

    function onTap(evt as Ui.ClickEvent) as Lang.Boolean { return openBolus(); }

    // Request a fresh status read from the phone.
    function onMenu() as Lang.Boolean {
        RemoteComm.send(RemoteComm.statusRead(RemoteComm.newRequestId()));
        return true;
    }
}
