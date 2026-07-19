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

        var vc = Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER;

        // Phone-connection dot (top).
        var connected = System.getDeviceSettings().phoneConnected;
        dc.setColor(connected ? Gfx.COLOR_GREEN : Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.fillCircle(cx, h * 0.15, 5);

        // Glucose (large, range-colored), vertically centered so the glyph baseline can't
        // collide with the unit label below it.
        var g = (AppState.glucose == null) ? "--" : (AppState.glucose as Lang.Number).toString();
        dc.setColor(AppState.glucoseColor(), Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.36, Gfx.FONT_NUMBER_HOT, g, vc);
        // Trend arrow (ASCII, from the phone) just right of the number.
        if (!AppState.trend.equals("")) {
            var gw = dc.getTextWidthInPixels(g, Gfx.FONT_NUMBER_HOT);
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx + gw / 2 + 12, h * 0.36, Gfx.FONT_TINY, AppState.trend,
                        Gfx.TEXT_JUSTIFY_LEFT | Gfx.TEXT_JUSTIFY_VCENTER);
        }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.55, Gfx.FONT_XTINY, "mg/dL", vc);

        // Bolus button (bottom), label vertically centered.
        var bw = w * 0.52, bh = h * 0.17;
        var bx = cx - bw / 2, by = h * 0.68;
        dc.setColor(0x5C6BE6, Gfx.COLOR_TRANSPARENT);   // indigo
        dc.fillRoundedRectangle(bx, by, bw, bh, 12);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, by + bh / 2, Gfx.FONT_SMALL, "Bolus", vc);
    }
}
