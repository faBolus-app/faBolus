using Toybox.Complications;
using Toybox.Application.Storage;
using Toybox.Lang;

// Publishes the current blood glucose to complication index 0 (see
// resources/complications/complications.xml). The value is a String like "124 ^" so Face It /
// CIQ faces render it verbatim; the trend is stored as a direction token (from the phone) and
// converted to a Latin-safe arrow here, since complication text can't rely on Unicode glyphs.
module BgComplication {
    const COMP_ID = 0;
    const KEY_BG = "bg";
    const KEY_TREND = "trend";   // direction token: flat/up/down/upup/downdown/up45/down45

    // Latin-safe arrow for the published complication string.
    function asciiArrow(token as Lang.String?) as Lang.String {
        if (token == null) { return ""; }
        if (token.equals("up")) { return "^"; }
        if (token.equals("upup")) { return "^^"; }
        if (token.equals("up45")) { return "/"; }
        if (token.equals("down")) { return "v"; }
        if (token.equals("downdown")) { return "vv"; }
        if (token.equals("down45")) { return "\\"; }
        if (token.equals("flat")) { return "->"; }
        return "";
    }

    function remember(bg as Lang.Number?, token as Lang.String) as Void {
        if (bg != null) { Storage.setValue(KEY_BG, bg); }
        Storage.setValue(KEY_TREND, token);
    }

    // Publish the reading. Falls back to the persisted value/token when bg is null.
    function publish(bg as Lang.Number?, token as Lang.String?) as Void {
        if (!(Toybox has :Complications)) { return; }
        var value = bg;
        var tok = token;
        if (value == null) {
            value = Storage.getValue(KEY_BG) as Lang.Number?;
            tok = Storage.getValue(KEY_TREND) as Lang.String?;
        }
        if (value == null) { return; }

        var label = value.toString();
        var arrow = asciiArrow(tok);
        var text = arrow.equals("") ? label : (label + " " + arrow);
        try {
            Complications.updateComplication(COMP_ID, {
                :value => text,
                :shortLabel => label,
                :ranges => [ value, 70, 180, 250 ]
            });
        } catch (e) {
            // Older firmware / complication not registered yet — ignore.
        }
    }

    function publishFromState() as Void {
        remember(AppState.glucose, AppState.trend);
        publish(AppState.glucose, AppState.trend);
    }
}
