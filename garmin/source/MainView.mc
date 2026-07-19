using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Lang;

// Glance: current glucose + mg/dL, and a single Bolus button. Nothing else.
class MainView extends Ui.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        // Phone-connection dot (top).
        var connected = System.getDeviceSettings().phoneConnected;
        dc.setColor(connected ? Gfx.COLOR_GREEN : Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.fillCircle(cx, h * 0.16, 5);

        // Glucose (large, range-colored) + unit label.
        var g = (AppState.glucose == null) ? "--" : (AppState.glucose as Lang.Number).toString();
        dc.setColor(AppState.glucoseColor(), Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.30, Gfx.FONT_NUMBER_THAI_HOT, g, Gfx.TEXT_JUSTIFY_CENTER);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.52, Gfx.FONT_XTINY, "mg/dL", Gfx.TEXT_JUSTIFY_CENTER);

        // Bolus button (bottom).
        var bw = w * 0.5, bh = h * 0.16;
        var bx = cx - bw / 2, by = h * 0.66;
        dc.setColor(0x5C6BE6, Gfx.COLOR_TRANSPARENT);   // indigo
        dc.fillRoundedRectangle(bx, by, bw, bh, 10);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, by + bh / 2 - 14, Gfx.FONT_SMALL, "Bolus", Gfx.TEXT_JUSTIFY_CENTER);
    }
}
