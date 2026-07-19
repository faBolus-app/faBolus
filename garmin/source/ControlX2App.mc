using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.Communications as Comm;
using Toybox.Lang;

// App entry. Starts on the glance HUD, listens for phone status/bolus updates, and requests a
// status read on launch. Thin remote — the iPhone owns the pump connection (PumpX2Kit).
class ControlX2App extends App.AppBase {
    function initialize() { AppBase.initialize(); }

    function onStart(state as Lang.Dictionary?) as Void {
        Comm.registerForPhoneAppMessages(method(:onPhoneMessage));
        // Status is requested on demand (menu / when the phone connects), not at launch, so the
        // app renders immediately even with no phone paired.
    }

    function onStop(state as Lang.Dictionary?) as Void {}

    function getInitialView() {
        return [ new MainView(), new MainDelegate() ];
    }

    // Status / bolus updates from the iPhone host (schema: statusRead / bolusStatus).
    function onPhoneMessage(msg as Comm.PhoneAppMessage) as Void {
        var data = msg.data;
        if (data instanceof Lang.Dictionary) {
            AppState.handle(data as Lang.Dictionary);
            Ui.requestUpdate();
        }
    }
}
