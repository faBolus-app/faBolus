using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Pump alerts screen (swipe up from details): lists active alerts/alarms; tap a row to clear it
// (the phone sends the signed dismiss to the pump). Plain onTap hit-testing. Up to 4 shown.
class AlertsListView extends Ui.View {
    static const MAX_ROWS = 4;

    function initialize() { View.initialize(); }

    // Row rect (pixels) for index i: [x, y, w, h].
    static function rowRect(i, w, h) {
        var rowH = h * 0.15;
        var y = h * (0.20 + 0.16 * i);
        return [w * 0.12, y, w * 0.76, rowH];
    }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var vc = Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER;

        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.13, Gfx.FONT_XTINY, "Alerts", vc);

        var n = AppState.alerts.size();
        if (n == 0) {
            dc.setColor(Gfx.COLOR_GREEN, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, h / 2, Gfx.FONT_SMALL, "No alerts", vc);
            return;
        }
        var shown = (n < MAX_ROWS) ? n : MAX_ROWS;
        for (var i = 0; i < shown; i += 1) {
            var a = AppState.alerts[i] as Lang.Dictionary;
            var rr = rowRect(i, w, h);
            dc.setColor(0x3A2A00, Gfx.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(rr[0], rr[1], rr[2], rr[3], 8);
            dc.setColor(Gfx.COLOR_YELLOW, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, rr[1] + rr[3] / 2, Gfx.FONT_XTINY, a["title"], vc);
        }
        // Hint at the bottom (wider part of the round screen), only when there are alerts.
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.90, Gfx.FONT_XTINY, "tap a row to clear", vc);
    }
}
