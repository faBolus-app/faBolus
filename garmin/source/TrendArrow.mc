using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Draws the CGM trend as a real arrow shape (the venu3s fonts can't render the Unicode arrows
// the iOS app uses, so we draw them). `token` is the direction from the phone:
// flat / up45 / up / upup / down45 / down / downdown. `size` is roughly the arrow half-length.
module TrendArrow {
    function head(dc as Gfx.Dc, tx, ty, dx, dy, size) as Void {
        var hl = size * 0.6, hw = size * 0.5;
        var bx = tx - dx * hl, by = ty - dy * hl;   // base center, behind the tip
        var px = -dy, py = dx;                        // perpendicular
        dc.fillPolygon([[tx, ty], [bx + px * hw, by + py * hw], [bx - px * hw, by - py * hw]]);
    }

    function draw(dc as Gfx.Dc, cx, cy, size, token as Lang.String?, color) as Void {
        if (token == null || token.equals("")) { return; }
        var dx = 1.0, dy = 0.0;   // flat → points right
        var dbl = false;
        if (token.equals("up")) { dx = 0.0; dy = -1.0; }
        else if (token.equals("upup")) { dx = 0.0; dy = -1.0; dbl = true; }
        else if (token.equals("up45")) { dx = 0.7; dy = -0.7; }
        else if (token.equals("down")) { dx = 0.0; dy = 1.0; }
        else if (token.equals("downdown")) { dx = 0.0; dy = 1.0; dbl = true; }
        else if (token.equals("down45")) { dx = 0.7; dy = 0.7; }

        dc.setColor(color, Gfx.COLOR_TRANSPARENT);
        var tipx = cx + dx * size, tipy = cy + dy * size;
        var tailx = cx - dx * size, taily = cy - dy * size;
        dc.setPenWidth(3);
        dc.drawLine(tailx, taily, tipx, tipy);
        head(dc, tipx, tipy, dx, dy, size);
        if (dbl) { head(dc, tipx - dx * size * 0.55, tipy - dy * size * 0.55, dx, dy, size); }
        dc.setPenWidth(1);
    }
}
