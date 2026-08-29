import Testing
@testable import faBolus

/// `CustomizeListView.canDelete(currentCount:removingCount:allowEmpty:)`, the extracted delete-guard
/// arithmetic behind the "Shown" list's `.onDelete`. Pins the truth table:
/// the default floor (`allowEmpty == false`) still blocks a delete that would empty the list, while
/// `allowEmpty == true` (the Live Activity fields list only) permits reaching zero, including a
/// multi-row swipe-delete that removes everything at once.
struct CustomizeListViewGuardTests {

    /// Default floor: a delete that would leave zero items is BLOCKED (Details/Pills/Watch details).
    @Test func blockAtFloorWhenAllowEmptyIsFalse() {
        #expect(CustomizeListView.canDelete(currentCount: 1, removingCount: 1, allowEmpty: false) == false)
    }

    /// Default floor: a delete that leaves at least one item is ALLOWED.
    @Test func allowDownToOneWhenAllowEmptyIsFalse() {
        #expect(CustomizeListView.canDelete(currentCount: 2, removingCount: 1, allowEmpty: false) == true)
    }

    /// LA-only relax: deleting the single last remaining item IS allowed when allowEmpty is true.
    @Test func allowEmptySingleDeleteReachesZero() {
        #expect(CustomizeListView.canDelete(currentCount: 1, removingCount: 1, allowEmpty: true) == true)
    }

    /// LA-only relax: a multi-row swipe-delete that removes every remaining item at once is allowed.
    @Test func allowEmptyMultiDeleteReachesZero() {
        #expect(CustomizeListView.canDelete(currentCount: 7, removingCount: 7, allowEmpty: true) == true)
    }
}
