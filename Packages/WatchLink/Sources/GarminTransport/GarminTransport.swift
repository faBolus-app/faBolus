// The Connect IQ adapter under the watch link. It converts the iOS companion SDK's callbacks to link
// events and the link's effects to SDK calls, and keeps nothing but the SDK's handles: when to send, retry,
// probe or give up is the link's (WatchLink). The SDK is licensed separately and isn't in the repository,
// so this compiles only in an app build that has it (`canImport(ConnectIQ)`).

#if canImport(ConnectIQ)
import ConnectIQ
import Foundation
import RemoteProtocol
import WatchLink

@MainActor
public final class GarminTransport: NSObject, WatchTransport {
    /// The URL scheme Garmin Connect returns to after device selection (Info.plist `CFBundleURLTypes`).
    public static let urlScheme = "fabolusciq"
    private static let deviceKey = "garminSelectedDevice"

    private let appUUID: UUID
    private let defaults: UserDefaults
    private var handler: (@MainActor (WatchTransportEvent) -> Void)?
    private var device: IQDevice?
    private var app: IQApp?

    /// - Parameter appUUID: the watch app's ID; a sideloaded app's store ID is the same.
    public init(appUUID: UUID, defaults: UserDefaults = .standard) {
        self.appUUID = appUUID
        self.defaults = defaults
        super.init()
        // State restoration lets iOS relaunch the app in the background on Bluetooth activity from the
        // watch; the SDK leaves reconnecting to the app, which `start` does.
        ConnectIQ.sharedInstance().initialize(
            withUrlScheme: Self.urlScheme, uiOverrideDelegate: nil, stateRestorationIdentifier: "fabolus.connectiq")
    }

    public func start(_ handler: @escaping @MainActor (WatchTransportEvent) -> Void) {
        self.handler = handler
        restoreDevice()
    }

    /// Opens Garmin Connect so the user can pick the watch.
    public func selectDevice() { ConnectIQ.sharedInstance().showDeviceSelection() }

    /// Garmin Connect's device-selection callback (`.onOpenURL`).
    public func handleOpenURL(_ url: URL) {
        let devices = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice]
        guard let first = devices?.first else { return }
        // The part number too: the device Garmin Connect returned has one, and the SDK may use it.
        defaults.set(
            [first.uuid.uuidString, first.modelName ?? "", first.friendlyName ?? "", first.partNumber ?? ""],
            forKey: Self.deviceKey)
        // Another watch: nothing the link knows or queued for the last one applies to it.
        if device?.uuid != first.uuid {
            unregister()
            handler?(.paired(false))
        }
        device = first
        register()
    }

    public func forgetDevice() {
        unregister()
        device = nil
        app = nil
        defaults.removeObject(forKey: Self.deviceKey)
        handler?(.paired(false))
    }

    public var deviceName: String? { device?.friendlyName ?? device?.modelName }

    private func restoreDevice() {
        // Three parts were saved before the part number was.
        guard let parts = defaults.array(forKey: Self.deviceKey) as? [String], parts.count == 3 || parts.count == 4,
            let uuid = UUID(uuidString: parts[0])
        else {
            handler?(.paired(false))
            return
        }
        if parts.count == 4, !parts[3].isEmpty {
            device = IQDevice(id: uuid, modelName: parts[1], friendlyName: parts[2], partNumber: parts[3])
        } else {
            device = IQDevice(id: uuid, modelName: parts[1], friendlyName: parts[2])
        }
        register()
    }

    private func register() {
        unregister()
        guard let device, let app = IQApp(uuid: appUUID, store: appUUID, device: device) else {
            app = nil
            handler?(.paired(false))
            return
        }
        self.app = app
        handler?(.paired(true))
        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
        ConnectIQ.sharedInstance().register(forAppMessages: app, delegate: self)
        handler?(.deviceStatus(Self.status(ConnectIQ.sharedInstance().getDeviceStatus(device))))
    }

    /// Before registering again, so listeners never stack (ConnectIQ.h).
    private func unregister() {
        ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
        ConnectIQ.sharedInstance().unregister(forAllAppMessages: self)
    }

    public func reregister() { register() }

    public func transmit(_ message: WireValue, send: Int) {
        guard let app else {
            handler?(.sendCompleted(send: send, .transientFailure("no app handle")))
            return
        }
        ConnectIQ.sharedInstance().sendMessage(
            message.foundation, to: app,
            progress: { [weak self] _, _ in
                Task { @MainActor in self?.handler?(.sendProgress(send: send)) }
            },
            completion: { [weak self] result in
                let mapped = Self.result(result)
                Task { @MainActor in self?.handler?(.sendCompleted(send: send, mapped)) }
            })
    }

    public func probeAppStatus(probe: Int) {
        guard let app else {
            handler?(.appStatus(installed: nil, probe: probe))
            return
        }
        ConnectIQ.sharedInstance().getAppStatus(app) { [weak self] status in
            let installed = status?.isInstalled
            Task { @MainActor in self?.handler?(.appStatus(installed: installed, probe: probe)) }
        }
    }

    nonisolated static func result(_ result: IQSendMessageResult) -> WatchSendResult {
        switch result {
        case .success: return .delivered
        case .failure_AppNotFound: return .appNotFound
        case .failure_UnsupportedType: return .undeliverable("unsupported type")
        case .failure_InsufficientMemory: return .undeliverable("insufficient memory")
        default: return .transientFailure(NSStringFromSendMessageResult(result))
        }
    }

    nonisolated static func status(_ status: IQDeviceStatus) -> WatchDeviceStatus {
        switch status {
        case .connected: return .connected
        case .notConnected: return .notConnected
        case .bluetoothNotReady: return .bluetoothOff
        case .notFound: return .notFound
        case .invalidDevice: return .invalid
        @unknown default: return .unknown
        }
    }
}

// The SDK calls these off the main actor, and the hops can land out of order, so each reports the device's
// status as the SDK gives it when the hop lands rather than the one captured in the callback: a late
// "not connected" can't strand a watch that has since connected.
extension GarminTransport: IQDeviceEventDelegate, IQAppMessageDelegate {
    nonisolated public func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        Task { @MainActor in self.reportCurrentStatus(discovered: false) }
    }

    nonisolated public func deviceCharacteristicsDiscovered(_ device: IQDevice!) {
        Task { @MainActor in self.reportCurrentStatus(discovered: true) }
    }

    private func reportCurrentStatus(discovered: Bool) {
        guard let device else { return }
        let status = Self.status(ConnectIQ.sharedInstance().getDeviceStatus(device))
        handler?(.deviceStatus(status))
        if discovered && status == .connected { handler?(.characteristicsDiscovered) }
    }

    nonisolated public func receivedMessage(_ message: Any!, from app: IQApp!) {
        let wire = message.flatMap { try? WireValue(foundation: $0) }
        Task { @MainActor in self.handler?(wire.map(WatchTransportEvent.received) ?? .receivedUnreadable) }
    }
}
#endif
