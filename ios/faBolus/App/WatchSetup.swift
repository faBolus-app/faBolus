import Foundation
import PhoneApp
import WatchLink

/// The watch's transport and the setup actions that are Garmin's own (choosing the watch in Garmin
/// Connect, the store page). `nil` in a build without Garmin's SDK.
@MainActor
final class WatchSetup {
    let transport: any WatchTransport
    #if GARMIN
    private let garmin: GarminTransport
    #endif

    static func make() -> WatchSetup? {
        #if GARMIN
        return WatchSetup()
        #else
        return nil
        #endif
    }

    #if GARMIN
    private init() {
        garmin = GarminTransport(appUUID: Self.watchAppUUID)
        transport = garmin
    }
    #endif

    /// The Connect IQ app the phone talks to: the beta listing (a self-builder's own, from
    /// `GARMIN_BETA_APP_ID`) or the store one. Read at launch; a change applies on the next launch.
    static var watchAppUUID: UUID {
        let app = UserDefaults.standard.string(forKey: AppSettings.Key.garminApp.rawValue)
        if app == AppSettings.GarminApp.store.rawValue { return storeAppUUID }
        let beta = (Bundle.main.object(forInfoDictionaryKey: "GarminBetaAppID") as? String)
            .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
        return beta ?? sharedBetaAppUUID
    }

    static let sharedBetaAppUUID = UUID(uuidString: "A1B2C3D4-E5F6-0011-2233-445566778899")!
    static let storeAppUUID = UUID(uuidString: "DED131EC-B69D-4649-3650-153AEF623BE6")!

    var deviceName: String? {
        #if GARMIN
        garmin.deviceName
        #else
        nil
        #endif
    }

    func selectDevice() {
        #if GARMIN
        garmin.selectDevice()
        #endif
    }

    func forgetDevice() {
        #if GARMIN
        garmin.forgetDevice()
        #endif
    }

    func openStore() {
        #if GARMIN
        garmin.openStore()
        #endif
    }

    func handleOpenURL(_ url: URL) {
        #if GARMIN
        garmin.handleOpenURL(url)
        #endif
    }
}
