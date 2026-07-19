using Toybox.Lang;
using Toybox.Graphics as Gfx;

// Shared app state for the ControlX2 Garmin remote — parity with the Apple Watch model:
// glucose + trend, Active Insulin (IOB), phone reachability, and the bolus flow. Updated from
// phone messages (schema: statusRead / bolusStatus).
module AppState {
    // HUD status
    var glucose as Lang.Number? = null;   // mg/dL
    var trend as Lang.String = "→";  // → default
    var iob as Lang.Float = 0.0;          // units (Active Insulin)
    var connection as Lang.String? = null;

    // Bolus flow
    var units as Lang.Float = 0.0;
    const MAX_UNITS = 10.0;
    const STEP = 0.05;
    var pendingRequestId as Lang.String? = null;
    var bolusStatus as Lang.String? = null;
    var bolusMessage as Lang.String? = null;

    function adjust(delta as Lang.Float) as Void {
        units += delta;
        if (units < 0.0) { units = 0.0; }
        if (units > MAX_UNITS) { units = MAX_UNITS; }
    }

    function resetBolus() as Void {
        units = 0.0; pendingRequestId = null; bolusStatus = null; bolusMessage = null;
    }

    // Route an inbound phone message (a decoded schema dictionary).
    function handle(data as Lang.Dictionary) as Void {
        var kind = data["kind"] as Lang.String?;
        if (kind == null) { return; }
        if (kind.equals("statusRead")) {
            var g = data["bgMgdl"];
            if (g instanceof Lang.Number || g instanceof Lang.Float || g instanceof Lang.Double) {
                glucose = g.toNumber();
            }
            var i = data["units"];
            if (i instanceof Lang.Number || i instanceof Lang.Float || i instanceof Lang.Double) {
                iob = i.toFloat();
            }
            connection = data["message"] as Lang.String?;
        } else if (kind.equals("bolusStatus")) {
            var rid = data["requestId"] as Lang.String?;
            if (pendingRequestId != null && rid != null && rid.equals(pendingRequestId)) {
                bolusStatus = data["status"] as Lang.String?;
                bolusMessage = data.hasKey("message") ? data["message"] as Lang.String? : null;
            }
        }
    }

    // Loop-style glucose color.
    function glucoseColor() as Gfx.ColorValue {
        if (glucose == null) { return Gfx.COLOR_LT_GRAY; }
        var g = glucose as Lang.Number;
        if (g < 70) { return Gfx.COLOR_RED; }
        if (g < 180) { return Gfx.COLOR_GREEN; }
        if (g < 250) { return Gfx.COLOR_YELLOW; }
        return Gfx.COLOR_ORANGE;
    }
}
