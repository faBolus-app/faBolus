using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Dexcom-style history screen (swipe up from the glance): "Nm ago", the current reading + trend,
// and a 3-hour glucose plot with 100/200/300/400 gridlines. Data comes from the phone
// (AppState.history, ~5-min spacing). A reading older than 6 min shows as "--".
class DexcomView extends Ui.View {
    function initialize() { View.initialize(); }

    private const VMIN = 40.0;
    private const VMAX = 300.0;

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var vc = Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER;
        var stale = AppState.glucoseStale();

        // "N M AGO"
        var age = AppState.ageMinutes();
        var ageStr = (age < 0) ? "--" : (age == 0 ? "NOW" : (age.toString() + "M AGO"));
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.11, Gfx.FONT_XTINY, ageStr, vc);

        // Current reading + trend arrow.
        var g = AppState.displayGlucose();
        dc.setColor(stale ? Gfx.COLOR_LT_GRAY : AppState.glucoseColor(), Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.22, Gfx.FONT_NUMBER_MEDIUM, g, vc);
        if (!stale && !AppState.trend.equals("")) {
            var gw = dc.getTextWidthInPixels(g, Gfx.FONT_NUMBER_MEDIUM);
            TrendArrow.draw(dc, cx + gw / 2 + 20, h * 0.22, 11, AppState.trend, AppState.glucoseColor());
        }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.32, Gfx.FONT_XTINY, "mg/dL", vc);

        // Plot area.
        var plotL = w * 0.16, plotR = w * 0.84;
        var plotT = h * 0.42, plotB = h * 0.82;
        var plotH = plotB - plotT;

        // Gridlines with right-edge labels (y-axis max = VMAX).
        var lines = [100, 200, 300];
        for (var i = 0; i < lines.size(); i += 1) {
            var v = lines[i];
            var y = plotB - ((v - VMIN) / (VMAX - VMIN)) * plotH;
            dc.setColor(0x333333, Gfx.COLOR_TRANSPARENT);
            dc.setPenWidth(1);
            dc.drawLine(plotL, y, plotR, y);
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(plotR + w * 0.02, y, Gfx.FONT_XTINY, v.toString(), Gfx.TEXT_JUSTIFY_LEFT | Gfx.TEXT_JUSTIFY_VCENTER);
        }

        // Data dots (Dexcom-style), oldest → newest across the width. Window to the selected
        // hours (~12 points/hour at 5-min spacing); newest points are at the end of the array.
        var full = AppState.history;
        var total = full.size();
        var want = AppState.plotHours * 12;
        var start = (total > want) ? (total - want) : 0;
        var n = total - start;
        if (n >= 1) {
            var span = (n > 1) ? (plotR - plotL) / (n - 1) : 0;
            for (var k = 0; k < n; k += 1) {
                var val = full[start + k];
                if (!(val instanceof Lang.Number) && !(val instanceof Lang.Float)) { continue; }
                var vv = val.toFloat();
                if (vv < VMIN) { vv = VMIN; }
                if (vv > VMAX) { vv = VMAX; }
                var px = plotL + span * k;
                var py = plotB - ((vv - VMIN) / (VMAX - VMIN)) * plotH;
                dc.setColor(AppState.rangeColor(val.toNumber()), Gfx.COLOR_TRANSPARENT);
                dc.fillCircle(px, py, 2);
            }
        } else {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, (plotT + plotB) / 2, Gfx.FONT_XTINY, "no history", vc);
        }

        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.90, Gfx.FONT_XTINY, AppState.plotHours.toString() + " Hours (tap)", vc);
    }
}
