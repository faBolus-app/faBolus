using Toybox.Complications;
using Toybox.Application.Storage;
using Toybox.Lang;

// Publishes the current blood glucose (with a Latin-safe trend arrow baked into the value
// string) to complication index 0, declared in resources/complications/complications.xml.
// Because it's a `public` complication, Garmin "Face It" faces and CIQ watch faces that
// subscribe can show it on the watch face without opening this app.
//
// The value is published as a String (e.g. "124 ^") so it renders verbatim; the numeric BG is
// also sent via `ranges` so a subscribing face can range-color it against the glucose bands.
module BgComplication {
    const COMP_ID = 0;
    const KEY_BG = "bg";
    const KEY_TREND = "trend";

    // Persist the last reading so we can re-publish immediately on launch / background wake,
    // keeping the face from going blank between updates.
    function remember(bg as Lang.Number?, trend as Lang.String) as Void {
        if (bg != null) { Storage.setValue(KEY_BG, bg); }
        Storage.setValue(KEY_TREND, trend);
    }

    // Publish the given reading. Falls back to the persisted value when bg is null.
    function publish(bg as Lang.Number?, trend as Lang.String) as Void {
        if (!(Toybox has :Complications)) { return; }
        var value = bg;
        var tr = trend;
        if (value == null) {
            value = Storage.getValue(KEY_BG) as Lang.Number?;
            var st = Storage.getValue(KEY_TREND) as Lang.String?;
            if (st != null) { tr = st; }
        }
        if (value == null) { return; }

        var label = value.toString();
        var text = (tr != null && !tr.equals("")) ? (label + " " + tr) : label;
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

    // Publish from whatever is currently in AppState (called after a phone status reply).
    function publishFromState() as Void {
        remember(AppState.glucose, AppState.trend);
        publish(AppState.glucose, AppState.trend);
    }
}
