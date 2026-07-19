using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Confirm screen: tap the numbered targets 1 → 2 → 3 in order to deliver (like the t:slim
// unlock). Positions are scrambled so it's a deliberate sequence, not a single tap. A wrong tap
// resets to 1. This uses Selectable regions because the venu3s delivers taps only as high-level
// events (onSelectable), not raw coordinates. Once sent, shows delivery status.

// A numbered tap target. Invisible (drawn by the view); used only for hit-testing.
class PinButton extends Ui.Selectable {
    public var num as Lang.Number;
    public var ccx as Lang.Number;
    public var ccy as Lang.Number;
    public var rad as Lang.Number;

    function initialize(n as Lang.Number, cx as Lang.Number, cy as Lang.Number, r as Lang.Number) {
        num = n; ccx = cx; ccy = cy; rad = r;
        Selectable.initialize({
            :locX => cx - r, :locY => cy - r, :width => 2 * r, :height => 2 * r,
            :stateDefault => Gfx.COLOR_BLACK,
            :stateHighlighted => Gfx.COLOR_BLACK,
            :stateSelected => Gfx.COLOR_BLACK
        });
    }
}

class HoldView extends Ui.View {
    private var _btns as Lang.Array?;
    private var _progress as Lang.Number = 0;   // how many correct taps so far (0..3)

    function initialize() { View.initialize(); }

    function onLayout(dc as Gfx.Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight();
        var r = (w * 0.12).toNumber();
        // In order, left → right: 1, 2, 3.
        _btns = [
            new PinButton(1, (w * 0.26).toNumber(), (h * 0.50).toNumber(), r),
            new PinButton(2, (w * 0.50).toNumber(), (h * 0.50).toNumber(), r),
            new PinButton(3, (w * 0.74).toNumber(), (h * 0.50).toNumber(), r)
        ];
        setLayout(_btns);
    }

    function buttons() as Lang.Array? { return _btns; }

    // Called by the delegate when target `num` is tapped.
    function tapped(num as Lang.Number) as Void {
        if (AppState.status != null) { return; }
        if (num == _progress + 1) {
            _progress += 1;
            if (_progress >= 3) { deliver(); }
        } else {
            _progress = 0;   // wrong order — start over
        }
        // Reset selectable states so every target stays tappable.
        if (_btns != null) {
            for (var i = 0; i < _btns.size(); i += 1) { (_btns[i] as PinButton).setState(:stateDefault); }
        }
        Ui.requestUpdate();
    }

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();
        View.onUpdate(dc);   // draws the (invisible) selectable regions
        var w = dc.getWidth(), h = dc.getHeight(), cx = w / 2, cy = h / 2;
        var vc = Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER;

        // Delivery status takes over the screen once sent.
        if (AppState.status != null) {
            var s = AppState.status as Lang.String;
            var color = Gfx.COLOR_BLUE;
            if (s.equals("delivered")) { color = Gfx.COLOR_GREEN; }
            else if (s.equals("failed") || s.equals("outOfRange")) { color = Gfx.COLOR_RED; }
            dc.setColor(color, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy - 30, Gfx.FONT_MEDIUM, s, Gfx.TEXT_JUSTIFY_CENTER);
            if (AppState.message != null) {
                dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
                dc.drawText(cx, cy + 10, Gfx.FONT_XTINY, AppState.message, Gfx.TEXT_JUSTIFY_CENTER);
            }
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(cx, cy + 55, Gfx.FONT_XTINY, "BACK to exit", Gfx.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Header: units + instruction.
        dc.setColor(0x8AB4FF, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.12, Gfx.FONT_SMALL, AppState.deliverUnits.format("%.2f") + " U", vc);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.86, Gfx.FONT_XTINY, "Tap 1 - 2 - 3 to deliver", vc);
        dc.drawText(cx, h * 0.93, Gfx.FONT_XTINY, "saline · bench", vc);

        // Numbered targets — completed ones turn green.
        if (_btns != null) {
            for (var i = 0; i < _btns.size(); i += 1) {
                var b = _btns[i] as PinButton;
                var done = b.num <= _progress;
                dc.setColor(done ? Gfx.COLOR_GREEN : 0x333333, Gfx.COLOR_TRANSPARENT);
                dc.fillCircle(b.ccx, b.ccy, b.rad);
                dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
                dc.drawText(b.ccx, b.ccy, Gfx.FONT_NUMBER_MEDIUM, b.num.toString(), vc);
            }
        }
    }

    private function deliver() as Void {
        var reqId = RemoteComm.newRequestId();
        AppState.pendingRequestId = reqId;
        if (!RemoteComm.phoneReachable()) {
            AppState.status = "outOfRange"; AppState.message = "iPhone unreachable"; return;
        }
        AppState.status = "delivering";
        RemoteComm.send(RemoteComm.bolusRequest(AppState.deliverUnits, reqId));
    }
}
