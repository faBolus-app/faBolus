import Testing
import faBolusCore
@testable import faBolus

/// P16 F6 (N13) — localization-seed guard. Asserts the mode-description slice resolves through the app's
/// String Catalog (`Localizable.xcstrings`, via `ModeCopy` → `String(localized:)`) to its expected
/// ENGLISH values, so the seed is real (not an empty catalog) and a future edit can't silently drop it.
/// Mirrors `RegulatoryCopyTests`. This does NOT bless the wording — the mode/Objectives copy still needs
/// owner + a §13 clinician sign-off before an `experimental` build is distributed (BRANCHES.md §13).
@Suite struct ModeCopyTests {

    @Test func modeDescriptionsResolveToEnglish() {
        #expect(ModeCopy.description(.simple) == "Just the essentials: glucose and bolus.")
        #expect(ModeCopy.description(.standard) == "Adds suspend/resume, activity (Sleep/Exercise) modes, and display customization.")
        #expect(ModeCopy.description(.advanced) == "Adds temp basal, profiles, Control-IQ settings, cartridge & fill, and pump limits — features that change therapy.")
    }
}
