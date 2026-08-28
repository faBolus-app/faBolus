import Testing
@testable import faBolusCore

/// Pins that pump-alert ids 50/51 present clean Control-IQ High/Low copy without adding a new faBolus
/// advisory or an imperative dosing verb. Identity is the pump bitmap id, not PumpAlertKind.
@Suite struct CiqAlertCopyTests {

    /// Control-IQ Low (#51)'s Tandem-sourced copy is already clean in the decode layer
    /// (`TandemKit/Sources/TandemMessages/Responses/Notifications.swift`
    /// `AlertStatusResponse.names[51]`) — reproduced here as a FIXTURE (not re-decoded; faBolusCore
    /// doesn't depend on TandemKit) purely so both known Control-IQ alerts are held to the SAME
    /// neutral-copy audit this suite applies to the id-50 overlay.
    private static let ciqLowTitle = "Control-IQ low"
    private static let ciqLowDetail = "Control-IQ has reduced basal insulin due to a low or predicted low."

    @Test func controlIQHighOverlayFiresOnlyWhenTheDecodedCopyIsGeneric() {
        // Generic fallback: decodedDetail == nil mirrors TandemKit's NotificationBitmap.decode leaving
        // `detail` nil for an unnamed bit (id 50 has no entry in AlertStatusResponse.names today).
        let resolved = PumpAlertCopyOverlay.resolve(id: 50, decodedTitle: "Alert 50", decodedDetail: nil)
        #expect(resolved.title == "Control-IQ high")
        #expect(!resolved.detail.isEmpty)
    }

    @Test func overlayNeverOverridesARealDecodedName() {
        // If the decode layer ever does supply a real name for id 50, the overlay must not clobber it —
        // and this is exactly how id 51 (already named) is left untouched today.
        let resolved = PumpAlertCopyOverlay.resolve(
            id: 50, decodedTitle: "Some real Tandem name", decodedDetail: "Some real Tandem detail.")
        #expect(resolved.title == "Some real Tandem name")
        #expect(resolved.detail == "Some real Tandem detail.")
    }

    @Test func controlIQAlertsFiftyAndFiftyOneAreDistinctIdsWithNonEmptyCleanCopy() {
        let high = PumpAlertCopyOverlay.resolve(id: 50, decodedTitle: "Alert 50", decodedDetail: nil)
        let low = (title: Self.ciqLowTitle, detail: Self.ciqLowDetail)
        #expect(high.title != low.title)
        #expect(!high.title.isEmpty && !high.detail.isEmpty)
        #expect(!low.title.isEmpty && !low.detail.isEmpty)
        // Neither is a generic "Alert N" fallback.
        #expect(!high.title.hasPrefix("Alert "))
        #expect(!low.title.hasPrefix("Alert "))
    }

    @Test func neitherControlIQAlertContainsAnImperativeDosingVerb() {
        let high = PumpAlertCopyOverlay.resolve(id: 50, decodedTitle: "Alert 50", decodedDetail: nil)
        #expect(!AlertCopyAudit.hasImperativeDosingVerb(high.title))
        #expect(!AlertCopyAudit.hasImperativeDosingVerb(high.detail))
        #expect(!AlertCopyAudit.hasImperativeDosingVerb(Self.ciqLowTitle))
        #expect(!AlertCopyAudit.hasImperativeDosingVerb(Self.ciqLowDetail))
    }

    @Test func imperativeDosingVerbAuditCatchesAnUpgradedString() {
        #expect(AlertCopyAudit.hasImperativeDosingVerb("Give a bolus now."))
        #expect(AlertCopyAudit.hasImperativeDosingVerb("Deliver insulin to correct."))
        #expect(!AlertCopyAudit.hasImperativeDosingVerb("Test your blood glucose and treat as necessary."))
    }
}
