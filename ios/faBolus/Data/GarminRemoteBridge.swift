import Foundation
import faBolusCore
#if GARMIN
import ConnectIQ

/// Bridges the Garmin venu3s (Connect IQ) remote to the iPhone host. Receives the watch app's
/// messages via the Connect IQ Mobile SDK, maps them to `RemoteCommand`, and routes them
/// through the same double-confirm flow as the Apple Watch (`AppModel`). Status is echoed back
/// to the watch. Requires the Garmin Connect Mobile app installed + the watch paired to it.
@MainActor
final class GarminRemoteBridge: NSObject {
    /// Custom URL scheme for the SDK's device-selection callback (see Info.plist CFBundleURLTypes).
    static let urlScheme = "fabolusciq"
    /// The two published Garmin apps (garmin/manifest.xml + manifest-official.xml). The developer
    /// panel picks which the phone pairs with (UserDefaults "garminTargetApp": beta|official).
    ///
    /// The BETA id is configurable: a self-compiler who builds their OWN private beta (the Connect IQ
    /// store requires a unique app id per beta listing — see faBolusGarmin/scripts/beta-build.sh) sets
    /// `GARMIN_BETA_APP_ID` in LocalConfig.xcconfig (→ Info.plist `GarminBetaAppID`) to the id that
    /// script prints, so the phone targets their beta app. Falls back to the shared default.
    /// The shared/published beta id (used when no personal beta id was configured).
    static let sharedBetaAppUUID = UUID(uuidString: "A1B2C3D4-E5F6-0011-2233-445566778899")!
    static let betaAppUUID: UUID = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "GarminBetaAppID") as? String,
           let id = UUID(uuidString: s.trimmingCharacters(in: .whitespaces)) { return id }
        return sharedBetaAppUUID
    }()
    static let officialAppUUID = UUID(uuidString: "DED131EC-B69D-4649-3650-153AEF623BE6")!
    /// The currently-targeted app UUID. Read from UserDefaults (not the MainActor AppSettings).
    /// **Default is BETA** — the official store listing is dormant for now, so beta is the live app
    /// (a personal beta id if one was configured, else the shared beta). Official is opt-in only, via
    /// the debug panel.
    static var watchAppUUID: UUID {
        UserDefaults.standard.string(forKey: "garminTargetApp") == "official" ? officialAppUUID : betaAppUUID
    }
    private static let deviceDefaultsKey = "garminSelectedDevice"

    private weak var model: AppModel?
    private var device: IQDevice?
    private var app: IQApp?

    // Connect IQ's sendMessage is serial + asynchronous: firing another before the last completes
    // backs up a queue, so the watch replays stale status and a bolus's terminal echo gets stuck
    // behind it. We keep at most ONE send in flight, coalesce status pushes (only the latest matters),
    // and never drop command echoes (bolus outcome, etc.) — echoes are sent first.
    private var sendInFlight = false
    private var pendingStatus: [String: Any]?     // latest coalesced statusRead payload
    private var echoQueue: [[String: Any]] = []   // ordered command echoes; never coalesced/dropped

    init(model: AppModel) {
        self.model = model
        super.init()
        ConnectIQ.sharedInstance().initialize(withUrlScheme: Self.urlScheme, uiOverrideDelegate: nil)
        model.addRemoteEcho { [weak self] cmd in self?.send(cmd) }
        // Proactively push status to the watch when pump data changes (prompt refresh while open).
        model.addStatusListener { [weak self] snap in self?.sendStatus(snap) }
        model.setupGarmin = { [weak self] in self?.selectDevice() }
        // Phone tells the watch when to run wrist eating-sensing (battery: only when wanted).
        model.onWantAccelSensing = { [weak self] on in
            self?.sendRaw(["v": 1, "type": "eating_sense", "on": on])
        }
        restoreDevice()
    }

    var hasDevice: Bool { device != nil }

    /// Opens Garmin Connect Mobile so the user can pick which paired device runs the remote.
    func selectDevice() {
        model?.garminStatus = "Opening Garmin Connect — pick your venu3s, then return to faBolus…"
        ConnectIQ.sharedInstance().showDeviceSelection()
    }

    /// Handle the SDK's device-selection callback URL (from `.onOpenURL`).
    func handleOpenURL(_ url: URL) {
        let devices = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice]
        guard let first = devices?.first else {
            model?.garminStatus = "Garmin returned no device (callback URL had no devices)."
            return
        }
        UserDefaults.standard.set([first.uuid.uuidString, first.modelName ?? "", first.friendlyName ?? ""],
                                  forKey: Self.deviceDefaultsKey)
        device = first
        registerApp()
        model?.garminStatus = "Garmin remote: \(first.friendlyName ?? first.modelName ?? "device") ✓"
    }

    private func restoreDevice() {
        guard let parts = UserDefaults.standard.array(forKey: Self.deviceDefaultsKey) as? [String],
              parts.count == 3, let uuid = UUID(uuidString: parts[0]) else { return }
        device = IQDevice(id: uuid, modelName: parts[1], friendlyName: parts[2])
        registerApp()
        model?.garminStatus = "Garmin remote: \(parts[2].isEmpty ? parts[1] : parts[2])"
    }

    private func registerApp() {
        guard let device else { return }
        // Sideloaded app: store UUID == app UUID.
        let app = IQApp(uuid: Self.watchAppUUID, store: Self.watchAppUUID, device: device)
        self.app = app
        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
        ConnectIQ.sharedInstance().register(forAppMessages: app, delegate: self)
    }

    /// Enqueue a command for the watch. Status pushes are coalesced (latest wins); everything else
    /// (bolus echoes, etc.) is queued in order and sent first, so a stale backlog can't delay a
    /// bolus's "delivered"/"cancelled" outcome or make the CGM lag behind the phone.
    private func send(_ cmd: RemoteCommand) {
        guard let dict = try? cmd.asDictionary() else { return }
        if cmd.kind == .statusRead {
            pendingStatus = dict
        } else {
            echoQueue.append(dict)
        }
        pump()
    }

    /// Send an out-of-band control dict (e.g. eating_sense) to the watch — queued like an echo so it
    /// respects the single-in-flight discipline. Not a RemoteCommand (no safety-critical schema).
    private func sendRaw(_ dict: [String: Any]) {
        echoQueue.append(dict)
        pump()
    }

    private func pump() {
        guard let app, !sendInFlight else { return }
        let next: [String: Any]
        if !echoQueue.isEmpty {
            next = echoQueue.removeFirst()
        } else if let status = pendingStatus {
            next = status; pendingStatus = nil
        } else {
            return
        }
        sendInFlight = true
        ConnectIQ.sharedInstance().sendMessage(next, to: app, progress: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sendInFlight = false
                self.pump()   // drain the next queued message (echo first, else the latest status)
            }
        }
    }

    private func handle(_ cmd: RemoteCommand) {
        guard let model else { return }
        switch cmd.kind {
        case .bolusRequest:
            // The watch already confirmed via hold-to-deliver — deliver directly, no phone
            // dialog. The pump still enforces max + signing. Blocked when Garmin is read-only.
            guard !AppSettings.shared.remotesReadOnly else {
                send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId, status: .failed, message: "Read-only mode"))
                return
            }
            // Units mode sends `units`; carbs mode sends `carbsGrams` (+ bgMgdl + the Garmin's own
            // estimate). The host recomputes carbs→units, runs the divergence guard, records carbs.
            guard cmd.units != nil || (cmd.carbsGrams ?? 0) > 0 else { return }
            Task { await model.remoteDeliver(requestId: cmd.requestId, units: cmd.units,
                                             carbsGrams: cmd.carbsGrams, bgMgdl: cmd.bgMgdl.map(Int.init),
                                             remoteEstimate: cmd.remoteEstimateUnits, peerId: "garmin") }
        case .cancelBolus:
            // Just request the cancel; the in-flight delivery loop echoes the single final
            // status (cancelled · partial, or delivered if it finished first). No echo here, or
            // the watch would flip cancelled → delivered.
            Task { await model.cancelBolus() }
        case .dismissAlert:
            if let id = cmd.alertId, let k = cmd.alertKind {
                Task { await model.dismissAlert(id: id, kind: k); send(model.statusCommand(includeHistory: true)) }
            }
        case .statusRead:
            if cmd.forceGlucose == true {
                Task { await model.refreshGlucoseNow(); self.send(model.statusCommand(includeHistory: true)) }
            } else {
                send(model.statusCommand(includeHistory: true))
            }
        default: break
        }
    }

    /// Send the full status (reply or proactive push). History included for the watch plot.
    private func sendStatus(_ s: PumpSnapshot) {
        if let model { send(model.statusCommand(includeHistory: true)) }
    }
}

