using Toybox.WatchUi as Ui;
using Toybox.Lang;

// History-screen input: tap cycles the window (3 → 6 → 12 h); swipe between screens in the
// user-configured order.
class DexcomDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }
    private function cycle() as Lang.Boolean { AppState.cyclePlotHours(); Ui.requestUpdate(); return true; }
    function onTap(evt as Ui.ClickEvent) as Lang.Boolean { return cycle(); }
    function onSelect() as Lang.Boolean { return cycle(); }   // fallback if taps arrive as select
    function onNextPage() as Lang.Boolean { return Nav.goNext("history"); }
    function onPreviousPage() as Lang.Boolean { return Nav.goPrev("history"); }
}
