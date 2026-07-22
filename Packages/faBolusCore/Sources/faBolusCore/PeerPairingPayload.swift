import Foundation

/// The contents of a pairing QR code shown by the host phone and scanned by a remote (parent iPhone
/// or Mac). It carries the host's BLE display name (so the remote can auto-select the right peer) and
/// the one-time pairing code (which the remote feeds into the same `MacPairing` HMAC handshake used by
/// manual entry). Encoded as a URL so a scanned string is unambiguous:
/// `fabolus-pair://v1?host=<pct>&code=<pct>`.
public struct PeerPairingPayload: Equatable, Sendable {
    public static let scheme = "fabolus-pair"
    public var hostName: String
    public var code: String

    public init(hostName: String, code: String) {
        self.hostName = hostName
        self.code = code
    }

    /// The QR string to render on the host.
    public func qrString() -> String {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "v1"
        c.queryItems = [URLQueryItem(name: "host", value: hostName),
                        URLQueryItem(name: "code", value: code)]
        return c.url?.absoluteString ?? ""
    }

    /// Parse a scanned string; nil if it isn't a valid faBolus pairing QR.
    public init?(qrString: String) {
        guard let c = URLComponents(string: qrString), c.scheme == Self.scheme,
              let items = c.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { return nil }
        self.hostName = host
        self.code = code
    }
}
