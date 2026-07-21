import Foundation
import CryptoKit
import faBolusCore

/// Uploads glucose **entries**, bolus **treatments**, and pump **devicestatus** to a Nightscout site
/// (opt-in, default off — it publishes health data off-device). Reuses the follower's config keys:
/// `nightscout.url` (UserDefaults) + optional `nightscout.token` / `nightscout.apisecret` (Keychain).
///
/// It is deliberately conservative: it de-dupes by timestamp (never re-posts a reading/bolus it has
/// already sent) and throttles device status, so calling `sync(...)` on every refresh is cheap.
@MainActor
final class NightscoutUploader {
    static let shared = NightscoutUploader()

    private let d = UserDefaults.standard
    private var inFlight = false
    private var lastSync = Date.distantPast
    private static let device = "faBolus"
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// High-water marks so we only ever upload new data (persisted so restarts don't re-post).
    private var lastEntryMs: Double {
        get { d.double(forKey: "ns.lastEntryMs") } set { d.set(newValue, forKey: "ns.lastEntryMs") }
    }
    private var lastBolusEpoch: Double {
        get { d.double(forKey: "ns.lastBolusEpoch") } set { d.set(newValue, forKey: "ns.lastBolusEpoch") }
    }
    private var lastStatus: Date {
        get { Date(timeIntervalSince1970: d.double(forKey: "ns.lastStatus")) }
        set { d.set(newValue.timeIntervalSince1970, forKey: "ns.lastStatus") }
    }

    /// Normalized site root (no trailing slash), or nil when unconfigured.
    private func base() -> String? {
        guard let raw = GlucoseSourceConfig.string("nightscout.url") else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// Kick off an upload if enabled and configured. Fire-and-forget; safe to call every refresh.
    func sync(snapshot: PumpSnapshot, glucose: [GlucoseReading], boluses: [BolusMarker]) {
        guard AppSettings.shared.nightscoutUploadEnabled, base() != nil, !inFlight else { return }
        // Overall throttle: at most once per 60 s (device status is throttled harder below).
        guard Date().timeIntervalSince(lastSync) >= 60 else { return }
        lastSync = Date()
        inFlight = true
        Task { [weak self] in
            await self?.run(snapshot: snapshot, glucose: glucose, boluses: boluses)
            self?.inFlight = false
        }
    }

    private func run(snapshot: PumpSnapshot, glucose: [GlucoseReading], boluses: [BolusMarker]) async {
        guard let base = base() else { return }

        // 1) Entries (sgv) newer than the high-water mark.
        let newEntries = glucose.filter { $0.date.timeIntervalSince1970 * 1000 > lastEntryMs }
        if !newEntries.isEmpty {
            let payload = newEntries.map { r -> [String: Any] in
                let ms = r.date.timeIntervalSince1970 * 1000
                return ["type": "sgv", "sgv": r.mgdl, "date": ms,
                        "dateString": iso.string(from: r.date), "device": Self.device]
            }
            if await post(base: base, path: "/api/v1/entries", body: payload) {
                lastEntryMs = newEntries.map { $0.date.timeIntervalSince1970 * 1000 }.max() ?? lastEntryMs
            }
        }

        // 2) Treatments — boluses newer than the high-water mark.
        let newBoluses = boluses.filter { $0.date.timeIntervalSince1970 > lastBolusEpoch }
        if !newBoluses.isEmpty {
            let payload = newBoluses.map { b -> [String: Any] in
                ["eventType": "Bolus", "insulin": b.units,
                 "created_at": iso.string(from: b.date), "enteredBy": Self.device]
            }
            if await post(base: base, path: "/api/v1/treatments", body: payload) {
                lastBolusEpoch = newBoluses.map { $0.date.timeIntervalSince1970 }.max() ?? lastBolusEpoch
            }
        }

        // 3) Device status — throttled to every ~5 min.
        if Date().timeIntervalSince(lastStatus) >= 5 * 60 {
            let pump: [String: Any] = [
                "clock": iso.string(from: Date()),
                "iob": ["iob": snapshot.iobUnits],
                "reservoir": snapshot.reservoirUnits,
                "battery": ["percent": snapshot.batteryPercent],
            ]
            let status: [String: Any] = ["device": Self.device, "created_at": iso.string(from: Date()), "pump": pump]
            if await post(base: base, path: "/api/v1/devicestatus", body: [status]) {
                lastStatus = Date()
            }
        }
    }

    /// POST a JSON array to a Nightscout endpoint. Auth via api-secret (SHA-1 hex) if present, else a
    /// `token` query param. Returns whether the server accepted it (2xx).
    private func post(base: String, path: String, body: [[String: Any]]) async -> Bool {
        guard var comps = URLComponents(string: base + path) else { return false }
        let apiSecret = CredentialStore.get(account: "nightscout.apisecret")
        if apiSecret == nil, let token = CredentialStore.get(account: "nightscout.token") {
            comps.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        guard let url = comps.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret = apiSecret {
            req.setValue(Self.sha1Hex(secret), forHTTPHeaderField: "api-secret")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard req.httpBody != nil else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return false
        }
    }

    private static func sha1Hex(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
