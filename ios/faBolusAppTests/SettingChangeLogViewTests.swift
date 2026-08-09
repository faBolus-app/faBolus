import Testing
import faBolusCore
@testable import faBolus

/// §2.1(3) B1(b): the change-log row title mapping — a friendly field name plus the segment start time
/// for per-segment keys, an unknown field passing through verbatim.
struct SettingChangeLogViewTests {
    @Test func fieldTitleMapsKnownFieldsAndSegmentStart() {
        #expect(SettingChangeLogView.fieldTitle(.global("maxBolus")) == "Max bolus")
        #expect(SettingChangeLogView.fieldTitle(.global("maxBasal")) == "Max basal")
        #expect(SettingChangeLogView.fieldTitle(.global("controlIQEnabled")) == "Control-IQ")
        #expect(SettingChangeLogView.fieldTitle(.segment(idpId: 0, startMinutes: 480, field: "isf"))
                == "Correction factor (ISF) · 08:00")
        #expect(SettingChangeLogView.fieldTitle(.segment(idpId: 1, startMinutes: 0, field: "basalRate"))
                == "Basal rate · 00:00")
        // Unknown field passes through verbatim (no crash / no mislabel).
        #expect(SettingChangeLogView.fieldTitle(.global("somethingNew")) == "somethingNew")
    }
}
