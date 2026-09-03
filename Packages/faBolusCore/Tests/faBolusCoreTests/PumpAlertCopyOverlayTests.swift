import Testing
@testable import faBolusCore

/// Pins `PumpAlertCopyOverlay`'s namespace guard: the id-keyed overlay table is scoped to `.alert`-kind
/// notifications only, so a reminder/alarm/malfunction whose id collides with an alert-overlay entry
/// (e.g. a hardware malfunction at bit 50, the same id as "Control-IQ high") must never borrow that
/// alert's copy.
struct PumpAlertCopyOverlayTests {

    /// The `.alert` happy path is unchanged: an alert id with an overlay entry and no decoded detail
    /// still gets the overlay's clean copy.
    @Test func alertKindWithOverlayEntryGetsOverlayCopy() {
        let copy = PumpAlertCopyOverlay.resolve(
            kind: .alert, id: 50, decodedTitle: "Alert 50", decodedDetail: nil)
        #expect(copy.title == "Control-IQ high")
    }

    /// A malfunction (alarm-kind) at the same bit id as an alert-overlay entry, decoded with an empty
    /// name table (detail nil), must NOT receive the alert's glucose-advisory copy.
    @Test func nonAlertKindWithCollidingIdBypassesTheOverlay() {
        let copy = PumpAlertCopyOverlay.resolve(
            kind: .alarm, id: 50, decodedTitle: "Alarm 50", decodedDetail: nil)
        #expect(copy.title == "Alarm 50")
        #expect(copy.title != "Control-IQ high")
    }

    /// A reminder at the same colliding id is likewise unaffected.
    @Test func reminderKindWithCollidingIdBypassesTheOverlay() {
        let copy = PumpAlertCopyOverlay.resolve(
            kind: .reminder, id: 50, decodedTitle: "Reminder 50", decodedDetail: nil)
        #expect(copy.title == "Reminder 50")
    }

    /// A decoded name the protocol layer already supplies is never overridden, alert kind or not.
    @Test func alertKindWithADecodedDetailIsNeverOverridden() {
        let copy = PumpAlertCopyOverlay.resolve(
            kind: .alert, id: 50, decodedTitle: "Some other name", decodedDetail: "already named")
        #expect(copy.title == "Some other name")
        #expect(copy.detail == "already named")
    }
}
