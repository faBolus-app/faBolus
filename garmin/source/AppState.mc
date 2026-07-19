using Toybox.Lang;
using Toybox.Graphics as Gfx;
using Toybox.Math;
using Toybox.Application.Storage;

// Shared app state for the ControlX2 Garmin remote. Glance data comes from the phone
// (statusRead reply); carbs→units is computed locally from the pump's calculator settings so
// the hold-to-deliver screen can show the exact units.
module AppState {
    // HUD data (from phone)
    var glucose as Lang.Number? = null;   // mg/dL
    var trend as Lang.String = "";
    var iob as Lang.Float = 0.0;          // units
    var carbRatio as Lang.Float = 0.0;    // g/u
    var isf as Lang.Number = 0;           // mg/dL per unit
    var targetBg as Lang.Number = 0;      // mg/dL
    var maxUnits as Lang.Float = 25.0;

    // Bolus entry
    var mode as Lang.String = "units";    // "units" | "carbs"
    var unitsValue as Lang.Float = 0.0;
    var carbsValue as Lang.Number = 0;
    const STEP_U = 0.05;
    const STEP_C = 1;
    const MAX_CARBS = 200;

    // Delivery
    var deliverUnits as Lang.Float = 0.0; // captured when entering the hold screen
    var holdProgress as Lang.Float = 0.0; // 0..1 for the hold-to-deliver ring
    var pendingRequestId as Lang.String? = null;
    var status as Lang.String? = null;    // delivering/delivered/failed/...
    var message as Lang.String? = null;

    function reset() as Void {
        mode = "units"; unitsValue = 0.0; carbsValue = 0;
        pendingRequestId = null; status = null; message = null;
    }

    // Seed glucose/trend from the persisted complication value so the glance shows the last-known
    // reading immediately on open, instead of "--" while the first phone reply is in flight.
    function loadPersisted() as Void {
        var g = Storage.getValue(BgComplication.KEY_BG);
        if (g != null && isNum(g)) { glucose = g.toNumber(); }
        var t = Storage.getValue(BgComplication.KEY_TREND);
        if (t != null && t instanceof Lang.String) { trend = t; }
    }

    function toggleMode() as Void {
        mode = mode.equals("units") ? "carbs" : "units";
    }

    // dir = +1 / -1
    function adjust(dir as Lang.Number) as Void {
        if (mode.equals("units")) {
            unitsValue += dir * STEP_U;
            if (unitsValue < 0.0) { unitsValue = 0.0; }
            if (unitsValue > maxUnits) { unitsValue = maxUnits; }
        } else {
            carbsValue += dir * STEP_C;
            if (carbsValue < 0) { carbsValue = 0; }
            if (carbsValue > MAX_CARBS) { carbsValue = MAX_CARBS; }
        }
    }

    // The units that will actually be delivered (rounded to 0.05, clamped to the pump max).
    function computeUnits() as Lang.Float {
        var total;
        if (mode.equals("units")) {
            total = unitsValue;
        } else {
            var food = (carbRatio > 0.0) ? (carbsValue.toFloat() / carbRatio) : 0.0;
            var correction = 0.0;
            if (isf > 0 && glucose != null) {
                correction = (glucose - targetBg).toFloat() / isf.toFloat() - iob;
                if (correction < 0.0) { correction = 0.0; }
            }
            total = food + correction;
        }
        total = Math.round(total * 20.0) / 20.0;   // 0.05 u steps
        if (total < 0.0) { total = 0.0; }
        if (total > maxUnits) { total = maxUnits; }
        return total;
    }

    function valueLabel() as Lang.String {
        if (mode.equals("units")) { return unitsValue.format("%.2f") + " U"; }
        return carbsValue.toString() + " g";
    }

    // Route an inbound phone message.
    function handle(data as Lang.Dictionary) as Void {
        var kind = data["kind"] as Lang.String?;
        if (kind == null) { return; }
        if (kind.equals("statusRead")) {
            glucose = numOrNull(data["bgMgdl"]);
            var t = data["trend"] as Lang.String?; if (t != null) { trend = t; }
            var i = flt(data["units"]); if (i != null) { iob = i; }
            var cr = flt(data["carbRatio"]); if (cr != null) { carbRatio = cr; }
            var isfv = numOrNull(data["isf"]); if (isfv != null) { isf = isfv; }
            var tb = numOrNull(data["targetBg"]); if (tb != null) { targetBg = tb; }
            var mx = flt(data["maxBolusUnits"]); if (mx != null) { maxUnits = mx; }
        } else if (kind.equals("bolusStatus")) {
            var rid = data["requestId"] as Lang.String?;
            if (pendingRequestId != null && rid != null && rid.equals(pendingRequestId)) {
                status = data["status"] as Lang.String?;
                message = data.hasKey("message") ? data["message"] as Lang.String? : null;
            }
        }
    }

    function isNum(v) as Lang.Boolean {
        return v instanceof Lang.Number || v instanceof Lang.Float || v instanceof Lang.Double;
    }
    function numOrNull(v) as Lang.Number? { return isNum(v) ? v.toNumber() : null; }
    function flt(v) as Lang.Float? { return isNum(v) ? v.toFloat() : null; }

    function glucoseColor() as Gfx.ColorValue {
        if (glucose == null) { return Gfx.COLOR_LT_GRAY; }
        var g = glucose as Lang.Number;
        if (g < 70) { return Gfx.COLOR_RED; }
        if (g < 180) { return Gfx.COLOR_GREEN; }
        if (g < 250) { return Gfx.COLOR_YELLOW; }
        return Gfx.COLOR_ORANGE;
    }
}
