using Toybox.WatchUi as Ui;
using Toybox.Timer;
using Toybox.Lang;

// Press-and-hold the touchscreen for 3s to deliver (the venu3s has no holdable middle button).
// Lifting early cancels. The ring in HoldView fills as the hold progresses.
class HoldDelegate extends Ui.BehaviorDelegate {
    private const HOLD_MS = 3000;
    private const TICK_MS = 50;
    private var _timer as Timer.Timer?;
    private var _elapsed = 0;

    function initialize() { BehaviorDelegate.initialize(); }

    // Touch down anywhere on the screen starts the hold; lifting (or a drag-release) cancels.
    function onPress(evt as Ui.ClickEvent) as Lang.Boolean {
        if (AppState.status != null) { return false; }         // already sent
        startHold(); return true;
    }
    function onRelease(evt as Ui.ClickEvent) as Lang.Boolean {
        cancelHold(); return true;
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
