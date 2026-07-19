using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Confirmation shown when a new pump alert arrives (an actionable "notification"): choosing Yes
// clears that alert via the phone. Choosing No dismisses the prompt (the alert stays in the list).
class AlertConfirmDelegate extends Ui.ConfirmationDelegate {
    private var _id as Lang.Number;
    private var _kind as Lang.Number;

    function initialize(id as Lang.Number, kind as Lang.Number) {
        ConfirmationDelegate.initialize();
        _id = id; _kind = kind;
    }

    function onResponse(response) as Lang.Boolean {
        if (response == Ui.CONFIRM_YES) {
            RemoteComm.send(RemoteComm.dismissAlert(RemoteComm.newRequestId(), _id, _kind));
            // Optimistically remove locally.
            var kept = [];
            for (var i = 0; i < AppState.alerts.size(); i += 1) {
                var a = AppState.alerts[i] as Lang.Dictionary;
                if (!(a["id"] == _id && a["kind"] == _kind)) { kept.add(a); }
            }
            AppState.alerts = kept;
            Ui.requestUpdate();
        }
        return true;
    }
}
