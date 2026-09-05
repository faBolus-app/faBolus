import Testing
@testable import faBolus

/// `CustomizeListView.canDelete(currentCount:removingCount:)`, the extracted delete-guard
/// arithmetic behind the "Shown" list's `.onDelete`. Pins the truth table: a delete that would
/// leave zero items is always blocked (Details/Pills/Watch details all share this one floor).
struct CustomizeListViewGuardTests {

    /// A delete that would leave zero items is BLOCKED.
    @Test func blockAtFloorWhenDeletingTheLastItem() {
        #expect(CustomizeListView.canDelete(currentCount: 1, removingCount: 1) == false)
    }

    /// A delete that leaves at least one item is ALLOWED.
    @Test func allowDownToOneItem() {
        #expect(CustomizeListView.canDelete(currentCount: 2, removingCount: 1) == true)
    }

    /// A multi-row swipe-delete that leaves at least one item is ALLOWED.
    @Test func allowMultiDeleteDownToOneItem() {
        #expect(CustomizeListView.canDelete(currentCount: 7, removingCount: 6) == true)
    }

    /// A multi-row swipe-delete that would remove every remaining item at once is BLOCKED.
    @Test func blockMultiDeleteThatWouldReachZero() {
        #expect(CustomizeListView.canDelete(currentCount: 7, removingCount: 7) == false)
    }
}
