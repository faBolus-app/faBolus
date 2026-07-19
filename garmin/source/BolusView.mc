using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Bolus entry: pick Units or Carbs (tap the mode chip), adjust with the top/bottom buttons,
// tap Deliver to go to the hold-to-confirm screen. Saline bench only.
class BolusEntryView extends Ui.View {
    function initialize() { View.initialize(); }

    // Touch zones (fractions of height) used by the delegate.
    static function modeZoneMaxY(h) { return h * 0.30; }
    static function deliverZoneMinY(h) { return h * 0.66; }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        // Mode chip (tap to toggle).
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - w * 0.22, h * 0.14, w * 0.44, h * 0.14, 8);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.16, Gfx.FONT_TINY,
                    AppState.mode.equals("units") ? "Units (tap)" : "Carbs (tap)", Gfx.TEXT_JUSTIFY_CENTER);

        // Big value.
        dc.setColor(0x8AB4FF, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.36, Gfx.FONT_NUMBER_MEDIUM, AppState.valueLabel(), Gfx.TEXT_JUSTIFY_CENTER);

        // In carbs mode, show the computed insulin.
        if (!AppState.mode.equals("units")) {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.55, Gfx.FONT_XTINY,
                        "~ " + AppState.computeUnits().format("%.2f") + " U", Gfx.TEXT_JUSTIFY_CENTER);
        }

        // Physical-button hints: ▲ near the top-right, ▼ near the bottom-right.
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.fillPolygon([[w * 0.92, h * 0.30], [w * 0.88, h * 0.35], [w * 0.96, h * 0.35]]);
        dc.fillPolygon([[w * 0.92, h * 0.70], [w * 0.88, h * 0.65], [w * 0.96, h * 0.65]]);

        // Deliver button.
        var bw = w * 0.5, bh = h * 0.16, bx = cx - bw / 2, by = h * 0.68;
        dc.setColor(0x5C6BE6, Gfx.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(bx, by, bw, bh, 10);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, by + bh / 2, Gfx.FONT_SMALL, "Deliver", Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
    }
}