// Connect IQ delegate callbacks (Obj-C, nonisolated) — hop onto the main actor.
extension GarminRemoteBridge: IQAppMessageDelegate, IQDeviceEventDelegate {
    nonisolated func receivedMessage(_ message: Any!, from app: IQApp!) {
        guard let dict = message as? [String: Any] else { return }
        // Eating-detection IMU windows ride an out-of-band envelope (not the safety-critical
        // RemoteCommand schema) — route them to phone-side inference before RemoteCommand parsing.
        if dict["type"] as? String == "imu_window" {
            let raw = (dict["data"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
            Task { @MainActor in self.model?.ingestGarminIMUWindow(rawWindow: raw) }
            return
        }
        guard let cmd = try? RemoteCommand.fromValidated(dict) else { return }   // audit A-07
        Task { @MainActor in self.handle(cmd) }
    }
    nonisolated func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {}
}

#else

/// Stub used when the app is built **without** the Garmin Connect IQ SDK (the `GARMIN` compile flag is
/// off because the SDK wasn't present at build time — see `scripts/generate-project.sh`). The Garmin
/// remote is unavailable; the Remotes & devices screen shows why. Keeps the same surface `App` uses
/// (`init(model:)` + `handleOpenURL(_:)`) so nothing else changes.
@MainActor
final class GarminRemoteBridge {
    init(model: AppModel) { model.garminStatus = nil }
    func handleOpenURL(_ url: URL) {}
}

#endif
