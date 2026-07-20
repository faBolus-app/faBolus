import Foundation
import CryptoKit
import faBolusCore

/// FreeStyle Libre 2/3 follower via the unofficial **LibreLinkUp** API — the only independent feed
/// while the official LibreLink app owns the sensor's single BLE connection. The user must share
/// with a LibreLinkUp follower account. Config: `librelinkup.username` + optional
/// `librelinkup.region` (UserDefaults), `librelinkup.password` (Keychain). Read-only.
///
/// Ported from the community `nightscout-librelink-up` / `libre-link-unofficial-api` clients.
@MainActor
final class LibreLinkUpSource: PollingGlucoseSource {
    init() { super.init(id: "librelinkup", priority: 25) }

    private var host = "https://api.libreview.io"
    private var token: String?
    private var accountId: String?     // SHA-256 hex of the user id (required header on newer API)
    private var patientId: String?

    override func poll() async throws -> [GlucoseSample] {
        guard let user = GlucoseSourceConfig.string("librelinkup.username"),
              let pass = CredentialStore.get(account: "librelinkup.password") else {
            throw SourceError.needsSetup("LibreLinkUp")
        }
        if let region = GlucoseSourceConfig.string("librelinkup.region") {
            host = "https://api-\(region).libreview.io"
        }
        if token == nil { try await login(user: user, pass: pass) }
        do { return try await readGraph() }
        catch { token = nil; try await login(user: user, pass: pass); return try await readGraph() }
    }

    // MARK: Auth

    private struct LoginResp: Decodable {
        struct DataObj: Decodable {
            struct Ticket: Decodable { let token: String }
            struct User: Decodable { let id: String }
            let authTicket: Ticket?
            let user: User?
            let redirect: Bool?
            let region: String?
        }
        let data: DataObj?
    }

    private func login(user: String, pass: String) async throws {
        let resp: LoginResp = try await postJSON("/llu/auth/login",
                                                 ["email": user, "password": pass], auth: false)
        // Region redirect: re-login against the account's regional host.
        if resp.data?.redirect == true, let region = resp.data?.region {
            host = "https://api-\(region).libreview.io"
            GlucoseSourceConfig.set(region, "librelinkup.region")
            let retry: LoginResp = try await postJSON("/llu/auth/login",
                                                      ["email": user, "password": pass], auth: false)
            try apply(retry)
            return
        }
        try apply(resp)
    }

    private func apply(_ resp: LoginResp) throws {
        guard let t = resp.data?.authTicket?.token, let uid = resp.data?.user?.id else {
            throw SourceError.badResponse
        }
        token = t
        accountId = SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reads

    private struct ConnectionsResp: Decodable {
        struct Conn: Decodable { let patientId: String }
        let data: [Conn]
    }
    private struct GraphResp: Decodable {
        struct DataObj: Decodable {
            struct Connection: Decodable { let glucoseMeasurement: Measurement? }
            struct Measurement: Decodable {
                let ValueInMgPerDl: Int
                let FactoryTimestamp: String
                let TrendArrow: Int?
            }
            let connection: Connection?
            let graphData: [Measurement]?
        }
        let data: DataObj?
    }

    private func readGraph() async throws -> [GlucoseSample] {
        if patientId == nil {
            let conns: ConnectionsResp = try await getJSON("/llu/connections")
            patientId = conns.data.first?.patientId
        }
        guard let pid = patientId else { throw SourceError.badResponse }
        let graph: GraphResp = try await getJSON("/llu/connections/\(pid)/graph")

        var samples: [GlucoseSample] = []
        if let m = graph.data?.connection?.glucoseMeasurement, let d = parseUTC(m.FactoryTimestamp) {
            samples.append(GlucoseSample(mgdl: m.ValueInMgPerDl, date: d,
                                         trend: CgmTrend.libre(m.TrendArrow ?? 3), sourceID: id))
        }
        for m in graph.data?.graphData ?? [] {
            if let d = parseUTC(m.FactoryTimestamp) {
                samples.append(GlucoseSample(mgdl: m.ValueInMgPerDl, date: d,
                                             trend: CgmTrend.libre(m.TrendArrow ?? 3), sourceID: id))
            }
        }
        if samples.isEmpty { throw SourceError.badResponse }
        return samples
    }

    // MARK: HTTP

    private func headers(auth: Bool) -> [String: String] {
        var h = ["cache-control": "no-cache", "connection": "Keep-Alive",
                 "content-type": "application/json", "product": "llu.ios",
                 "version": "4.12.0", "User-Agent": "Mozilla/5.0"]
        if auth { if let token { h["authorization"] = "Bearer \(token)" }
                  if let accountId { h["account-id"] = accountId } }
        return h
    }

    private func postJSON<T: Decodable>(_ path: String, _ body: [String: String], auth: Bool) async throws -> T {
        var req = URLRequest(url: URL(string: host + path)!)
        req.httpMethod = "POST"
        headers(auth: auth).forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func getJSON<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: URL(string: host + path)!)
        headers(auth: true).forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SourceError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// LibreLinkUp `FactoryTimestamp` is UTC, formatted "M/d/yyyy h:mm:ss a".
    private func parseUTC(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "M/d/yyyy h:mm:ss a"
        return f.date(from: s)
    }
}
