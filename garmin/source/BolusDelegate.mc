using Toybox.WatchUi as Ui;
using Toybox.Lang;
using Toybox.System;

// Bolus input for the touch venu3s: tap top (+) / bottom (−) to adjust units; START/ENTER
// requests on the iPhone (double-confirm there). BACK pops. The watch never delivers directly.
class BolusDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    function onKey(evt as Ui.KeyEvent) as Lang.Boolean {
        var key = evt.getKey();
        if (key == Ui.KEY_ENTER || key == Ui.KEY_START) { return sendRequest(); }
        return false;
    }

    function onSelect() as Lang.Boolean { return sendRequest(); }

    // Touch: top third increments, bottom third decrements, middle sends.
    function onTap(evt as Ui.ClickEvent) as Lang.Boolean {
        if (AppState.bolusStatus != null) { return false; }
        var coords = evt.getCoordinates();
        var y = coords[1];
        var h = System.getDeviceSettings().screenHeight;
        if (y < h / 3) { AppState.adjust(AppState.STEP); Ui.requestUpdate(); return true; }
        if (y > (2 * h) / 3) { AppState.adjust(-AppState.STEP); Ui.requestUpdate(); return true; }
        return sendRequest();
    }

    function sendRequest() as Lang.Boolean {
        if (AppState.units < AppState.STEP || AppState.bolusStatus != null) { return false; }
        var reqId = RemoteComm.newRequestId();
        AppState.pendingRequestId = reqId;
        if (!RemoteComm.phoneReachable()) {
            AppState.bolusStatus = "outOfRange";
            AppState.bolusMessage = "iPhone unreachable";
            Ui.requestUpdate();
            return true;
        }
        AppState.bolusStatus = "awaitingConfirm";
        AppState.bolusMessage = "Confirm on iPhone";
        RemoteComm.send(RemoteComm.bolusRequest(AppState.units, reqId));
        Ui.requestUpdate();
        return true;
    }
}
