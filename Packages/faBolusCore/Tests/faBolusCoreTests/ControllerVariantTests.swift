import Testing
@testable import faBolusCore

struct ControllerVariantTests {

    /// The raw values are a frozen v1 remote-wire contract (`RemoteCommand.controllerVariant`). This test
    /// fails if a case is renamed in a way that changes its token (which would silently break older remotes).
    /// The marketing name is "Control-IQ+" but the wire token stays `controlIQPro`.
    @Test func rawValuesAreTheFrozenWireContract() {
        #expect(ControllerVariant.none.rawValue == "none")
        #expect(ControllerVariant.controlIQ.rawValue == "controlIQ")
        #expect(ControllerVariant.controlIQPro.rawValue == "controlIQPro")
        // A non-token (e.g. a future rename to the marketing name) must not resolve.
        #expect(ControllerVariant(rawValue: "controlIQPlus") == nil)
        // Every case round-trips through its own raw (a remote decodes with `?? .none`).
        for v in ControllerVariant.allCases { #expect(ControllerVariant(rawValue: v.rawValue) == v) }
    }
}
