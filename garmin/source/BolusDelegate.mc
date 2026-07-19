using Toybox.WatchUi as Ui;
using Toybox.System;

// Button/key handling for the bolus picker. UP/DOWN adjust units; START/ENTER sends a
// units-only bolusRequest to the phone (which runs the second confirm). BACK cancels.
class BolusDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    function onKey(evt) {
        var key = evt.getKey();
        if (key == Ui.KEY_UP) {
            BolusState.adjust(BolusState.STEP); Ui.requestUpdate(); return true;
        } else if (key == Ui.KEY_DOWN) {
            BolusState.adjust(-BolusState.STEP); Ui.requestUpdate(); return true;
        } else if (key == Ui.KEY_ENTER || key == Ui.KEY_START) {
            sendRequest(); return true;
        }
        return false;
    }

    function onSelect() { sendRequest(); return true; }

    function sendRequest() {
        if (BolusState.units < BolusState.STEP) { return; }
        var reqId = RemoteComm.newRequestId();
        BolusState.pendingRequestId = reqId;
        BolusState.status = "awaitingConfirm";
        BolusState.message = "Confirm on iPhone";
        var cmd = RemoteComm.bolusRequest(BolusState.units, reqId);
        RemoteComm.send(cmd, method(:onSendComplete));
        Ui.requestUpdate();
    }

    function onSendComplete(code) {
        if (code != 0) {   // non-zero => transmit failure (phone out of range)
            BolusState.status = "outOfRange";
            BolusState.message = "iPhone unreachable";
            Ui.requestUpdate();
        }
    }
}
