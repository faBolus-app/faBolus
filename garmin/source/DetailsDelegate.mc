using Toybox.WatchUi as Ui;
using Toybox.Lang;

// Details-screen input: swipe between screens in the user-configured order.
class DetailsDelegate extends Ui.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }
    function onNextPage() as Lang.Boolean { return Nav.goNext("details"); }
    function onPreviousPage() as Lang.Boolean { return Nav.goPrev("details"); }
}
