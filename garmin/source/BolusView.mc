using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Bolus entry (venu3s gestures): swipe up/down to change the value, tap to Deliver, hold the top
// button to switch Units/Carbs. On-screen chevrons hint the swipe; a tap anywhere = Deliver
// (the watch delivers taps as "select"). Saline bench only.
class BolusEntryView extends Ui.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var vc = Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER;
        var isUnits = AppState.mode.equals("units");

        // Mode label + hold hint.
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.16, Gfx.FONT_TINY, isUnits ? "Units" : "Carbs", vc);
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.25, Gfx.FONT_XTINY, "hold btn to switch", vc);

        // Up chevron (swipe-up hint).
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.fillPolygon([[cx, h * 0.31], [cx - 12, h * 0.35], [cx + 12, h * 0.35]]);

        // Big value.
        dc.setColor(0x8AB4FF, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.46, Gfx.FONT_NUMBER_MEDIUM, AppState.valueLabel(), vc);

        // Down chevron (swipe-down hint).
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.fillPolygon([[cx, h * 0.61], [cx - 12, h * 0.57], [cx + 12, h * 0.57]]);

        // Computed insulin (carbs mode).
        if (!isUnits) {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.68, Gfx.FONT_XTINY,
                        "~ " + AppState.computeUnits().format("%.2f") + " U", vc);
        }

        // Deliver hint (a tap anywhere delivers).
        dc.setColor(0x5C6BE6, Gfx.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - w * 0.28, h * 0.76, w * 0.56, h * 0.14, 10);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.83, Gfx.FONT_SMALL, "Tap = Deliver", vc);
    }
}
