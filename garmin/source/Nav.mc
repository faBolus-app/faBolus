using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Screen carousel for the ControlX2 remote. The swipe order and the first screen are configurable
// (from phone settings, held in AppState.screenOrder / AppState.defaultScreen). Instead of a fixed
// push/pop stack, screens are swapped with switchToView() so any order works and the default
// screen is simply the initial view. The bolus screen is a modal push on top (not in this order),
// so popView() from bolus returns to whatever screen launched it.
module Nav {
    // [View, Delegate] for a screen id. Falls back to the glance for an unknown id.
    function viewFor(id as Lang.String) as Lang.Array {
        if (id.equals("alerts"))  { return [new AlertsListView(), new AlertsListDelegate()]; }
        if (id.equals("history")) { return [new DexcomView(), new DexcomDelegate()]; }
        if (id.equals("details")) { return [new DetailsView(), new DetailsDelegate()]; }
        return [new MainView(), new MainDelegate()];
    }

    // The first screen shown at launch.
    function initialView() as Lang.Array {
        return viewFor(AppState.defaultScreen);
    }

    function indexOf(id as Lang.String) as Lang.Number {
        var order = AppState.screenOrder;
        for (var i = 0; i < order.size(); i += 1) {
            if ((order[i] as Lang.String).equals(id)) { return i; }
        }
        return -1;
    }

    // Swipe up → next screen in the order (clamped at the last screen).
    function goNext(currentId as Lang.String) as Lang.Boolean {
        var i = indexOf(currentId);
        var order = AppState.screenOrder;
        if (i < 0 || i + 1 >= order.size()) { return true; }   // at the end: swallow, no move
        var vd = viewFor(order[i + 1] as Lang.String);
        Ui.switchToView(vd[0], vd[1], Ui.SLIDE_UP);
        return true;
    }

    // Swipe down → previous screen in the order (clamped at the first screen).
    function goPrev(currentId as Lang.String) as Lang.Boolean {
        var i = indexOf(currentId);
        if (i <= 0) { return true; }                            // at the start: swallow, no move
        var vd = viewFor(AppState.screenOrder[i - 1] as Lang.String);
        Ui.switchToView(vd[0], vd[1], Ui.SLIDE_DOWN);
        return true;
    }
}
