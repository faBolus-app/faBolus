using Toybox.WatchUi as Ui;
using Toybox.System;
using Toybox.Lang;

// Tapping an alert row sends a dismiss to the phone (which signs + clears it on the pump).
class AlertsListDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }

    private function inRect(c, r) {
        return c[0] >= r[0] && c[0] <= r[0] + r[2] && c[1] >= r[1] && c[1] <= r[1] + r[3];
    }

    function onTap(evt as Ui.ClickEvent) as Lang.Boolean {
        var c = evt.getCoordinates();
        var s = System.getDeviceSettings();
        var w = s.screenWidth, h = s.screenHeight;
        var n = AppState.alerts.size();
        var shown = (n < AlertsListView.MAX_ROWS) ? n : AlertsListView.MAX_ROWS;
        for (var i = 0; i < shown; i += 1) {
            if (inRect(c, AlertsListView.rowRect(i, w, h))) {
                var a = AppState.alerts[i] as Lang.Dictionary;
                RemoteComm.send(RemoteComm.dismissAlert(RemoteComm.newRequestId(), a["id"], a["kind"]));
                var kept = [];
                for (var j = 0; j < AppState.alerts.size(); j += 1) {
                    if (j != i) { kept.add(AppState.alerts[j]); }
                }
                AppState.alerts = kept;
                Ui.requestUpdate();
                return true;
            }
        }
        return true;
    }

    // Swipe between screens in the user-configured order.
    function onNextPage() as Lang.Boolean { return Nav.goNext("alerts"); }
    function onPreviousPage() as Lang.Boolean { return Nav.goPrev("alerts"); }
}
