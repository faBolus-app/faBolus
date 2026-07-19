using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Details-screen input: swipe up → alerts list; swipe down / back → back to the history screen.
class DetailsDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }
    function onNextPage() as Lang.Boolean {
        Ui.pushView(new AlertsListView(), new AlertsListDelegate(), Ui.SLIDE_UP);
        return true;
    }
    function onPreviousPage() as Lang.Boolean { Ui.popView(Ui.SLIDE_DOWN); return true; }
}
