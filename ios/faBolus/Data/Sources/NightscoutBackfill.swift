import Foundation

/// Pulls Nightscout **treatments** (carbs + insulin) and the **profile** (basal schedule) into faBolus,
/// complementing `NightscoutSource` (which handles glucose). Uses the same site URL + optional token.
/// Read-only. The results feed `HistoryStore` (carbs/insulin) and the cached basal schedule
/// (settings-advice / autotune). See MIGRATION.md Phase 4 follow-on.
enum NightscoutBackfill {
    struct Result {
        var carbs: [(date: Date, grams: Double)] = []
        var insulin: [(date: Date, units: Double)] = []
        var basalByHour: [Double]?     // 24 hourly U/hr, if the profile had a basal schedule
    }

    static func fetch(days: Int = 30) async -> Result? {
        guard let base = GlucoseSourceConfig.string("nightscout.url") else { return nil }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        let token = CredentialStore.get(account: "nightscout.token")
        var result = Result()
        if let t = try? await fetchTreatments(root: root, token: token, days: days) {
            result.carbs = t.carbs; result.insulin = t.insulin
        }
        result.basalByHour = try? await fetchBasalSchedule(root: root, token: token)
        return result
    }

    // MARK: treatments (carbs + insulin)

    private struct Treatment: Decodable { let created_at: String?; let carbs: Double?; let insulin: Double? }

    private static func fetchTreatments(root: String, token: String?, days: Int)
        async throws -> (carbs: [(date: Date, grams: Double)], insulin: [(date: Date, units: Double)]) {
        var comps = URLComponents(string: root + "/api/v1/treatments.json")!
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        var items = [URLQueryItem(name: "count", value: "50000"),
                     URLQueryItem(name: "find[created_at][$gte]", value: ISO8601DateFormatter().string(from: since))]
        if let token { items.append(URLQueryItem(name: "token", value: token)) }
        comps.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let ts = (try? JSONDecoder().decode([Treatment].self, from: data)) ?? []
        var carbs: [(Date, Double)] = [], insulin: [(Date, Double)] = []
        for t in ts {
            guard let date = t.created_at.flatMap(parseDate) else { continue }
            if let c = t.carbs, c > 0 { carbs.append((date, c)) }
            if let i = t.insulin, i > 0 { insulin.append((date, i)) }
        }
        return (carbs.map { (date: $0.0, grams: $0.1) }, insulin.map { (date: $0.0, units: $0.1) })
    }

    // MARK: profile → basal schedule (24 hourly rates)

    private static func fetchBasalSchedule(root: String, token: String?) async throws -> [Double]? {
        var comps = URLComponents(string: root + "/api/v1/profile.json")!
        if let token { comps.queryItems = [URLQueryItem(name: "token", value: token)] }
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        // Nightscout profile: [{ defaultProfile, store: { <name>: { basal: [{time,value,timeAsSeconds}] } } }]
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let doc = arr.first,
              let store = doc["store"] as? [String: Any] else { return nil }
        let name = (doc["defaultProfile"] as? String) ?? store.keys.first ?? ""
        guard let profile = store[name] as? [String: Any],
              let basal = profile["basal"] as? [[String: Any]], !basal.isEmpty else { return nil }
        // Build 24 hourly rates: each segment (start in seconds) applies until the next.
        let segments: [(start: Int, rate: Double)] = basal.compactMap {
            guard let rate = ($0["value"] as? NSNumber)?.doubleValue else { return nil }
            let secs = ($0["timeAsSeconds"] as? NSNumber)?.intValue
                ?? minutesFromHHmm($0["time"] as? String).map { $0 * 60 } ?? 0
            return (secs, rate)
        }.sorted { $0.start < $1.start }
        guard !segments.isEmpty else { return nil }
        return (0..<24).map { hour in
            let sec = hour * 3600
            return (segments.last { $0.start <= sec } ?? segments[0]).rate
        }
    }

    private static func minutesFromHHmm(_ s: String?) -> Int? {
        guard let p = s?.split(separator: ":"), p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }
    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
