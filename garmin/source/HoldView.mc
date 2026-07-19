using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Confirm screen: shows the units to deliver and a ring that fills as the middle button is
// held. At 100% (3s) it sends the bolus. Once sent, shows delivery status.
class HoldView extends Ui.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth(), h = dc.getHeight();
        var cx = w / 2, cy = h / 2;

        if (AppState.status != null) {
            var s = AppState.status as Lang.String;
            var color = Gfx.COLOR_BLUE;
            if (s.equals("delivered")) { color = Gfx.COLOR_GREEN; }
            else if (s.equals("failed") || s.equals("outOfRange")) { color = Gfx.COLOR_RED; }
            dc.setColor(color, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 30, Gfx.FONT_MEDIUM, s, Gfx.TEXT_JUSTIFY_CENTER);
            if (AppState.message != null) {
                dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
                dc.drawText(cx, cy + 10, Gfx.FONT_XTINY, AppState.message, Gfx.TEXT_JUSTIFY_CENTER);
            }
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + 55, Gfx.FONT_XTINY, "BACK to exit", Gfx.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Progress ring (fills clockwise from the top as the button is held).
        var r = (w / 2) - 8;
        dc.setPenWidth(12);
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, r, Gfx.ARC_CLOCKWISE, 0, 360);
        if (AppState.holdProgress > 0.0) {
            dc.setColor(0x5C6BE6, Gfx.COLOR_TRANSPARENT);
            var endDeg = 90 - (360.0 * AppState.holdProgress);
            dc.drawArc(cx, cy, r, Gfx.ARC_CLOCKWISE, 90, endDeg);
        }
        dc.setPenWidth(1);

        dc.setColor(0x8AB4FF, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 34, Gfx.FONT_NUMBER_MEDIUM, AppState.deliverUnits.format("%.2f") + " U", Gfx.TEXT_JUSTIFY_CENTER);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 22, Gfx.FONT_XTINY, "Hold middle button", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, cy + 40, Gfx.FONT_XTINY, "saline · bench", Gfx.TEXT_JUSTIFY_CENTER);
    }
}
