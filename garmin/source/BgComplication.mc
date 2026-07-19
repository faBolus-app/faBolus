using Toybox.Complications;
using Toybox.Application.Storage;
using Toybox.Time;
using Toybox.Lang;

// Publishes the current blood glucose to complication index 0 (see
// resources/complications/complications.xml). The value is a String like "124 ^" so Face It /
// CIQ faces render it verbatim; the trend is stored as a direction token (from the phone) and
// converted to a Latin-safe arrow here, since complication text can't rely on Unicode glyphs.
module BgComplication {
    const COMP_ID = 0;
    const KEY_BG = "bg";
    const KEY_TREND = "trend";   // direction token: flat/up/down/upup/downdown/up45/down45
    const KEY_EPOCH = "bgEpoch"; // unix sec the BG was taken (for 6-min staleness)

    // Real Unicode trend arrow. Published inside the VALUE string (not the unit): the face's
    // value font has arrow glyphs (Dexcom's complication uses this), while the unit font doesn't.
    function arrowFor(token as Lang.String?) as Lang.String {
        if (token == null) { return ""; }
        if (token.equals("up")) { return "↑"; }
        if (token.equals("upup")) { return "⇈"; }
        if (token.equals("up45")) { return "↗"; }
        if (token.equals("down")) { return "↓"; }
        if (token.equals("downdown")) { return "⇊"; }
        if (token.equals("down45")) { return "↘"; }
        if (token.equals("flat")) { return "→"; }
        return "";
    }

    function remember(bg as Lang.Number?, token as Lang.String, epoch as Lang.Number) as Void {
        if (bg != null) { Storage.setValue(KEY_BG, bg); }
        Storage.setValue(KEY_TREND, token);
        if (epoch > 0) { Storage.setValue(KEY_EPOCH, epoch); }
    }

    // Publish the reading. Falls back to the persisted value/token/epoch when bg is null. A
    // reading older than 6 minutes is shown as "--" so a stale value is never displayed.
    function publish(bg as Lang.Number?, token as Lang.String?, epoch as Lang.Number) as Void {
        if (!(Toybox has :Complications)) { return; }
        var value = bg;
        var tok = token;
        var ep = epoch;
        if (value == null) {
            value = Storage.getValue(KEY_BG) as Lang.Number?;
            tok = Storage.getValue(KEY_TREND) as Lang.String?;
            var se = Storage.getValue(KEY_EPOCH); ep = (se == null) ? 0 : se;
        }
        if (value == null) { return; }

        var stale = (ep <= 0) || ((Time.now().value() - ep) > 360);
        var arrow = stale ? "" : arrowFor(tok);
        // Dexcom style: value + trend arrow as a single STRING value (the face's value font
        // renders the arrow), no unit/ranges. Putting the arrow in :unit made updateComplication
        // reject the call, freezing the value.
        var text = stale ? "--" : (value.toString() + arrow);
        try {
            Complications.updateComplication(COMP_ID, {
                :value => text,
                :shortLabel => text
            });
        } catch (e) {
            // Older firmware / complication not registered yet — ignore.
        }
    }

    function publishFromState() as Void {
        remember(AppState.glucose, AppState.trend, AppState.readingEpoch);
        publish(AppState.glucose, AppState.trend, AppState.readingEpoch);
    }
}
