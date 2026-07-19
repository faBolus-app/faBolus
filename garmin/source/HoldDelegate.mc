using Toybox.WatchUi as Ui;
using Toybox.Timer;
using Toybox.Lang;

// Press-and-hold the middle button for 3s to deliver. Releasing early cancels. The ring in
// HoldView fills as the hold progresses.
class HoldDelegate extends Ui.BehaviorDelegate {
    private const HOLD_MS = 3000;
    private const TICK_MS = 50;
    private var _timer as Timer.Timer?;
    private var _elapsed = 0;

    function initialize() { BehaviorDelegate.initialize(); }

    function onKeyPressed(evt as Ui.KeyEvent) as Lang.Boolean {
        if (AppState.status != null) { return false; }         // already sent
        if (evt.getKey() == Ui.KEY_ENTER) { startHold(); return true; }
        return false;
    }

    function onKeyReleased(evt as Ui.KeyEvent) as Lang.Boolean {
        if (evt.getKey() == Ui.KEY_ENTER) { cancelHold(); return true; }
        return false;
    }

    private function startHold() as Void {
        _elapsed = 0;
        AppState.holdProgress = 0.0;
        if (_timer == null) { _timer = new Timer.Timer(); }
        _timer.start(method(:onTick), TICK_MS, true);
    }

    private function cancelHold() as Void {
        if (_timer != null) { _timer.stop(); }
        if (AppState.status == null) { AppState.holdProgress = 0.0; Ui.requestUpdate(); }
    }

    function onTick() as Void {
        _elapsed += TICK_MS;
        AppState.holdProgress = _elapsed.toFloat() / HOLD_MS;
        if (_elapsed >= HOLD_MS) {
            AppState.holdProgress = 1.0;
            if (_timer != null) { _timer.stop(); }
            deliver();
        }
        Ui.requestUpdate();
    }

    private function deliver() as Void {
        var reqId = RemoteComm.newRequestId();
        AppState.pendingRequestId = reqId;
        if (!RemoteComm.phoneReachable()) {
            AppState.status = "outOfRange"; AppState.message = "iPhone unreachable"; Ui.requestUpdate(); return;
        }
        AppState.status = "delivering";
        RemoteComm.send(RemoteComm.bolusRequest(AppState.deliverUnits, reqId));
        Ui.requestUpdate();
    }
}
