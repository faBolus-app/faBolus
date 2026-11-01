import Foundation

/// Why a glucose source isn't delivering readings, in terms the user can act on. A source that can't
/// read must say why rather than sit silently on "searching".
public enum GlucoseSourceProblem: Sendable, Equatable {
    case bluetoothOff
    /// The user hasn't allowed Bluetooth for the app.
    case bluetoothNotAllowed
    case bluetoothUnsupported
    /// No matching transmitter or sensor has connected for longer than a few of its 5-minute cycles.
    case sensorNotFound
    /// The phone reached the transmitter, but the Dexcom app never signed in to it. Direct Bluetooth
    /// only reads alongside the Dexcom app, which must be installed, running and showing readings.
    case dexcomAppNotConnected
    /// The sensor reports no reading it stands behind yet (warm-up, a sensor error, no session).
    case sensorNotReady(String)
    case connectionFailed(String)
    /// The account was refused: wrong username or password, or Dexcom locked the account.
    case signInFailed(String)
    case network(String)

    /// One sentence for the source's status line.
    public var message: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off."
        case .bluetoothNotAllowed: return "Bluetooth isn't allowed for faBolus. Turn it on in Settings."
        case .bluetoothUnsupported: return "This device doesn't support Bluetooth LE."
        case .sensorNotFound:
            return "No Dexcom transmitter found nearby. Check the transmitter ID and that the sensor is in range."
        case .dexcomAppNotConnected:
            return "The Dexcom app isn't connected to the transmitter. Open the Dexcom app and check it shows readings."
        case .sensorNotReady(let detail): return "The sensor isn't giving readings yet (\(detail))."
        case .connectionFailed(let detail): return "Couldn't connect to the transmitter: \(detail)"
        case .signInFailed(let detail): return "Dexcom Share sign-in failed: \(detail)"
        case .network(let detail): return "Couldn't reach Dexcom Share: \(detail)"
        }
    }
}
