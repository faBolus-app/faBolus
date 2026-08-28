import Testing
import Foundation
@testable import faBolus

/// Pins that iPad sidebar extras stay in lockstep with search, and that Safety (AccessPolicy /
/// read-only) and Privacy (erase-stays-reachable) remain the only extra groups.
@Suite struct SettingsSidebarParityTests {

    @Test func allExtrasCoversBothRemainingGroups() {
        let extras = Set(SettingsSidebarItem.allExtras)
        #expect(extras.count == 2)
        #expect(extras.contains(.safety))
        #expect(extras.contains(.privacyData))
    }

    @Test func extraSearchIndexHasNoDriftFromSidebarExtras() {
        let sidebarItems = Set(SettingsSidebarItem.allExtras)
        let indexedItems = Set(SettingsExtraIndex.entries.map(\.item))
        #expect(sidebarItems == indexedItems)
    }

    @Test func searchFindsReadOnlyModeBySafetyCriticalKeywords() {
        // AccessPolicy / read-only must stay searchable on the remaining Safety extra.
        #expect(SettingsExtraIndex.entries.contains { $0.matches("read-only") && $0.item == .safety })
        #expect(SettingsExtraIndex.entries.contains { $0.matches("safe viewer") && $0.item == .safety })
    }

    @Test func searchFindsPrivacy() {
        #expect(SettingsExtraIndex.entries.contains { $0.matches("privacy") && $0.item == .privacyData })
    }
}
