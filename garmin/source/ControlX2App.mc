using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.Communications as Comm;
using Toybox.Timer;
using Toybox.Lang;

// App entry. Glance-first: requests pump status from the phone on launch and every 30s, and
// listens for status/bolus updates. Thin remote — the iPhone owns the pump connection.
class ControlX2App extends App.AppBase {
    private var _timer as Timer.Timer?;

    function initialize() { AppBase.initialize(); }

    function onStart(state as Lang.Dictionary?) as Void {
        Comm.registerForPhoneAppMessages(method(:onPhoneMessage));
        requestStatus();
        _timer = new Timer.Timer();
        _timer.start(method(:requestStatus), 30000, true);   // refresh every 30s
    }

    function onStop(state as Lang.Dictionary?) as Void {
        if (_timer != null) { _timer.stop(); }
    }

    function getInitialView() {
        return [ new MainView(), new MainDelegate() ];
    }

    function requestStatus() as Void {
        RemoteComm.send(RemoteComm.statusRead(RemoteComm.newRequestId()));
    }

    function onPhoneMessage(msg as Comm.PhoneAppMessage) as Void {
        var data = msg.data;
        if (data instanceof Lang.Dictionary) {
            AppState.handle(data as Lang.Dictionary);
            Ui.requestUpdate();
        }
    }
}
