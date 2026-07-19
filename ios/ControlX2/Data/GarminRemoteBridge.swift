import Foundation
import ConnectIQ

/// Bridges the Garmin venu3s (Connect IQ) remote to the iPhone host. Receives the watch app's
/// messages via the Connect IQ Mobile SDK, maps them to `RemoteCommand`, and routes them
/// through the same double-confirm flow as the Apple Watch (`AppModel`). Status is echoed back
/// to the watch. Requires the Garmin Connect Mobile app installed + the watch paired to it.
@MainActor
final class GarminRemoteBridge: NSObject {
    /// Custom URL scheme for the SDK's device-selection callback (see Info.plist CFBundleURLTypes).
    static let urlScheme = "controlx2ciq"
    /// Our Monkey C app's UUID from garmin/manifest.xml (a1b2c3d4e5f600112233445566778899).
    static let watchAppUUID = UUID(uuidString: "A1B2C3D4-E5F6-0011-2233-445566778899")!
    private static let deviceDefaultsKey = "garminSelectedDevice"

    private weak var model: AppModel?
    private var device: IQDevice?
    private var app: IQApp?

    init(model: AppModel) {
        self.model = model
        super.init()
        ConnectIQ.sharedInstance().initialize(withUrlScheme: Self.urlScheme, uiOverrideDelegate: nil)
        model.addRemoteEcho { [weak self] cmd in self?.send(cmd) }
        model.setupGarmin = { [weak self] in self?.selectDevice() }
        restoreDevice()
    }

    var hasDevice: Bool { device != nil }

    /// Opens Garmin Connect Mobile so the user can pick which paired device runs the remote.
    func selectDevice() { ConnectIQ.sharedInstance().showDeviceSelection() }

    /// Handle the SDK's device-selection callback URL (from `.onOpenURL`).
    func handleOpenURL(_ url: URL) {
        guard let devices = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice],
              let first = devices.first else { return }
        UserDefaults.standard.set([first.uuid.uuidString, first.modelName ?? "", first.friendlyName ?? ""],
                                  forKey: Self.deviceDefaultsKey)
        device = first
        registerApp()
    }

    private func restoreDevice() {
        guard let parts = UserDefaults.standard.array(forKey: Self.deviceDefaultsKey) as? [String],
              parts.count == 3, let uuid = UUID(uuidString: parts[0]) else { return }
        device = IQDevice(id: uuid, modelName: parts[1], friendlyName: parts[2])
        registerApp()
    }

    private func registerApp() {
        guard let device else { return }
        // Sideloaded app: store UUID == app UUID.
        let app = IQApp(uuid: Self.watchAppUUID, store: Self.watchAppUUID, device: device)
        self.app = app
        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
        ConnectIQ.sharedInstance().register(forAppMessages: app, delegate: self)
    }

    private func send(_ cmd: RemoteCommand) {
        guard let app, let dict = try? cmd.asDictionary() else { return }
        ConnectIQ.sharedInstance().sendMessage(dict, to: app, progress: nil, completion: { _ in })
    }

    private func handle(_ cmd: RemoteCommand) {
        guard let model else { return }
        switch cmd.kind {
        case .bolusRequest:
            guard let units = cmd.units else { return }
            model.presentRemoteBolus(requestId: cmd.requestId, units: units)
            send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId,
                               status: .awaitingConfirm, message: "Confirm on iPhone"))
        case .cancelBolus:
            Task { await model.cancelBolus() }
            send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId, status: .cancelled))
        case .statusRead:
            let s = model.snapshot
            send(RemoteCommand(kind: .statusRead, units: s.iobUnits,
                               bgMgdl: s.glucose.map(Double.init), message: s.connection.rawValue))
        default: break
        }
    }
}

// Connect IQ delegate callbacks (Obj-C, nonisolated) — hop onto the main actor.
extension GarminRemoteBridge: IQAppMessageDelegate, IQDeviceEventDelegate {
    nonisolated func receivedMessage(_ message: Any!, from app: IQApp!) {
        guard let dict = message as? [String: Any], let cmd = try? RemoteCommand.from(dict) else { return }
        Task { @MainActor in self.handle(cmd) }
    }
    nonisolated func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {}
}
