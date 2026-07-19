using Toybox.WatchUi as Ui;
using Toybox.Lang;

// History-screen input: swipe up → pump details, swipe down / back → glance.
class DexcomDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }
    function onNextPage() as Lang.Boolean {
        Ui.pushView(new DetailsView(), new DetailsDelegate(), Ui.SLIDE_UP);
        return true;
    }
    function onPreviousPage() as Lang.Boolean { Ui.popView(Ui.SLIDE_DOWN); return true; }
}
