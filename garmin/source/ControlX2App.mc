using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.Communications as Comm;
using Toybox.Background;
using Toybox.Time;
using Toybox.System;
using Toybox.Timer;
using Toybox.Attention;
using Toybox.Lang;

// App entry. Glance-first: requests pump status from the phone on launch and every 30s, listens
// for status/bolus updates, and republishes the BG complication so it shows on the watch face.
// A background temporal event refreshes the complication roughly every 5 minutes while the app
// isn't open. Thin remote — the iPhone owns the pump connection.
class ControlX2App extends App.AppBase {
    private var _timer as Timer.Timer?;
    private var _lastAlertCount as Lang.Number = 0;

    function initialize() { AppBase.initialize(); }

    function onStart(state as Lang.Dictionary?) as Void {
        Comm.registerForPhoneAppMessages(method(:onPhoneMessage));
        AppState.loadPersisted();            // show last-known BG instantly (no "--" flash)
        AppState.loadPrefs();                // restore configured screen order + default screen
        BgComplication.publish(null, null, 0);  // re-publish last-known reading to the complication
        requestStatus();
        _timer = new Timer.Timer();
        _timer.start(method(:requestStatus), 15000, true);   // refresh every 15s while open
        registerBackground();
    }

    function onStop(state as Lang.Dictionary?) as Void {
        if (_timer != null) { _timer.stop(); }
    }

    function getInitialView() {
        return Nav.initialView();   // the user-configured default screen
    }

    // The background service that refreshes the complication when the app is closed.
    function getServiceDelegate() as [System.ServiceDelegate] {
        return [ new BgServiceDelegate() ];
    }

    private function registerBackground() as Void {
        if (!(Toybox has :Background)) { return; }
        try {
            var last = Background.getLastTemporalEventTime();
            if (last == null) {
                Background.registerForTemporalEvent(new Time.Duration(5 * 60));
            }
        } catch (e) {
            // Background not permitted on this device/config — foreground updates still work.
        }
    }

    function requestStatus() as Void {
        RemoteComm.send(RemoteComm.statusRead(RemoteComm.newRequestId()));
    }

    function onPhoneMessage(msg as Comm.PhoneAppMessage) as Void {
        var data = msg.data;
        if (data instanceof Lang.Dictionary) {
            AppState.handle(data as Lang.Dictionary);
            BgComplication.publishFromState();
            notifyNewAlerts();
            Ui.requestUpdate();
        }
    }

    // When a new pump alert arrives, vibrate and show an actionable confirmation to clear it.
    private function notifyNewAlerts() as Void {
        var count = AppState.alerts.size();
        if (count > _lastAlertCount && count > 0) {
            if (Attention has :vibrate) {
                Attention.vibrate([new Attention.VibeProfile(75, 400)]);
            }
            var a = AppState.alerts[0] as Lang.Dictionary;   // most-serious first
            var title = a["title"];
            Ui.pushView(new Ui.Confirmation("Pump alert: " + title + " — clear?"),
                        new AlertConfirmDelegate(a["id"], a["kind"]), Ui.SLIDE_UP);
        }
        _lastAlertCount = count;
    }

    // Called when the background service exits with data (a fresh reading fetched off-screen).
    function onBackgroundData(data as App.PersistableType) as Void {
        if (data instanceof Lang.Dictionary) {
            AppState.handle(data as Lang.Dictionary);
            BgComplication.publishFromState();
        }
    }
}
