import Foundation
import PhoneApp
import WatchLink

/// The watch's transport and the setup actions that are Garmin's own (choosing the watch in Garmin
/// Connect). `nil` in a build without Garmin's SDK.
@MainActor
final class WatchSetup {
    let transport: any WatchTransport
    #if GARMIN
    private let garmin: GarminTransport
    #endif

    static func make() -> WatchSetup? { WatchSetup() }

    #if GARMIN
    private init() {
        garmin = GarminTransport(appUUID: Self.watchAppUUID)
        transport = garmin
    }
    #else
    private init?() { nil }
    #endif

    /// The Connect IQ app the phone talks to: `GARMIN_BETA_APP_ID`, which the build writes into Info.plist
    /// (a self-builder's private beta, or the watch app's own id).
    static var watchAppUUID: UUID {
        let beta = (Bundle.main.object(forInfoDictionaryKey: "GarminBetaAppID") as? String)
            .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
        return beta ?? defaultAppUUID
    }

    static let defaultAppUUID = UUID(uuidString: "A1B2C3D4-E5F6-0011-2233-445566778899")!

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

    func handleOpenURL(_ url: URL) {
        #if GARMIN
        garmin.handleOpenURL(url)
        #endif
    }
}
