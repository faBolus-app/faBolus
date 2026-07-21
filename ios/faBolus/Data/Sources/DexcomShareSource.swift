import Foundation
import faBolusCore

/// Dexcom Share follower — **last resort** for Dexcom (G6 has no free BLE slot; Share is the only
/// independent feed, and it is notoriously flaky). The official Dexcom app must have Share enabled
/// and uploading. Config: `dexcomshare.username` + `dexcomshare.region` (UserDefaults),
/// `dexcomshare.password` (Keychain). Uses the unofficial `share2` endpoints. Read-only.
@MainActor
final class DexcomShareSource: PollingGlucoseSource {
    /// Well-known Dexcom Share application id (same value every community client uses).
    private static let appId = "d89443d2-327c-4a6f-89e5-496bbb0317db"
    private var sessionId: String?

    init() { super.init(id: "dexcom-share", priority: 20) }

    private func base() -> String {
        GlucoseSourceConfig.string("dexcomshare.region") == "ous"
            ? "https://shareous1.dexcom.com" : "https://share2.dexcom.com"
    }

    override func poll() async throws -> [GlucoseSample] {
        guard let user = GlucoseSourceConfig.string("dexcomshare.username"),
              let pass = CredentialStore.get(account: "dexcomshare.password") else {
            throw SourceError.needsSetup("Dexcom Share")
        }
        if sessionId == nil { try await login(user: user, pass: pass) }
        do {
            return try await readValues()
        } catch {
            sessionId = nil                                   // session likely expired — re-login once
            try await login(user: user, pass: pass)
            return try await readValues()
        }
    }

    private func login(user: String, pass: String) async throws {
        let accountId: String = try await postString(
            "General/AuthenticatePublisherAccount",
            ["accountName": user, "password": pass, "applicationId": Self.appId])
        sessionId = try await postString(
            "General/LoginPublisherAccountById",
            ["accountId": accountId, "password": pass, "applicationId": Self.appId])
    }

    private struct Reading: Decodable {
        let Value: Int
        let WT: String
        let Trend: TrendValue
    }
    /// `Trend` is a number on the old API and a string on the newer one.
    private enum TrendValue: Decodable {
        case int(Int), string(String)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i) }
            else { self = .string((try? c.decode(String.self)) ?? "Flat") }
        }
        var trend: GlucoseTrend {
            switch self { case .int(let i): return CgmTrend.dexcom(i)
                          case .string(let s): return CgmTrend.dexcom(name: s) }
        }
    }

    private func readValues() async throws -> [GlucoseSample] {
        guard let sid = sessionId else { throw SourceError.badResponse }
        var comps = URLComponents(string: base() + "/ShareWebServices/Services/Publisher/ReadPublisherLatestGlucoseValues")!
        comps.queryItems = [
            URLQueryItem(name: "sessionId", value: sid),
            URLQueryItem(name: "minutes", value: "1440"),
            URLQueryItem(name: "maxCount", value: "48"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let readings = try JSONDecoder().decode([Reading].self, from: data)
        return readings.compactMap { r in
            guard r.Value > 0, let date = CgmTrend.dotNetDate(r.WT) else { return nil }
            return GlucoseSample(mgdl: r.Value, date: date, trend: r.Trend.trend, sourceID: id)
        }
    }

    /// POST a JSON body to a Share `General/*` endpoint and decode the bare-string (GUID) reply.
    private func postString(_ path: String, _ body: [String: String]) async throws -> String {
        var req = URLRequest(url: URL(string: base() + "/ShareWebServices/Services/" + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let s = try JSONDecoder().decode(String.self, from: data)
        guard s != "00000000-0000-0000-0000-000000000000" else { throw SourceError.badResponse }
        return s
    }
}
