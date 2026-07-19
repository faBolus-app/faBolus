using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Bolus entry (touch-driven — the venu3s has no up/down buttons). Tap the mode chip to switch
// Units/Carbs, tap the on-screen − / + to adjust, tap Deliver to go to hold-to-confirm.
// Saline bench only.
class BolusEntryView extends Ui.View {
    function initialize() { View.initialize(); }

    // Shared geometry (fractions of screen), used by the delegate for hit-testing.
    static function chipRect(w, h) { return [w * 0.28, h * 0.06, w * 0.44, h * 0.16]; }       // x,y,w,h
    static function minusCenter(w, h) { return [w * 0.15, h * 0.42]; }
    static function plusCenter(w, h) { return [w * 0.85, h * 0.42]; }
    static function stepRadius(w) { return w * 0.12; }
    static function deliverRect(w, h) { return [w * 0.25, h * 0.72, w * 0.5, h * 0.16]; }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var vc = Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER;
        var isUnits = AppState.mode.equals("units");

        // Mode chip (tap to toggle).
        var cr = chipRect(w, h);
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cr[0], cr[1], cr[2], cr[3], 8);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cr[1] + cr[3] / 2, Gfx.FONT_TINY, isUnits ? "Units" : "Carbs", vc);

        // − / + tap circles.
        var mc = minusCenter(w, h), pc = plusCenter(w, h), r = stepRadius(w);
        dc.setColor(0x333333, Gfx.COLOR_TRANSPARENT); dc.fillCircle(mc[0], mc[1], r);
        dc.setColor(0x333333, Gfx.COLOR_TRANSPARENT); dc.fillCircle(pc[0], pc[1], r);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(mc[0], mc[1], Gfx.FONT_MEDIUM, "-", vc);
        dc.drawText(pc[0], pc[1], Gfx.FONT_MEDIUM, "+", vc);

        // Big value (vertically centered so its baseline can't collide with the line below).
        dc.setColor(0x8AB4FF, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.40, Gfx.FONT_NUMBER_MEDIUM, AppState.valueLabel(), vc);

        // In carbs mode, show the computed insulin — well below the value so they don't overlap.
        if (!isUnits) {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.58, Gfx.FONT_XTINY,
                        "~ " + AppState.computeUnits().format("%.2f") + " U", vc);
        }

        // Deliver button.
        var dr = deliverRect(w, h);
        dc.setColor(0x5C6BE6, Gfx.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(dr[0], dr[1], dr[2], dr[3], 10);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, dr[1] + dr[3] / 2, Gfx.FONT_SMALL, "Deliver", vc);
    }
}
