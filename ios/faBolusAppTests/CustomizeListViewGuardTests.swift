import Testing

@testable import faBolus

/// Ported from the old app: `CustomizeListView.canDelete`, the floor behind the "Shown" lists' swipe to
/// hide. A delete that would leave zero items is refused; anything that leaves one is allowed. On the main
/// actor, where the view's static method is isolated.
@MainActor
struct CustomizeListViewGuardTests {
    @Test func blockAtFloorWhenDeletingTheLastItem() {
        #expect(CustomizeListView.canDelete(currentCount: 1, removingCount: 1) == false)
    }

    @Test func allowDownToOneItem() {
        #expect(CustomizeListView.canDelete(currentCount: 2, removingCount: 1) == true)
    }

    @Test func allowMultiDeleteDownToOneItem() {
        #expect(CustomizeListView.canDelete(currentCount: 7, removingCount: 6) == true)
    }

    @Test func blockMultiDeleteThatWouldReachZero() {
        #expect(CustomizeListView.canDelete(currentCount: 7, removingCount: 7) == false)
    }

    /// Adding an item already shown leaves one of it: the fields screen added "Last bolus" on every tap.
    @Test func addingAnItemTwiceKeepsOne() {
        #expect(CustomizeListView.adding("b", to: ["a"]) == ["a", "b"])
        #expect(CustomizeListView.adding("b", to: ["a", "b"]) == ["a", "b"])
    }

    /// A list saved with repeats shows each item once, in order.
    @Test func aListWithRepeatsShowsEachOnce() {
        #expect(CustomizeListView.unique(["a", "b", "b", "a", "c", "b"]) == ["a", "b", "c"])
    }
}
