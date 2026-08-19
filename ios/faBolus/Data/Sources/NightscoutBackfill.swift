import Foundation

/// Pulls Nightscout **treatments** (carbs + insulin) into faBolus, complementing `NightscoutSource`
/// (which handles glucose). Uses the same site URL + optional token. Read-only. The results feed
/// `HistoryStore` (carbs/insulin). See MIGRATION.md Phase 4 follow-on.
enum NightscoutBackfill {
    struct Result {
        var carbs: [(date: Date, grams: Double)] = []
        var insulin: [(date: Date, units: Double)] = []
    }

    static func fetch(days: Int = 30) async -> Result? {
        guard let base = GlucoseSourceConfig.string("nightscout.url") else { return nil }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        let token = CredentialStore.get(account: "nightscout.token")
        var result = Result()
        if let t = try? await fetchTreatments(root: root, token: token, days: days) {
            result.carbs = t.carbs; result.insulin = t.insulin
        }
        return result
    }

    // MARK: treatments (carbs + insulin)

    private struct Treatment: Decodable { let created_at: String?; let carbs: Double?; let insulin: Double? }

    /// Build + validate the treatments URL (D-13). Validates via `URLComponents` (scheme/host checks)
    /// instead of force-unwrapping `URLComponents(string:)!` / `comps.url!` — a malformed
    /// `nightscout.url` (a space, no scheme, junk) would otherwise trap/crash, exactly the crash-safety
    /// bug `NightscoutSource` already avoids. Extracted `static` (throwing) so it's testable offline
    /// without a network call. ASVS V5.
    static func treatmentsURL(root: String, token: String?, days: Int) throws -> URL {
        guard var comps = URLComponents(string: root + "/api/v1/treatments.json"),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              comps.host?.isEmpty == false else {
            throw SourceError.invalidConfig("Nightscout URL")
        }
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        var items = [URLQueryItem(name: "count", value: "50000"),
                     URLQueryItem(name: "find[created_at][$gte]", value: ISO8601DateFormatter().string(from: since))]
        if let token { items.append(URLQueryItem(name: "token", value: token)) }
        comps.queryItems = items
        guard let url = comps.url else { throw SourceError.invalidConfig("Nightscout URL") }
        return url
    }

    private static func fetchTreatments(root: String, token: String?, days: Int)
        async throws -> (carbs: [(date: Date, grams: Double)], insulin: [(date: Date, units: Double)]) {
        let url = try treatmentsURL(root: root, token: token, days: days)
        let (data, _) = try await URLSession.shared.data(from: url)
        let ts = (try? JSONDecoder().decode([Treatment].self, from: data)) ?? []
        var carbs: [(Date, Double)] = [], insulin: [(Date, Double)] = []
        for t in ts {
            guard let date = t.created_at.flatMap(parseDate) else { continue }
            if let c = t.carbs, c > 0 { carbs.append((date, c)) }
            if let i = t.insulin, i > 0 { insulin.append((date, i)) }
        }
        return (carbs.map { (date: $0.0, grams: $0.1) }, insulin.map { (date: $0.0, units: $0.1) })
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
