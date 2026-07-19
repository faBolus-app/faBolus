using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Bolus entry (touch-driven — the venu3s has no up/down buttons). Layout keeps every tap target
// away from the screen edge: the watch treats touches within ~81px of the edge as swipe gestures
// (back/scroll), so edge buttons never register as taps. Tap zones therefore span big bands and
// their hint graphics sit toward the center.
//   • top band  → toggle Units/Carbs
//   • middle    → left half is −, right half is +
//   • bottom    → Deliver
// Saline bench only.
class BolusEntryView extends Ui.View {
    function initialize() { View.initialize(); }

    // Tap-zone boundaries (fractions of height), shared with the delegate.
    static function topBandMaxY(h) { return h * 0.34; }      // <= toggle mode
    static function deliverBandMinY(h) { return h * 0.66; }  // >= deliver
    // (middle band between them: left = −, right = +)

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var vc = Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER;
        var isUnits = AppState.mode.equals("units");

        // Mode chip (tap the top band to toggle) — centered, clear of the top edge.
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - w * 0.22, h * 0.18, w * 0.44, h * 0.13, 8);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.245, Gfx.FONT_TINY, isUnits ? "Units (tap)" : "Carbs (tap)", vc);

        // − / + hints (drawn toward center so they sit in the tappable region).
        dc.setColor(0x333333, Gfx.COLOR_TRANSPARENT);
        dc.fillCircle(w * 0.20, h * 0.50, w * 0.10);
        dc.fillCircle(w * 0.80, h * 0.50, w * 0.10);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w * 0.20, h * 0.50, Gfx.FONT_MEDIUM, "-", vc);
        dc.drawText(w * 0.80, h * 0.50, Gfx.FONT_MEDIUM, "+", vc);

        // Big value in the center.
        dc.setColor(0x8AB4FF, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.44, Gfx.FONT_NUMBER_MEDIUM, AppState.valueLabel(), vc);

        // Computed insulin (carbs mode) — below the value, above the deliver band.
        if (!isUnits) {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.58, Gfx.FONT_XTINY,
                        "~ " + AppState.computeUnits().format("%.2f") + " U", vc);
        }

        // Deliver button (bottom band), centered and clear of the bottom edge.
        dc.setColor(0x5C6BE6, Gfx.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - w * 0.25, h * 0.70, w * 0.5, h * 0.15, 10);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.775, Gfx.FONT_SMALL, "Deliver", vc);
    }
}
