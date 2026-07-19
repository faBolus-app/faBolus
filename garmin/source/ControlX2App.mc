using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.Communications as Comm;

// App entry. Registers a phone-message listener so status echoed back from the iPhone host
// (bolusStatus) can update the UI.
class ControlX2App extends App.AppBase {
    function initialize() { AppBase.initialize(); }

    function onStart(state) {
        Comm.registerForPhoneAppMessages(method(:onPhoneMessage));
    }

    function onStop(state) {}

    function getInitialView() {
        return [ new BolusView(), new BolusDelegate() ];
    }

    // Receives status updates from the iPhone host (schema: bolusStatus / statusRead).
    function onPhoneMessage(msg) {
        var data = msg.data;
        if (data != null && data.hasKey("kind")) {
            BolusState.handle(data);
            Ui.requestUpdate();
        }
    }
}
