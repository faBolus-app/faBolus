import Foundation
import faBolusCore

/// F1 (§13) — a single, user-invokable export of the on-device HEALTH data as one shareable JSON file:
/// glucose / insulin / carb history, the setting-change (provenance) audit log, and the remote-bolus
/// ledger audit trail. faBolus has no servers — this is the user's own copy of everything held on the
/// device, saved wherever they choose (Files / iCloud Drive / AirDrop). The full audit trail is included
/// (owner default). Assembled by `AppModel.buildPrivacyExport()`.
struct PrivacyDataExport: Codable {
    static let currentSchema = 1

    struct Meta: Codable, Equatable {
        var createdAt: Date
        var appVersion: String
        var schemaVersion: Int
    }
    struct GlucosePoint: Codable, Equatable { var date: Date; var mgdl: Int }
    struct BolusPoint: Codable, Equatable { var date: Date; var units: Double }
    struct CarbPoint: Codable, Equatable { var date: Date; var grams: Double }
    /// One SiteAtlas placement (09.18a-01, D-10). `kind`/`bodySide` are the raw enum String values.
    struct SitePoint: Codable, Equatable {
        var siteID: String
        var kind: String
        var bodySide: String
        var normalizedX: Double
        var normalizedY: Double
        var note: String?
        var date: Date
    }

    var meta: Meta
    var glucose: [GlucosePoint]
    var boluses: [BolusPoint]
    var carbs: [CarbPoint]
    /// SiteAtlas placements (infusion sites / CGM sensors). Decode-optional: a payload from a build
    /// before SiteAtlas existed simply yields an empty array.
    var sites: [SitePoint]
    /// Full setting-change provenance log (latest-per-key + the chronological audit trail).
    var settingChangeLog: SettingChangeLog
    /// The durable remote-bolus idempotency ledger — the delivery audit trail.
    var remoteBolusLedger: RemoteBolusLedger

    private enum CodingKeys: String, CodingKey {
        case meta, glucose, boluses, carbs, sites, settingChangeLog, remoteBolusLedger
    }

    init(meta: Meta, glucose: [GlucosePoint], boluses: [BolusPoint], carbs: [CarbPoint],
         sites: [SitePoint] = [], settingChangeLog: SettingChangeLog, remoteBolusLedger: RemoteBolusLedger) {
        self.meta = meta; self.glucose = glucose; self.boluses = boluses; self.carbs = carbs
        self.sites = sites; self.settingChangeLog = settingChangeLog; self.remoteBolusLedger = remoteBolusLedger
    }

    /// Back-compat decode: `sites` may be absent in a payload written before SiteAtlas shipped → [].
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(Meta.self, forKey: .meta)
        glucose = try c.decode([GlucosePoint].self, forKey: .glucose)
        boluses = try c.decode([BolusPoint].self, forKey: .boluses)
        carbs = try c.decode([CarbPoint].self, forKey: .carbs)
        sites = try c.decodeIfPresent([SitePoint].self, forKey: .sites) ?? []
        settingChangeLog = try c.decode(SettingChangeLog.self, forKey: .settingChangeLog)
        remoteBolusLedger = try c.decode(RemoteBolusLedger.self, forKey: .remoteBolusLedger)
    }

    /// Encode as a stable, human-readable JSON payload (sorted keys, ISO-8601 dates).
    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    /// Decode a payload produced by `encoded()` (matching ISO-8601 date strategy).
    static func decode(_ data: Data) throws -> PrivacyDataExport {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(PrivacyDataExport.self, from: data)
    }

    /// Suggested share-sheet filename (a plain `.json`, matching the backup convention).
    static func suggestedFilename(now: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "faBolus-data-\(f.string(from: now))"
    }
}
