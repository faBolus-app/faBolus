import Testing
import Foundation
import faBolusCore
import UserNotifications
@testable import faBolus

/// P9 step 3 — the app-side broker owner. Pins that the coordinator's runtime + the single poster:
///  (1) never drop a safety category no matter how hostile the config,
///  (2) suppress a disabled governed category,
///  (3) persist the daily counters across a runtime restart (App-Group-backed, so a sibling process sees them),
///  (4) honor one-per-episode and re-enable it once an alert clears (`forgetEpisode`), and
///  (5) build each request with the message's OWN `dedupeKey` as the identifier — so two distinct
///     remote-bolus rejections get two distinct notifications (the old fixed id collapsed them onto one).
///
/// An isolated `UserDefaults` suite + an injected `add` closure keep this off the real notification
/// center and out of shared state.
@MainActor
@Suite(.serialized) struct NotificationCoordinatorTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    private func at(_ h: Int, _ m: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))!
    }
    /// A throwaway, empty defaults suite (unique per test) so runtime state never leaks.
    private func isolatedStore(_ name: String) -> UserDefaults {
        let suite = "test.notif.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
    private func msg(_ c: C, key: String = "k") -> B.Message {
        B.Message(category: c, severity: .warning, title: "t", body: "b", dedupeKey: key)
    }

    @Test func safetyCategoriesPostEvenWhenEverythingIsLocked() {
        let hostile = Dictionary(uniqueKeysWithValues: C.allCases.map {
            ($0, B.CategorySettings(enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1,
                                    minIntervalSeconds: 99_999))
        })
        let rt = NotificationRuntime(store: isolatedStore(#function), settings: hostile,
                                     budget: B.Budget(dailyTotal: 0, dailyMeal: 0))
        var posted: [String] = []
        for c in C.allCases where c.neverSuppressible {
            let d = NotificationPoster.post(msg(c, key: c.rawValue), runtime: rt, now: at(3, 0)) {
                posted.append($0.identifier)
            }
            #expect(d.deliver, "\(c.rawValue) must always post")
        }
        #expect(Set(posted) == ["pumpDisconnect", "bolusReconciliation", "cgmDataLoss"])
        // A governed category under the SAME hostile config does not post (proves the config is hostile).
        let g = NotificationPoster.post(msg(.pumpAlert), runtime: rt, now: at(3, 0)) { posted.append($0.identifier) }
        #expect(!g.deliver && g.reason == .categoryDisabled)
    }

    @Test func dailyCountersPersistAcrossARuntimeRestart() {
        let store = isolatedStore(#function)
        let rt1 = NotificationRuntime(store: store)
        let d = NotificationPoster.post(msg(.pumpAlert, key: "a"), runtime: rt1, now: at(9, 0)) { _ in }
        #expect(d.deliver && rt1.state.deliveredToday == 1)
        // A fresh runtime on the same store (a relaunch, or the mode-reminder intent process) sees it.
        let rt2 = NotificationRuntime(store: store)
        #expect(rt2.state.deliveredToday == 1)
    }

    @Test func settingsPersistAcrossARuntimeRestart() {
        let store = isolatedStore(#function)
        let rt1 = NotificationRuntime(store: store)
        var cfg = rt1.settings[.pumpAlert] ?? .defaults(for: .pumpAlert)
        cfg.enabled = false
        cfg.allowCriticalBreakthrough = false
        rt1.updateSettings(cfg, for: .pumpAlert)
        // A fresh runtime on the same store (a relaunch, or a sibling out-of-process poster) sees it.
        let rt2 = NotificationRuntime(store: store)
        #expect(rt2.settings[.pumpAlert]?.enabled == false)
        #expect(rt2.settings[.pumpAlert]?.allowCriticalBreakthrough == false)
    }

    @Test func breakThroughOffPersistsAndIsHonoredByThePosterAcrossARuntimeRestart() {
        // End-to-end tracer: model -> persistence -> decide, proven through the real poster (D-04).
        let store = isolatedStore(#function)
        let rt1 = NotificationRuntime(store: store)
        var cfg = rt1.settings[.pumpAlert] ?? .defaults(for: .pumpAlert)
        // Otherwise-enabled config (enabled stays true) — only quiet-hours + break-through change, so the
        // suppression below is provably caused by the break-through toggle unmasking quiet-hours governance.
        cfg.quietStartMinuteOfDay = 0
        cfg.quietEndMinuteOfDay = 1439
        cfg.allowCriticalBreakthrough = false
        rt1.updateSettings(cfg, for: .pumpAlert)
        let rt2 = NotificationRuntime(store: store)
        let critical = B.Message(category: .pumpAlert, severity: .critical, title: "Occlusion", body: "b",
                                 dedupeKey: "occ2")
        let d = NotificationPoster.post(critical, runtime: rt2, now: at(9, 0)) { _ in }
        #expect(!d.deliver && d.reason == .quietHours,
               "persisted break-through OFF is honored by a fresh runtime + the real poster")
        // A trio post on rt2 still delivers, unaffected by the pumpAlert-only settings mutation.
        let trio = NotificationPoster.post(msg(.pumpDisconnect, key: "trio1"), runtime: rt2, now: at(9, 0)) { _ in }
        #expect(trio.deliver)
    }

    @Test func onePerEpisodeThenForgetReEnables() {
        let rt = NotificationRuntime(store: isolatedStore(#function))
        #expect(NotificationPoster.post(msg(.pumpAlert, key: "ep"), runtime: rt, now: at(9, 0)) { _ in }.deliver)
        // A governed repeat of the same key is dropped…
        let again = NotificationPoster.post(msg(.pumpAlert, key: "ep"), runtime: rt, now: at(9, 5)) { _ in }
        #expect(again.reason == .episodeAlreadyNotified)
        // …until the alert clears and we forget it — then a genuine re-raise posts again.
        rt.forgetEpisode("ep")
        #expect(NotificationPoster.post(msg(.pumpAlert, key: "ep"), runtime: rt, now: at(9, 10)) { _ in }.deliver)
    }

    @Test func snoozeSuppressesAGovernedCategoryAcrossARuntimeRestartButNeverSafety() {
        let store = isolatedStore(#function)
        let rt1 = NotificationRuntime(store: store)
        rt1.snooze(.pumpAlert, until: at(10, 0))
        #expect(NotificationPoster.post(msg(.pumpAlert), runtime: rt1, now: at(9, 0)) { _ in }.reason == .snoozed)
        // A fresh runtime on the same App-Group store still honors the snooze (persisted, cross-process).
        let rt2 = NotificationRuntime(store: store)
        #expect(NotificationPoster.post(msg(.pumpAlert), runtime: rt2, now: at(9, 0)) { _ in }.reason == .snoozed)
        #expect(NotificationPoster.post(msg(.pumpAlert), runtime: rt2, now: at(10, 1)) { _ in }.deliver)
        // A safety category can never be snoozed, even when asked.
        rt2.snooze(.pumpDisconnect, until: at(10, 0))
        #expect(NotificationPoster.post(msg(.pumpDisconnect), runtime: rt2, now: at(9, 0)) { _ in }.deliver)
    }

    @Test func telemetryAccruesOnlyWhenOptedInAndAttributesResponses() {
        let store = isolatedStore(#function)
        let rt = NotificationRuntime(store: store)
        // Opt-OUT (default): a delivered post records nothing.
        NotificationPoster.post(msg(.pumpAlert, key: "a"), runtime: rt, now: at(9, 0)) { _ in }
        #expect(rt.telemetry.isEmpty)
        // Opt IN. Use a DISTINCT dedupeKey so this post isn't episode-suppressed by the first.
        store.set(true, forKey: NotificationRuntime.telemetryEnabledKey)
        let d = NotificationPoster.post(msg(.pumpAlert, key: "b"), runtime: rt, now: at(9, 1)) { _ in }
        #expect(d.deliver)
        rt.recordResponse(categoryRawValue: "pumpAlert", actionIdentifier: UNNotificationDismissActionIdentifier)  // dismissed
        rt.recordResponse(categoryRawValue: "pumpAlert", actionIdentifier: "SNOOZE")                                // acted-upon
        #expect(rt.telemetry["pumpAlert"] == NotificationBroker.CategoryTelemetry(delivered: 1, dismissed: 1, actedUpon: 1))
        // Persists across a runtime restart on the same App-Group store.
        let rt2 = NotificationRuntime(store: store)
        #expect(rt2.telemetry["pumpAlert"]?.delivered == 1)
    }

    /// S7: an escalation step posts with a `UNTimeIntervalNotificationTrigger` at its elapsed time (so the
    /// OS delivers it while the app is suspended), while a default (nil-trigger) post is still immediate —
    /// proving the new optional trigger threads through the sole poster without changing existing callers.
    @Test func posterThreadsAScheduledTriggerButDefaultsToImmediate() {
        let rt = NotificationRuntime(store: isolatedStore(#function))
        let step = DisconnectEscalation.steps.first!
        var scheduled: [UNNotificationRequest] = []
        let d = NotificationPoster.post(
            msg(.pumpDisconnect, key: step.id), runtime: rt,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: step.afterSeconds, repeats: false),
            now: at(9, 0)) { scheduled.append($0) }
        #expect(d.deliver)                                            // never-suppressible → always posts
        #expect(scheduled.first?.identifier == step.id)              // step's own stable id
        let trig = scheduled.first?.trigger as? UNTimeIntervalNotificationTrigger
        #expect(trig?.timeInterval == step.afterSeconds)
        #expect(trig?.repeats == false)
        // A default post (no trigger arg) is still immediate — existing callers are unchanged.
        var immediate: [UNNotificationRequest] = []
        NotificationPoster.post(msg(.pumpDisconnect, key: "safety.pumpDisconnect"),
                                runtime: rt, now: at(9, 0)) { immediate.append($0) }
        #expect(immediate.first?.trigger == nil)
    }

    /// B6: the OS Critical Alert level is applied ONLY to the never-suppressible safety categories, and
    /// ONLY when the caller allows it (entitlement granted + user opted in). A governed category never gets
    /// it, and a safety category degrades gracefully to the normal level when not allowed. D-06: also
    /// asserts `.sound` alongside `.interruptionLevel` — the `.defaultCritical`/`.default` half of SC1/SC2
    /// that no test previously covered.
    ///
    /// CR-01: while the Critical-Alerts entitlement is pending, the "not allowed" degrade path for the
    /// safety trio must still break through Focus/DND, or the shipped "time-sensitive delivery" copy in
    /// AlertRulesView is a lie. So the degrade target is `.timeSensitive` (breaks through Focus), NOT
    /// `.active` (silenced by Focus) — scoped to `neverSuppressible` categories only; a governed category
    /// under the same "not allowed" conditions must stay at the untouched default.
    @Test func criticalLevelOnlyForSafetyAndOnlyWhenAllowed() {
        let rt = NotificationRuntime(store: isolatedStore(#function))
        var reqs: [UNNotificationRequest] = []
        // Safety category + allowed → .critical / .defaultCritical.
        NotificationPoster.post(msg(.pumpDisconnect, key: "s1"), runtime: rt, allowCritical: true, now: at(9, 0)) { reqs.append($0) }
        #expect(reqs.first?.content.interruptionLevel == .critical)
        #expect(reqs.first?.content.sound == .defaultCritical)
        // Safety category but NOT allowed (entitlement absent / opt-out off) → degrades to .timeSensitive,
        // which still breaks through Focus/DND (unlike .active) — CR-01. Sound stays .default: the special
        // critical sound is reserved for the fully-granted .critical path above.
        reqs.removeAll()
        NotificationPoster.post(msg(.cgmDataLoss, key: "s2"), runtime: rt, allowCritical: false, now: at(9, 0)) { reqs.append($0) }
        #expect(reqs.first?.content.interruptionLevel == .timeSensitive)
        #expect(reqs.first?.content.sound == .default)
        // A governed (suppressible) category never gets .critical, even when allowed.
        reqs.removeAll()
        NotificationPoster.post(msg(.pumpAlert, key: "g1"), runtime: rt, allowCritical: true, now: at(9, 0)) { reqs.append($0) }
        #expect(reqs.first?.content.interruptionLevel == .active)
        #expect(reqs.first?.content.sound == .default)
        // CR-01 scope check: a governed category with allowCritical:false (today's default caller shape)
        // stays at the plain default — it must NOT pick up .timeSensitive just because it shares the
        // "not allowed" branch with the safety trio above.
        reqs.removeAll()
        NotificationPoster.post(msg(.pumpAlert, key: "g2"), runtime: rt, allowCritical: false, now: at(9, 0)) { reqs.append($0) }
        #expect(reqs.first?.content.interruptionLevel == .active)
        #expect(reqs.first?.content.sound == .default)
    }

    /// B6: the pump-alarm opt-out suppresses ONLY a pump ALARM the user opted out of — never a lower-
    /// priority pump ALERT, and never when the opt-out is off.
    @Test func mirroredAlarmOptOutSuppressesOnlyAlarmsAndOnlyWhenOptedOut() {
        #expect(NotificationCoordinator.suppressesMirroredAlarm(kind: .alarm, optedOut: true))
        #expect(!NotificationCoordinator.suppressesMirroredAlarm(kind: .alarm, optedOut: false))
        #expect(!NotificationCoordinator.suppressesMirroredAlarm(kind: .alert, optedOut: true))
        #expect(!NotificationCoordinator.suppressesMirroredAlarm(kind: .cgmAlert, optedOut: true))
    }

    /// D-03/D-04: the honest "pending Apple approval" status shows ONLY when the user opted in
    /// (`criticalAlertsEnabled == true`) AND the OS grant is not active — the four-case truth table.
    /// 08.1-02 (D-07): `shouldShowHonestStatus` relocated from `AlertRulesView` to
    /// `NotificationSettingsView` along with the toggle it gates — this pin follows the move.
    @Test func honestStatusShownOnlyWhenEnabledAndNotGranted() {
        #expect(NotificationSettingsView.shouldShowHonestStatus(enabled: true, grantActive: false) == true)
        #expect(NotificationSettingsView.shouldShowHonestStatus(enabled: true, grantActive: true) == false)
        #expect(NotificationSettingsView.shouldShowHonestStatus(enabled: false, grantActive: false) == false)
        #expect(NotificationSettingsView.shouldShowHonestStatus(enabled: false, grantActive: true) == false)
    }

    /// 09.25-01 Task 1 (tracer, D-03/D-06/D-08/D-09): the safety trio becomes user-disableable behind an
    /// acknowledged-disable flag. This is the end-to-end slice: write the disable through
    /// `NotificationRuntime.updateSettings` on an isolated store, then prove a FRESH runtime + the real
    /// `NotificationPoster` honors it — while an untouched trio category still delivers.
    @Test func acknowledgedSafetyDisablePersistsAndIsHonoredByAFreshRuntimeAndTheRealPoster() {
        let store = isolatedStore(#function)
        let rt1 = NotificationRuntime(store: store)
        var cfg = rt1.settings[.pumpDisconnect] ?? .defaults(for: .pumpDisconnect)
        cfg.enabled = false
        cfg.userAcknowledgedSafetyDisable = true
        rt1.updateSettings(cfg, for: .pumpDisconnect)
        // A FRESH runtime on the same App-Group store (a relaunch, or an out-of-process poster).
        let rt2 = NotificationRuntime(store: store)
        let disabled = NotificationPoster.post(msg(.pumpDisconnect, key: "pd1"), runtime: rt2, now: at(9, 0)) { _ in }
        #expect(!disabled.deliver && disabled.reason == .categoryDisabled,
               "an acknowledged safety-disable is honored by a fresh runtime + the real poster")
        // cgmDataLoss (untouched) still delivers on the same runtime.
        let untouched = NotificationPoster.post(msg(.cgmDataLoss, key: "cgm1"), runtime: rt2, now: at(9, 0)) { _ in }
        #expect(untouched.deliver, "an untouched trio category is unaffected by another category's disable")
    }

    /// decide(): `!enabled` alone must NEVER suppress a trio — only the paired acknowledgment does.
    @Test func decideRequiresBothEnabledFalseAndAcknowledgedTrueToSuppressATrioCategory() {
        typealias B = NotificationBroker
        // enabled==false, ack unset (nil) → still delivers.
        let notAcked = B.decide(msg(.pumpDisconnect),
                                settings: [.pumpDisconnect: B.CategorySettings(enabled: false)],
                                state: B.State(), now: at(9, 0))
        #expect(notAcked.deliver, "the ack flag is the mandatory gate — !enabled alone must never suppress a trio")
        // enabled==false, ack==true → suppressed.
        var ackedCfg = B.CategorySettings(enabled: false)
        ackedCfg.userAcknowledgedSafetyDisable = true
        let acked = B.decide(msg(.pumpDisconnect), settings: [.pumpDisconnect: ackedCfg],
                             state: B.State(), now: at(9, 0))
        #expect(!acked.deliver && acked.reason == .categoryDisabled)
    }

    /// 09.25-02 Task 1 (D-01/D-02): pure caption helper pins the exact UI-SPEC copy for the
    /// break-through row's three effective-state branches — the direct fix for the D-01 override
    /// ambiguity (a disabled category's break-through row must read as moot, not silently ignored).
    @Test func breakThroughCaptionCoversAllThreeEffectiveStateBranches() {
        #expect(NotificationSettingsView.breakThroughCaption(enabled: true, allow: true)
                == "On — this category's urgent/critical alerts always break through quiet hours and limits.")
        #expect(NotificationSettingsView.breakThroughCaption(enabled: true, allow: false)
                == "Off — this category's urgent/critical alerts follow the normal quiet-hours/limit rules below.")
        #expect(NotificationSettingsView.breakThroughCaption(enabled: false, allow: true)
                == "Off — category is disabled, so break-through has no effect.")
        // `allow` is moot once the master is off — same string regardless of its value.
        #expect(NotificationSettingsView.breakThroughCaption(enabled: false, allow: false)
                == "Off — category is disabled, so break-through has no effect.")
    }

    /// 09.25-02 Task 1 (D-06): the silence-pump-alarms row's effective-state caption is non-nil ONLY
    /// when the pump section's master is off (the row has no effect while `pumpAlert` is disabled).
    @Test func silenceMirrorCaptionOnlyWhenPumpDisabled() {
        #expect(NotificationSettingsView.silenceMirrorCaption(pumpEnabled: false)
                == "No effect — pump alerts are disabled.")
        #expect(NotificationSettingsView.silenceMirrorCaption(pumpEnabled: true) == nil)
    }

    /// 09.25-02 Task 2 (D-02c): resolves `NotificationSettingsView.swift` by walking up from
    /// `#filePath`, mirroring `SettingsReachabilityGuardTests.viewsDirURL()` — same technique, scoped to
    /// one file rather than a whole directory.
    private static func notificationSettingsViewFileURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("ios/faBolus/Views/NotificationSettingsView.swift")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// 09.25-02 Task 2 (D-02c/T-09.25-06): the Interruption Strength section (relabel of "Critical
    /// Alerts") must gate NOTHING else on screen — no `.disabled(...)` call anywhere in the view may
    /// read `criticalAlertsEnabled`. Scans every `.disabled(` occurrence's balanced-parenthesis argument
    /// for the flag token; the plain toggle binding (`$settings.criticalAlertsEnabled`) and
    /// `shouldShowHonestStatus(...)` references are allowed since neither is a `.disabled(...)` call.
    /// Fails loudly (non-vacuously) if the file can't be resolved/read or if greying has regressed to
    /// zero `.disabled(` sites.
    @Test func interruptionStrengthSectionGatesNoOtherRow() throws {
        guard let url = Self.notificationSettingsViewFileURL(),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("could not resolve/read NotificationSettingsView.swift from #filePath=\(#filePath)")
            return
        }
        #expect(!source.isEmpty, "path resolution broke — read zero bytes from NotificationSettingsView.swift")

        var searchStart = source.startIndex
        var disabledSitesFound = 0
        while let range = source.range(of: ".disabled(", range: searchStart..<source.endIndex) {
            disabledSitesFound += 1
            // Extract the parenthesized argument up to its own matching close paren — every
            // `.disabled(...)` call site in this file is a simple boolean expression, so a single-level
            // balance counter is sufficient (no need for a full expression parser).
            var depth = 0
            var i = range.upperBound
            var argEnd = i
            while i < source.endIndex {
                let ch = source[i]
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    if depth == 0 { argEnd = i; break }
                    depth -= 1
                }
                i = source.index(after: i)
            }
            let arg = String(source[range.upperBound..<argEnd])
            #expect(!arg.contains("criticalAlertsEnabled"),
                    "found .disabled(...) reading criticalAlertsEnabled: \(arg)")
            searchStart = source.index(after: range.lowerBound)
        }
        #expect(disabledSitesFound > 0,
                "found zero .disabled( occurrences in NotificationSettingsView.swift — parent-master greying may have regressed")
    }

    @Test func posterUsesTheMessageDedupeKeyAsIdentifierSoRejectionsAreDistinct() {
        let rt = NotificationRuntime(store: isolatedStore(#function))
        var ids: [String] = []
        // Two rejections with the distinct ids AppModel now assigns (rejectionSeq).
        NotificationPoster.post(msg(.remoteBolusRejected, key: "remoteBolusRejected-1"),
                                runtime: rt, now: at(9, 0)) { ids.append($0.identifier) }
        NotificationPoster.post(msg(.remoteBolusRejected, key: "remoteBolusRejected-2"),
                                runtime: rt, now: at(9, 0)) { ids.append($0.identifier) }
        #expect(ids == ["remoteBolusRejected-1", "remoteBolusRejected-2"])   // old fixed id collapsed both
    }

    // MARK: - 09.25 REVIEW-FIX (WR-01 / WR-02 / IN-01)

    /// IN-01: pins the safety-trio toggle's Cancel/snap-back contract at its ACTUAL call-site wiring
    /// (`safetyEnabledBinding`, via the extracted `safetyTrioToggleBinding` factory) rather than only the
    /// generic `guardedToggle` contract `GuardedToggleTests` already covers — turning the toggle OFF must
    /// request confirm and must NOT write `enabled` until the confirm button fires; if Cancel is chosen
    /// (never calls `setEnabled`), a re-read must show the toggle back ON with nothing written.
    @Test func safetyTrioToggleCancelSnapsBackWithoutWritingEnabled() {
        var backing = true   // currently ON (protection active)
        var setCalls: [Bool] = []
        var confirmRequested = 0
        let binding = NotificationSettingsView.safetyTrioToggleBinding(
            enabled: { backing },
            setEnabled: { on in setCalls.append(on); backing = on },
            requestConfirmDisable: { confirmRequested += 1 }
        )
        #expect(binding.wrappedValue == true)
        binding.wrappedValue = false   // user taps the toggle OFF
        #expect(confirmRequested == 1, "turning off must request confirm before writing anything")
        #expect(setCalls.isEmpty, "must not write `enabled` until the confirm button explicitly fires")
        // Simulate Cancel: no dialog action ever calls setEnabled. A re-read must snap back to ON.
        #expect(binding.wrappedValue == true, "Cancel must snap the toggle back to its prior (on) state")
        #expect(backing == true, "Cancel must never have written the backing value")
    }

    /// IN-01 / WR-01 companion: confirming (not cancelling) DOES write through `setEnabled`, so the
    /// snap-back test above isn't vacuously passing because writes are broken entirely.
    @Test func safetyTrioToggleConfirmWritesThroughSetEnabled() {
        var backing = true
        var setCalls: [Bool] = []
        let binding = NotificationSettingsView.safetyTrioToggleBinding(
            enabled: { backing }, setEnabled: { on in setCalls.append(on); backing = on },
            requestConfirmDisable: { }
        )
        binding.wrappedValue = false             // requests confirm, no write yet
        setCalls.append(false); backing = false  // simulate the confirm button's own explicit action
        #expect(binding.wrappedValue == false)
        #expect(setCalls == [false])
    }

    /// WR-02: `trioIsSuppressed` must mirror `NotificationBroker.decide()`'s exact AND-gate — `enabled ==
    /// false` alone (no acknowledgment) must NEVER read as suppressed, matching
    /// `decideRequiresBothEnabledFalseAndAcknowledgedTrueToSuppressATrioCategory` above one-for-one so the
    /// UI caption/toggle can never diverge from what `decide()` actually delivers.
    @Test func trioIsSuppressedMirrorsDecidesExactAndGate() {
        typealias B = NotificationBroker
        #expect(!NotificationSettingsView.trioIsSuppressed(cfg: nil))
        #expect(!NotificationSettingsView.trioIsSuppressed(cfg: B.CategorySettings(enabled: true)))
        // enabled == false, ack unset (nil) → NOT suppressed (the exact WR-02 failure shape).
        #expect(!NotificationSettingsView.trioIsSuppressed(cfg: B.CategorySettings(enabled: false)))
        // enabled == false, ack explicitly false → still NOT suppressed.
        var ackedFalse = B.CategorySettings(enabled: false)
        ackedFalse.userAcknowledgedSafetyDisable = false
        #expect(!NotificationSettingsView.trioIsSuppressed(cfg: ackedFalse))
        // enabled == false AND ack == true → suppressed (the only true case).
        var acked = B.CategorySettings(enabled: false)
        acked.userAcknowledgedSafetyDisable = true
        #expect(NotificationSettingsView.trioIsSuppressed(cfg: acked))
        // enabled == true (regardless of ack) → never suppressed.
        var enabledButAcked = B.CategorySettings(enabled: true)
        enabledButAcked.userAcknowledgedSafetyDisable = true
        #expect(!NotificationSettingsView.trioIsSuppressed(cfg: enabledButAcked))
    }

    /// WR-01 regression: `NotificationCoordinator.identifiers(for:in:)` is the matching contract
    /// `withdrawAll(for:)` uses to find every OS-outstanding request for a category — pins that it
    /// filters by the `brokerCategory` userInfo stamp (`NotificationPoster.post`) rather than a static
    /// dedupe-key list, so it also matches `.bolusReconciliation`'s per-attempt DYNAMIC keys
    /// (`reconcile-<peerId>-<requestId>`, which have no fixed list to enumerate ahead of time) and never
    /// cross-matches an unrelated category.
    @Test func withdrawAllMatchesOnlyRequestsStampedWithTheGivenCategory() {
        func request(_ id: String, category: NotificationBroker.Category) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.userInfo = ["brokerCategory": category.rawValue]
            return UNNotificationRequest(identifier: id, content: content, trigger: nil)
        }
        let requests = [
            request("safety.pumpDisconnect", category: .pumpDisconnect),
            request("pumpDisconnect-escalation-1", category: .pumpDisconnect),
            request("reconcile-peerA-req1", category: .bolusReconciliation),   // dynamic key, no static list
            request("safety.cgmDataLoss", category: .cgmDataLoss),
            request("some-pump-alert", category: .pumpAlert),                  // must NOT match any trio
        ]
        #expect(Set(NotificationCoordinator.identifiers(for: .pumpDisconnect, in: requests))
                == ["safety.pumpDisconnect", "pumpDisconnect-escalation-1"])
        #expect(NotificationCoordinator.identifiers(for: .bolusReconciliation, in: requests)
                == ["reconcile-peerA-req1"])
        #expect(NotificationCoordinator.identifiers(for: .cgmDataLoss, in: requests) == ["safety.cgmDataLoss"])
        // The unrelated pump-alert request matches ONLY its own category — never a trio query, and no
        // trio query's result set ever includes it (checked implicitly above via exact-set equality).
        #expect(NotificationCoordinator.identifiers(for: .pumpAlert, in: requests) == ["some-pump-alert"])
    }

    /// WR-01: a request with no `brokerCategory` userInfo at all (shouldn't happen — every poster stamps
    /// it — but the filter must degrade safely rather than crash or over-match) never matches any category.
    @Test func withdrawAllNeverMatchesARequestMissingTheBrokerCategoryStamp() {
        let content = UNMutableNotificationContent()   // no userInfo set
        let bare = UNNotificationRequest(identifier: "bare", content: content, trigger: nil)
        #expect(NotificationCoordinator.identifiers(for: .pumpDisconnect, in: [bare]) == [])
    }

    // MARK: - Phase 13-01 Task 2 (CX-F-03 depth, T3-01/02): SafetyAlertStore persist-then-replay

    /// Test 1 (full-content round-trip): a `SafetyAlertStore.Entry` persists the COMPLETE replay
    /// contract — not just `{dedupeKey, issuedDate, escalationStep}` (codex HIGH) — and decodes back
    /// identically from a FRESH store instance on the same App-Group-style `UserDefaults` suite.
    @Test func safetyAlertStoreFullContentRoundTrips() {
        let defaults = isolatedStore(#function)
        let store1 = SafetyAlertStore(store: defaults)
        let entry = SafetyAlertStore.Entry(
            category: .pumpDisconnect, severity: .error, title: "Pump disconnected",
            body: "faBolus lost the connection to your pump.", dedupeKey: "safety.pumpDisconnect",
            userInfo: ["k": "v"], categoryIdentifier: "", issuedDate: at(9, 0),
            deadline: at(9, 15), kind: .delayed, lifecycleState: .issued)
        store1.record(entry)

        let store2 = SafetyAlertStore(store: defaults)   // fresh instance, same store
        #expect(store2.entries["safety.pumpDisconnect"] == entry,
                "the full replay contract must round-trip byte-for-byte, not a reduced {dedupeKey,issuedDate,escalationStep} shape")
    }

    /// Test 2 (immediate vs delayed replay): the pure trigger-selection rule `replayTrigger` — an
    /// inherently-immediate entry (`deadline == nil`, e.g. `.cgmDataLoss`/`.bolusReconciliation`, which
    /// have no escalation step) or an OVERDUE delayed entry (`deadline <= now`) replays with `nil`
    /// (immediate post) — NEVER a computed `UNTimeIntervalNotificationTrigger(timeInterval: 0)` (invalid).
    /// A not-yet-due delayed entry replays with a strictly-positive interval re-derived from `deadline - now`.
    @Test func replayTriggerIsImmediateForNilOrOverdueDeadlineAndPositiveIntervalForPending() {
        let now = at(9, 0)
        #expect(NotificationCoordinator.replayTrigger(deadline: nil, now: now) == nil)
        #expect(NotificationCoordinator.replayTrigger(deadline: now.addingTimeInterval(-1), now: now) == nil)
        // Exactly `now` must also read as overdue/immediate — never a literal 0s trigger.
        #expect(NotificationCoordinator.replayTrigger(deadline: now, now: now) == nil)
        let pending = NotificationCoordinator.replayTrigger(deadline: now.addingTimeInterval(300), now: now)
        let trig = pending as? UNTimeIntervalNotificationTrigger
        #expect(trig != nil, "a not-yet-due delayed entry must replay with a real scheduled trigger")
        #expect(trig?.timeInterval == 300)
        #expect(trig?.repeats == false)
    }

    /// Test 3 (atomic persist-before-post): `SafetyAlertPoster.post` must write the durable entry to
    /// `store` BEFORE invoking the injectable `add` closure — asserted by checking, FROM INSIDE `add`,
    /// that the entry is already present in the store (addresses codex MEDIUM).
    @Test func safetyAlertPosterPersistsBeforeSubmittingTheOSRequest() {
        let defaults = isolatedStore(#function)
        let store = SafetyAlertStore(store: defaults)
        let rt = NotificationRuntime(store: defaults)
        var sawPersistedBeforeAdd = false
        var addCallCount = 0

        let decision = SafetyAlertPoster.post(msg(.pumpDisconnect, key: "ord1"), store: store, runtime: rt,
                                              now: at(9, 0)) { _ in
            addCallCount += 1
            sawPersistedBeforeAdd = store.entries["ord1"] != nil
        }

        #expect(decision.deliver)
        #expect(addCallCount == 1)
        #expect(sawPersistedBeforeAdd, "the entry must already be durable by the time the OS add(_:) runs")
    }

    /// Test 4 (prune on resolve, BOTH paths): `NotificationCoordinator.withdraw(_:)` AND
    /// `withdrawAll(for:)` must EACH prune their matching durable `SafetyAlertStore` entries — a
    /// category-wide withdrawal that leaves a durable entry behind would replay it after the condition
    /// resolved (addresses codex MEDIUM).
    @Test func withdrawAndWithdrawAllBothPruneTheDurableSafetyStore() {
        let defaults = isolatedStore(#function)
        let store = SafetyAlertStore(store: defaults)
        let rt = NotificationRuntime(store: defaults)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("safety-store-\(UUID().uuidString).json")
        let model = AppModel(source: MockBackend(), ledgerStoreURL: url)
        let coordinator = NotificationCoordinator(model: model, runtime: rt, safetyAlertStore: store)

        store.record(.init(category: .pumpDisconnect, severity: .error, title: "t", body: "b",
                           dedupeKey: "safety.pumpDisconnect", userInfo: [:], categoryIdentifier: "",
                           issuedDate: at(9, 0), deadline: nil, kind: .immediate, lifecycleState: .issued))
        store.record(.init(category: .bolusReconciliation, severity: .error, title: "t2", body: "b2",
                           dedupeKey: "reconcile-watch-r1", userInfo: [:], categoryIdentifier: "",
                           issuedDate: at(9, 0), deadline: nil, kind: .immediate, lifecycleState: .issued))

        coordinator.withdraw(["safety.pumpDisconnect"])
        #expect(store.entries["safety.pumpDisconnect"] == nil, "withdraw(_:) must prune the durable entry")
        #expect(store.entries["reconcile-watch-r1"] != nil)

        coordinator.withdrawAll(for: .bolusReconciliation)
        #expect(store.entries["reconcile-watch-r1"] == nil, "withdrawAll(for:) must prune the durable entry")
    }
}
