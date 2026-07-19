using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;

// Shared UI state for the bolus flow.
module BolusState {
    var units = 0.0;
    const MAX_UNITS = 10.0;
    const STEP = 0.05;
    var pendingRequestId = null;
    var status = null;      // "awaitingConfirm" | "delivering" | "delivered" | "failed" | ...
    var message = null;

    function adjust(delta) {
        units += delta;
        if (units < 0.0) { units = 0.0; }
        if (units > MAX_UNITS) { units = MAX_UNITS; }
    }

    // Handle a status echo from the phone.
    function handle(data) {
        if (data["kind"].equals("bolusStatus") && data["requestId"].equals(pendingRequestId)) {
            status = data["status"];
            message = data.hasKey("message") ? data["message"] : null;
        }
    }
}

// Loop-style units picker + confirm. UP/DOWN adjust; START requests on the phone.
class BolusView extends Ui.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc) {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;

        if (BolusState.status != null) {
            dc.drawText(cx, cy - 20, Gfx.FONT_MEDIUM, BolusState.status, Gfx.TEXT_JUSTIFY_CENTER);
            if (BolusState.message != null) {
                dc.drawText(cx, cy + 20, Gfx.FONT_SMALL, BolusState.message, Gfx.TEXT_JUSTIFY_CENTER);
            }
        } else {
            dc.drawText(cx, cy - 40, Gfx.FONT_SMALL, "Bolus (saline)", Gfx.TEXT_JUSTIFY_CENTER);
            dc.setColor(Gfx.COLOR_BLUE, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 10, Gfx.FONT_NUMBER_MEDIUM,
                        BolusState.units.format("%.2f") + " U", Gfx.TEXT_JUSTIFY_CENTER);
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + 40, Gfx.FONT_XTINY, "UP/DOWN set · START send", Gfx.TEXT_JUSTIFY_CENTER);
        }
    }
}
