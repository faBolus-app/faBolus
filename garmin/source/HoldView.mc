using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Confirm screen: tap the numbered targets 1 → 2 → 3 in order (sequentially, not held) to
// deliver — like unlocking a t:slim. A wrong/out-of-order tap resets to 1. Uses plain onTap
// coordinate hit-testing (reliable on the venu3s). Once sent, shows delivery status.
class HoldView extends Ui.View {
    private var _progress as Lang.Number = 0;   // correct taps so far (0..3)

    function initialize() { View.initialize(); }

    // Circle centers/radius (pixels), shared with the delegate. In order, left → right.
    // Spread out and sized so the three circles don't overlap.
    static function center(i, w, h) {
        var xs = [0.23, 0.50, 0.77];
        return [ (w * xs[i]).toNumber(), (h * 0.50).toNumber() ];
    }
    static function radius(w) { return (w * 0.11).toNumber(); }

    // Cancel button (shown while delivering). [x,y,w,h].
    static function cancelRect(w, h) { return [w / 2 - w * 0.26, h * 0.66, w * 0.52, h * 0.15]; }

    function progress() as Lang.Number { return _progress; }

    // Register a tap on button number `num` (1..3).
    function tapped(num as Lang.Number) as Void {
        if (AppState.status != null) { return; }
        if (num == _progress + 1) {
            _progress += 1;
            if (_progress >= 3) { deliver(); }
        } else {
            _progress = 0;   // out of order — start over
        }
        Ui.requestUpdate();
    }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2, cy = h / 2;
        var vc = Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER;

        if (AppState.status != null) {
            var s = AppState.status as Lang.String;
            var color = Gfx.COLOR_BLUE;
            if (s.equals("delivered")) { color = Gfx.COLOR_GREEN; }
            else if (s.equals("failed") || s.equals("outOfRange")) { color = Gfx.COLOR_RED; }
            dc.setColor(color, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.30, Gfx.FONT_MEDIUM, s, Gfx.TEXT_JUSTIFY_CENTER);
            if (AppState.message != null) {
                dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
                dc.drawText(cx, h * 0.44, Gfx.FONT_XTINY, AppState.message, Gfx.TEXT_JUSTIFY_CENTER);
            }
            // While delivering, a red Cancel button (tap) instead of relying on the BACK button.
            if (s.equals("delivering") || s.equals("cancelling")) {
                var cr = cancelRect(w, h);
                dc.setColor(Gfx.COLOR_RED, Gfx.COLOR_TRANSPARENT);
                dc.fillRoundedRectangle(cr[0], cr[1], cr[2], cr[3], 10);
                dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
                dc.drawText(cx, cr[1] + cr[3] / 2, Gfx.FONT_SMALL, "Cancel",
                            Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
            } else {
                dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
                dc.drawText(cx, h * 0.80, Gfx.FONT_XTINY, "BACK to exit", Gfx.TEXT_JUSTIFY_CENTER);
            }
            return;
        }

        dc.setColor(0x8AB4FF, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.14, Gfx.FONT_SMALL, AppState.deliverUnits.format("%.2f") + " U", vc);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.28, Gfx.FONT_XTINY, "Tap 1 - 2 - 3 in order", vc);

        var r = radius(w);
        for (var i = 0; i < 3; i += 1) {
            var c = center(i, w, h);
            var done = (i + 1) <= _progress;
            dc.setColor(done ? Gfx.COLOR_GREEN : 0x333333, Gfx.COLOR_TRANSPARENT);
            dc.fillCircle(c[0], c[1], r);
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            dc.drawText(c[0], c[1], Gfx.FONT_NUMBER_MEDIUM, (i + 1).toString(), vc);
        }

        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.90, Gfx.FONT_XTINY, "saline · bench", vc);
    }

    private function deliver() as Void {
        var reqId = RemoteComm.newRequestId();
        AppState.pendingRequestId = reqId;
        if (!RemoteComm.phoneReachable()) {
            AppState.status = "outOfRange"; AppState.message = "iPhone unreachable"; return;
        }
        AppState.status = "delivering";
        RemoteComm.send(RemoteComm.bolusRequest(AppState.deliverUnits, reqId));
    }
}
