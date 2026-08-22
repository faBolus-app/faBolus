import Testing
import Foundation
@testable import faBolus

/// **CR-01 gap closure (Phase 09.17-06).** Structural regression guard for the iPad regular-width
/// Settings sidebar's non-`SettingsCategory` rows — the six setting-groups the code review (CR-01)
/// found reachable on iPhone (`SettingsView.settingsList`'s Mode / Safety / Child-mode / Backup /
/// Data / Privacy sections) but UNREACHABLE from the iPad `NavigationSplitView` sidebar, with no
/// path even via search: the Mode selector, Read-only ("safe viewer") mode, Child mode's PIN lock,
/// Backup & restore, Data & history, and Privacy & data.
///
/// This can't be a full-render visual test (WR-02 — no regular-width snapshot infrastructure exists
/// in this repo), so it pins the two structural facts that would actually regress if a future edit
/// dropped one of these rows or let search drift out of sync with the sidebar:
/// 1. `SettingsSidebarItem.allExtras` (the canonical list `sidebarList`'s second section renders)
///    contains exactly the six CR-01 groups (6 total) — not fewer.
/// 2. `SettingsExtraIndex.entries` (the sidebar's search coverage for those rows) has NO drift from
///    `allExtras` — every extra sidebar item is searchable, and nothing is searchable that isn't
///    also a real sidebar row.
///
/// Phase 4 (04-02, D-05/NUDGE-01): the count dropped 7 → 6 and `.smartAssist` was removed from both
/// `SettingsSidebarItem` and this assertion — the whole Smart Assist settings submenu (and its
/// sidebar entry point) was git rm'd from narrow `main` (delete-on-main, preserved on `dev/nudge`).
///
/// Phase 6 (06-02, D-06/D-08, Rule 3 — minimal interim fix): the count drops 6 → 5 —
/// `.backupRestore` is removed (the backup/restore sidebar row is gone); `.privacyData` is KEPT
/// (D-08, routes to the trimmed erase-only view). This is the minimal compile/assertion fix Task 2's
/// own `SettingsSidebarItem` enum edit requires; Plan 03 supersedes it with the full §6c token-audit
/// treatment (dated comment idiom, `CompileGateAudit.gatedOffSearchTokens` extension).
@Suite struct SettingsSidebarParityTests {

    @Test func allExtrasCoversAllFiveGroups() {
        let extras = Set(SettingsSidebarItem.allExtras)
        #expect(extras.count == 5)
        #expect(extras.contains(.mode))
        #expect(extras.contains(.safety))
        #expect(extras.contains(.childMode))
        #expect(extras.contains(.dataHistory))
        #expect(extras.contains(.privacyData))
    }

    @Test func extraSearchIndexHasNoDriftFromSidebarExtras() {
        let sidebarItems = Set(SettingsSidebarItem.allExtras)
        let indexedItems = Set(SettingsExtraIndex.entries.map(\.item))
        #expect(sidebarItems == indexedItems)
    }

    @Test func searchFindsChildModeAndReadOnlyModeBySafetyCriticalKeywords() {
        // The two safety/access-control groups CR-01 called out by name must be searchable —
        // Child mode's PIN lock and Read-only ("safe viewer") mode.
        #expect(SettingsExtraIndex.entries.contains { $0.matches("child") && $0.item == .childMode })
        #expect(SettingsExtraIndex.entries.contains { $0.matches("pin") && $0.item == .childMode })
        #expect(SettingsExtraIndex.entries.contains { $0.matches("read-only") && $0.item == .safety })
        #expect(SettingsExtraIndex.entries.contains { $0.matches("safe viewer") && $0.item == .safety })
    }

    @Test func searchFindsModeDataHistoryAndPrivacy() {
        #expect(SettingsExtraIndex.entries.contains { $0.matches("mode") && $0.item == .mode })
        #expect(SettingsExtraIndex.entries.contains { $0.matches("history") && $0.item == .dataHistory })
        #expect(SettingsExtraIndex.entries.contains { $0.matches("privacy") && $0.item == .privacyData })
    }
}
