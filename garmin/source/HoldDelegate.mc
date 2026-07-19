using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Confirm-screen input: forward numbered-target taps to the view, which enforces the 1→2→3
// order before delivering. Uses onSelectable because the venu3s delivers taps as high-level
// events, not raw coordinates. BACK (swipe right / bottom button) exits.
class HoldDelegate extends Ui.BehaviorDelegate {
    private var _view as HoldView;

    function initialize(view as HoldView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelectable(event as Ui.SelectableEvent) as Lang.Boolean {
        var inst = event.getInstance();
        if (inst instanceof PinButton) { _view.tapped((inst as PinButton).num); }
        return true;
    }
}
