using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Bolus entry (saline, bench only). Tap the top (+) / bottom (−) of the screen to adjust, then
// press START to request on the iPhone (which runs the second confirm). Shows delivery status
// echoed back from the phone. Parity with the Apple Watch bolus screen.
class BolusView extends Ui.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;

        if (AppState.bolusStatus != null) {
            var status = AppState.bolusStatus as Lang.String;
            var color = Gfx.COLOR_BLUE;
            if (status.equals("delivered")) { color = Gfx.COLOR_GREEN; }
            else if (status.equals("failed") || status.equals("outOfRange")) { color = Gfx.COLOR_RED; }
            else if (status.equals("cancelled")) { color = Gfx.COLOR_ORANGE; }
            dc.setColor(color, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 40, Gfx.FONT_SMALL, status, Gfx.TEXT_JUSTIFY_CENTER);
            if (AppState.bolusMessage != null) {
                dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
                dc.drawText(cx, cy, Gfx.FONT_XTINY, AppState.bolusMessage, Gfx.TEXT_JUSTIFY_CENTER);
            }
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + 50, Gfx.FONT_XTINY, "BACK to exit", Gfx.TEXT_JUSTIFY_CENTER);
            return;
        }

        // + / - affordances (ASCII — device fonts lack the Unicode minus glyph)
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 92, Gfx.FONT_LARGE, "+", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, cy + 56, Gfx.FONT_LARGE, "-", Gfx.TEXT_JUSTIFY_CENTER);

        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 44, Gfx.FONT_XTINY, "Bolus (saline)", Gfx.TEXT_JUSTIFY_CENTER);
        dc.setColor(Gfx.COLOR_BLUE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 24, Gfx.FONT_NUMBER_MEDIUM, AppState.units.format("%.2f") + " U", Gfx.TEXT_JUSTIFY_CENTER);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 20, Gfx.FONT_XTINY, "START → request on iPhone", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, cy + 36, Gfx.FONT_XTINY, "saline · bench only", Gfx.TEXT_JUSTIFY_CENTER);
    }
}
