using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Details-screen input (top of the stack): swipe down / back → back to the history screen.
class DetailsDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }
    function onPreviousPage() as Lang.Boolean { Ui.popView(Ui.SLIDE_DOWN); return true; }
}
