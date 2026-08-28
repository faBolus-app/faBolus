import Foundation
import faBolusCore
import WidgetKit

extension Notification.Name {
    static let widgetBolusPending = Notification.Name("fabolus.widgetBolusPending")
    static let widgetBolusCancel = Notification.Name("fabolus.widgetBolusCancel")
}

/// Delivers a bolus the Quick-Bolus widget confirmed (1-2-3) without opening the app. The widget
/// posts a Darwin notification; this receiver (alive whenever the app is running — including in the
/// background with the pump connected via `bluetooth-central`) picks up the pending request, drives
/// delivery through the validated signed path, and writes status back to the App Group so the
/// widget shows progress + a cancel button in place.
@MainActor
final class WidgetBolusReceiver {
    private weak var model: AppModel?
    /// C6-02: the CFNotificationCenter Darwin observer identity (`Unmanaged.passUnretained(self)`).
    /// The two `CFNotificationCenterAddObserver` calls below register C callbacks that capture NOTHING —
    /// they run independently of this instance's ARC lifetime and, unless explicitly removed with the
    /// SAME `center`/`observer` pair, keep firing (and re-posting a Foundation notification) even after
    /// this instance is deallocated. A re-created instance after a scene teardown/re-appear would then
    /// have TWO Darwin registrations live for the same notification name, so a single widget post
    /// dispatches twice.
    /// `nonisolated(unsafe)` on these four: `deinit` runs nonisolated (Swift can't guarantee it happens on
    /// the main actor), so removing the observers there needs to read them outside actor isolation. This is
    /// sound — nothing else can run concurrently with `deinit` (by the time it executes, refcount is
    /// already zero / about to be, so no other reference exists to race on these values), and each is
    /// otherwise only ever written once, from `init`, before any other reference to `self` escapes.
    private nonisolated(unsafe) let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
    /// Set once in `init` (an implicitly-unwrapped Optional, not a `lazy var`: computing this from `self`
    /// requires phase-1 init to already be "complete," and a `lazy var` — the usual workaround for a
    /// self-referencing stored value — cannot be read from `deinit`'s nonisolated context on a
    /// `@MainActor` class. A plain stored property CAN be read there.)
    private nonisolated(unsafe) var darwinObserver: UnsafeMutableRawPointer!
    /// The block-observer tokens `NotificationCenter.default.addObserver(forName:...)` returns — previously
    /// discarded (codex MEDIUM), so they could never be removed and a re-created receiver would leak a
    /// stale block still holding this instance's `[weak self]`.
    private nonisolated(unsafe) var pendingToken: NSObjectProtocol?
    private nonisolated(unsafe) var cancelToken: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        let center = darwinCenter
        let observer = Unmanaged.passUnretained(self).toOpaque()
        darwinObserver = observer
        // The C callbacks capture nothing; they re-post as Foundation notifications handled below.
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in
                NotificationCenter.default.post(name: .widgetBolusPending, object: nil)
            }, WidgetBolusStore.darwinPending as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in
                NotificationCenter.default.post(name: .widgetBolusCancel, object: nil)
            }, WidgetBolusStore.darwinCancel as CFString, nil, .deliverImmediately)

        pendingToken = NotificationCenter.default.addObserver(forName: .widgetBolusPending, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.handlePending() }
        }
        cancelToken = NotificationCenter.default.addObserver(forName: .widgetBolusCancel, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                // VA-28: only act on a cancel corroborated by the App-Group token the widget's own
                // cancel intent wrote (single-use + TTL-bounded). A bare/replayed Darwin post from a
                // co-resident app finds no token and is dropped.
                guard let model = self?.model, WidgetBolusStore.takeCancelIntent() else { return }
                Task { await model.cancelBolus(from: .quickBolusWidget, peerId: "widget") }
            }
        }
    }

    /// C6-02: tear down BOTH observer systems so a deallocated instance leaves nothing behind — no stale
    /// Darwin registration re-posting into a dead receiver, and no leaked block observer.
    deinit {
        CFNotificationCenterRemoveObserver(
            darwinCenter, darwinObserver,
            CFNotificationName(WidgetBolusStore.darwinPending as CFString), nil)
        CFNotificationCenterRemoveObserver(
            darwinCenter, darwinObserver,
            CFNotificationName(WidgetBolusStore.darwinCancel as CFString), nil)
        if let pendingToken { NotificationCenter.default.removeObserver(pendingToken) }
        if let cancelToken { NotificationCenter.default.removeObserver(cancelToken) }
    }

    private func reload() { WidgetCenter.shared.reloadTimelines(ofKind: "FaBolusQuickBolus") }

    /// Consume a pending widget bolus and deliver it, updating the widget's status as it goes.
    /// Called on the Darwin wake and again when the app becomes active (a suspended-app fallback).
    func handlePending() {
        guard let model, let r = WidgetBolusStore.takePending() else { return }
        Task {
            // Read-only is a local gate the widget must respect too (audit A-05).
            if AppSettings.shared.phoneReadOnly {
                WidgetBolusStore.setStatus(
                    WidgetBolusStatus(
                        phase: .failed, requestId: r.requestId,
                        message: "faBolus is read-only"))
                reload()
                return
            }
            if r.mode == "carbs" {
                // Audit C-03: the widget confirmed GRAMS, not units, and would dose off possibly-stale
                // glucose. A carb bolus must NOT deliver in place — stage a host-owned review that
                // freezes the real units (fresh CGM, fail-closed) and needs an in-app confirm.
                // `presentRemoteBolus` resolves + freezes; the widget tells the user to finish in-app.
                // FB-09: resolve the estimate off the SAME fresh, staleness-gated BG the host uses in
                // resolveRemoteDose (refresh first, then `freshCorrectionBG`) — otherwise the estimate
                // (previously off raw, possibly-stale `snapshot.glucose`) and the authoritative dose
                // diverge and the guard rejects with a confusing "dose changed" and no review to act on.
                await model.refreshGlucoseNow()
                let est = await model.recommendBolus(carbsGrams: r.amount, bgMgdl: model.freshCorrectionBG)
                    .recommendedUnits
                await model.presentRemoteBolus(
                    requestId: r.requestId, units: 0, carbsGrams: r.amount,
                    bgMgdl: nil, remoteEstimate: est, from: .quickBolusWidget, peerId: "widget")
                WidgetBolusStore.setStatus(
                    WidgetBolusStatus(
                        phase: .failed, requestId: r.requestId,
                        message: "Open faBolus to confirm the dose"))
                reload()
                return
            }
            // Units mode: an explicit unit amount the user set on the widget — deliver in place.
            let units = r.amount
            guard units > 0 else {
                WidgetBolusStore.setStatus(
                    WidgetBolusStatus(
                        phase: .failed, requestId: r.requestId,
                        message: "No insulin needed"))
                reload()
                return
            }
            // VA-26: only deliver in place for a live handoff (age ~0, the Darwin-woke path). A request
            // that only surfaced via a foreground fallback (app was suspended when confirmed) could be up
            // to ~2 min old — do NOT auto-dose it late by surprise. Convert it to a host-owned in-app
            // re-confirm, exactly like the carbs branch above.
            let age = Date().timeIntervalSince(r.createdAt)
            if age > WidgetBolusStore.promptTTL {
                await model.presentRemoteBolus(
                    requestId: r.requestId, units: units, carbsGrams: nil,
                    bgMgdl: nil, remoteEstimate: units, from: .quickBolusWidget, peerId: "widget")
                WidgetBolusStore.setStatus(
                    WidgetBolusStatus(
                        phase: .failed, requestId: r.requestId,
                        message: "Open faBolus to confirm the dose"))
                reload()
                return
            }
            WidgetBolusStore.setStatus(WidgetBolusStatus(phase: .delivering, units: units, requestId: r.requestId))
            reload()
            let out = await model.deliverWidgetBolus(requestId: r.requestId, units: units, carbsGrams: nil, bgMgdl: nil)
            let phase: WidgetBolusPhase = out.error != nil ? .failed : (out.cancelled ? .cancelled : .delivered)
            WidgetBolusStore.setStatus(
                WidgetBolusStatus(
                    phase: phase, units: units,
                    deliveredUnits: out.delivered, requestId: r.requestId,
                    message: out.error ?? ""))
            reload()
        }
    }
}
