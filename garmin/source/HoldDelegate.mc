using Toybox.WatchUi as Ui;
using Toybox.Lang;
using Toybox.System;
using Toybox.Math;

// Confirm-screen input: tap the numbered circles 1 → 2 → 3 in order. Plain onTap coordinate
// hit-testing (reliable on the venu3s); the view enforces the sequence.
class HoldDelegate extends Ui.BehaviorDelegate {
    private var _view as HoldView;
    function initialize(view as HoldView) { BehaviorDelegate.initialize(); _view = view; }

    function onTap(evt as Ui.ClickEvent) as Lang.Boolean {
        var c = evt.getCoordinates();
        var s = System.getDeviceSettings();
        var w = s.screenWidth, h = s.screenHeight;

        // While delivering, the only control is the Cancel button.
        if (AppState.status != null) {
            if (AppState.status.equals("delivering")) {
                var cr = HoldView.cancelRect(w, h);
                if (c[0] >= cr[0] && c[0] <= cr[0] + cr[2] && c[1] >= cr[1] && c[1] <= cr[1] + cr[3]) {
                    if (AppState.pendingRequestId != null) {
                        RemoteComm.send(RemoteComm.cancelBolus(AppState.pendingRequestId));
                    }
                    AppState.status = "cancelling"; Ui.requestUpdate();
                }
            }
            return true;
        }

        // Otherwise: the 1-2-3 confirm circles.
        var r = HoldView.radius(w);
        for (var i = 0; i < 3; i += 1) {
            var ctr = HoldView.center(i, w, h);
            var dx = c[0] - ctr[0], dy = c[1] - ctr[1];
            if (Math.sqrt(dx * dx + dy * dy) <= r * 1.3) { _view.tapped(i + 1); return true; }
        }
        return true;
    }
}
