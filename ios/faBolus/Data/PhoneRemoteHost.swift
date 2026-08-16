import Foundation
import faBolusCore

/// iPhone-side receiver for remote (watch/Garmin) commands. The remote confirms on-device (a
/// hold-to-deliver gesture); this host does **not** show a separate phone confirm dialog for a
/// watch/Garmin `bolusRequest`. Instead the phone is the single calculator — `remoteDeliver`
/// recomputes carbs→units, runs the divergence guard against the remote's own estimate, records
/// carbs on the pump, and delivers. Status is echoed back to the remote. (The explicit phone-side
/// approval dialog is the *peer*/parent-remote path in `PeerRemoteHost`, not this one.)
@MainActor
public final class PhoneRemoteHost {
    private let link = RemoteLink()
    private weak var model: AppModel?

    /// Phase 09.6-05 (Part C-3a, D-03.3): app-wide weak reference so `WCDiagnostics`/`DebugMenuView`
    /// can read this host's already-tracked WatchConnectivity state without an init-signature
    /// change — mirrors `GarminRemoteBridge.shared`'s 09.6-04 precedent: `App.swift` constructs this
    /// instance-scoped `@State`, and `DebugMenuView`'s declared `files_modified` doesn't include
    /// `App.swift`, so a live reference can't be threaded through an init parameter without an
    /// out-of-scope call-site change.
    static weak var shared: PhoneRemoteHost?

    /// Read-only diagnostics counters (Phase 09.6-05, D-03.3) — how many outbound sends this host has
    /// attempted, and how many the transport reported undeliverable via `onUndeliverable`. Purely
    /// observational: neither counter gates any send decision or gets reset except by app relaunch.
    private(set) var sentCountForDiagnostics = 0
    private(set) var undeliverableCountForDiagnostics = 0
    /// The transport's live reachability (`RemoteLink.isReachable`, WCSession-backed) — read directly,
    /// never re-derived.
    var reachableForDiagnostics: Bool { link.isReachable }

    public init(model: AppModel) {
        self.model = model
        Self.shared = self
        link.onReceive = { [weak self] cmd in self?.handle(cmd) }
        // Read-only diagnostics accessor (Phase 09.6-05): the existing `onUndeliverable` seam already
        // fires exactly when a pump-mutating send couldn't be handed to the peer (RemoteSendDisposition,
        // never a new WC round-trip) — just counted here, never acted on differently than before.
        link.onUndeliverable = { [weak self] _ in self?.undeliverableCountForDiagnostics += 1 }
        model.addRemoteEcho { [weak self] cmd in self?.sendTracked(cmd) }
        // Proactively push status (with history for the watch chart) when pump data changes.
        model.addStatusListener { [weak self] _ in
            guard let self, let m = self.model else { return }
            self.sendTracked(m.statusCommand(includeHistory: true))
        }
    }

    /// Every outbound send from this host funnels through here so `sentCountForDiagnostics` reflects
    /// every attempt — a thin counting wrapper around `link.send`, no behavior change.
    private func sendTracked(_ cmd: RemoteCommand) {
        sentCountForDiagnostics += 1
        link.send(cmd)
    }

    private func handle(_ cmd: RemoteCommand) {
        guard let model else { return }
        // Group B (P11): refuse a delivery-authorizing command that arrived too long after it was composed —
        // a bolus/resume/approval applied minutes late is a double-dose hazard. Only insulin-INCREASING kinds
        // are gated (see RemoteCommandFreshness); a late cancel/suspend is still honored (safe direction).
        if RemoteCommandFreshness.isStale(cmd) {
            sendTracked(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId,
                                    status: .failed, message: RemoteCommandFreshness.rejectionMessage))
            return
        }
        switch cmd.kind {
        case .bolusRequest:
            guard !AppSettings.shared.remotesReadOnly else {
                sendTracked(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId,
                                        status: .failed, message: "Read-only mode"))
                return
            }
            // The Apple Watch confirms on-device (hold-to-deliver), like the Garmin. The host is the
            // single calculator: `remoteDeliver` recomputes carbs→units, runs the divergence guard vs
            // the watch's own estimate, records carbs on the pump, and echoes the outcome.
            Task {
                await model.remoteDeliver(requestId: cmd.requestId, units: cmd.units,
                                          carbsGrams: cmd.carbsGrams, bgMgdl: cmd.bgMgdl.map(Int.init),
                                          remoteEstimate: cmd.remoteEstimateUnits,
                                          includeStaleBG: cmd.includeStaleBG ?? false,
                                          from: .appleWatch, peerId: "watch")
            }
        case .cancelBolus:
            // The in-flight delivery loop echoes the single final status; no echo here (else the
            // watch would flip cancelled → delivered when the bolus finishes first).
            Task { await model.cancelBolus(from: .appleWatch, peerId: "watch") }
        case .dismissAlert:
            if let id = cmd.alertId, let k = cmd.alertKind {
                Task { await model.dismissAlert(id: id, kind: k, from: .appleWatch, peerId: "watch"); self.sendTracked(model.statusCommand(includeHistory: true)) }
            }
        case .statusRead:
            if cmd.forceGlucose == true {
                Task { await model.refreshGlucoseNow(); self.sendTracked(model.statusCommand(includeHistory: true)) }
            } else {
                sendTracked(model.statusCommand(includeHistory: true))
            }
        case .eatingEvent:
            // Apple Watch on-device detector relayed a p(eating) — feed the fusion engine. Advisory.
            if let p = cmd.eatingProb { model.ingestWatchEatingEvent(prob: p) }
        case .suspendPump:
            guard !AppSettings.shared.remotesReadOnly else { return }
            model.requestRemoteControl(requestId: cmd.requestId, action: .suspend)
        case .resumePump:
            guard !AppSettings.shared.remotesReadOnly else { return }
            model.requestRemoteControl(requestId: cmd.requestId, action: .resume)
        default:
            break
        }
    }
}
