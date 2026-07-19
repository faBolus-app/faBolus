using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Secondary screen (swipe up from the glance): all the other relevant pump data from the phone.
// One metric per row, centered, generously spaced so nothing overlaps. "--" when unknown.
class DetailsView extends Ui.View {
    function initialize() { View.initialize(); }

    private function f2(v as Lang.Float) as Lang.String {
        return v < 0.0 ? "--" : v.format("%.2f");
    }
    private function n0(v as Lang.Number) as Lang.String {
        return v < 0 ? "--" : v.toString();
    }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2;
        var vc = Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER;

        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.08, Gfx.FONT_XTINY,
                    AppState.connection.equals("") ? "Pump status" : AppState.connection, vc);

        // Rows in the central band (0.20..0.84) so the round edges never clip the text.
        var alertCount = AppState.alerts.size();
        var rows = [
            "Active Insulin: " + f2(AppState.iob) + " U",
            "Reservoir: " + f2(AppState.reservoir) + " U",
            "Battery: " + n0(AppState.battery) + "%",
            "Carb ratio: " + f2(AppState.carbRatio) + " g/U",
            "ISF: " + n0(AppState.isf) + " mg/dL/U",
            "Target: " + n0(AppState.targetBg) + " mg/dL",
            "Last bolus: " + f2(AppState.lastBolus) + " U",
            (alertCount > 0 ? ("Alerts: " + alertCount.toString() + " (swipe up)") : "No alerts")
        ];
        var top = 0.19, bottom = 0.85;
        var step = (bottom - top) / (rows.size() - 1);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        for (var i = 0; i < rows.size(); i += 1) {
            dc.drawText(cx, h * (top + step * i), Gfx.FONT_XTINY, rows[i], vc);
        }
    }
}
