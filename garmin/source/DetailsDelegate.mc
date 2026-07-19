using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Details-screen input: swipe down (previous page) or back returns to the glance.
class DetailsDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }
    function onPreviousPage() as Lang.Boolean { Ui.popView(Ui.SLIDE_DOWN); return true; }
}
