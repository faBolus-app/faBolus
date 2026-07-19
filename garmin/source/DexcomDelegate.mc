using Toybox.WatchUi as Ui;
using Toybox.Lang;

// History-screen input: tap cycles the window (3 → 6 → 12 → 24 → 3 h); swipe up → pump details,
// swipe down / back → glance.
class DexcomDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }
    private function cycle() as Lang.Boolean { AppState.cyclePlotHours(); Ui.requestUpdate(); return true; }
    function onTap(evt as Ui.ClickEvent) as Lang.Boolean { return cycle(); }
    function onSelect() as Lang.Boolean { return cycle(); }   // fallback if taps arrive as select
    function onNextPage() as Lang.Boolean {
        Ui.pushView(new DetailsView(), new DetailsDelegate(), Ui.SLIDE_UP);
        return true;
    }
    function onPreviousPage() as Lang.Boolean { Ui.popView(Ui.SLIDE_DOWN); return true; }
}
