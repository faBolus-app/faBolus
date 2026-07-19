using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Lang;

// Loop-style glance HUD: glucose + trend inside a status ring, Active Insulin, phone
// connection, and a hint to open the bolus flow. Parity with the Apple Watch glance.
class MainView extends Ui.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;
        var connected = System.getDeviceSettings().phoneConnected;

        // Status ring (green when phone connected, gray otherwise).
        dc.setPenWidth(8);
        dc.setColor(connected ? Gfx.COLOR_GREEN : Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, (w / 2) - 6, Gfx.ARC_CLOCKWISE, 90, connected ? 90 - 359 : 60);
        dc.setPenWidth(1);

        // Title
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 96, Gfx.FONT_XTINY, "ControlX2", Gfx.TEXT_JUSTIFY_CENTER);

        // Glucose (+ a drawn trend triangle when we have a reading)
        var glucoseText = (AppState.glucose == null) ? "--" : (AppState.glucose as Lang.Number).toString();
        dc.setColor(AppState.glucoseColor(), Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 58, Gfx.FONT_NUMBER_MEDIUM, glucoseText, Gfx.TEXT_JUSTIFY_CENTER);
        if (AppState.glucose != null) { drawTrend(dc, cx + 52, cy - 34); }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 8, Gfx.FONT_XTINY, "mg/dL", Gfx.TEXT_JUSTIFY_CENTER);

        // Active Insulin (IOB)
        dc.setColor(Gfx.COLOR_BLUE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 20, Gfx.FONT_TINY, AppState.iob.format("%.2f") + " U IOB", Gfx.TEXT_JUSTIFY_CENTER);

        // Phone connection + hint
        dc.setColor(connected ? Gfx.COLOR_GREEN : Gfx.COLOR_ORANGE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 50, Gfx.FONT_XTINY,
            connected ? "iPhone connected" : "iPhone out of range", Gfx.TEXT_JUSTIFY_CENTER);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 72, Gfx.FONT_XTINY, "START or tap: Bolus", Gfx.TEXT_JUSTIFY_CENTER);
    }

    // Small flat trend triangle (placeholder until the phone sends CGM trend).
    private function drawTrend(dc as Gfx.Dc, x as Lang.Number, y as Lang.Number) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.fillPolygon([[x - 8, y - 5], [x + 8, y], [x - 8, y + 5]]);
    }
}
