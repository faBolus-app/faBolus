import Testing
import Foundation
@testable import faBolus

/// Pins that `childModeEnabled` stays frozen false: a direct setter call must never resurrect Child
/// Mode. AccessPolicyTests still pin the evaluator against `true` literals.
@MainActor
struct ChildModeFreezeGuardTests {

    // MARK: - childModeEnabled: no direct setter call can arm it

    @Test func directSetterCallOnChildModeEnabledHasNoEffect() {
        AppSettings.shared.childModeEnabled = true
        #expect(
            AppSettings.shared.childModeEnabled == false,
            "childModeEnabled's getter-level freeze must reject a direct setter call (SAFETY)"
        )
    }
}
