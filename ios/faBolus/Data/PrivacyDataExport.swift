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
    /// One logged caffeine intake (09.18d-02, D-14/D-17). Benign log fields only — informational.
    struct CaffeinePoint: Codable, Equatable { var date: Date; var milligrams: Double; var source: String }
    /// One logged alcohol intake (09.18d-02, D-14/D-17). Benign log fields only — no risk inference.
    struct AlcoholPoint: Codable, Equatable { var date: Date; var standardDrinks: Double; var source: String }

    var meta: Meta
    var glucose: [GlucosePoint]
    var boluses: [BolusPoint]
    var carbs: [CarbPoint]
    /// SiteAtlas placements (infusion sites / CGM sensors). Decode-optional: a payload from a build
    /// before SiteAtlas existed simply yields an empty array.
    var sites: [SitePoint]
    /// Caffeine tracker log (09.18d-02). Decode-optional: a payload from a build before the trackers
    /// shipped simply yields an empty array.
    var caffeine: [CaffeinePoint]
    /// Alcohol tracker log (09.18d-02). Decode-optional (same back-compat as `caffeine`).
    var alcohol: [AlcoholPoint]
    /// Full setting-change provenance log (latest-per-key + the chronological audit trail).
    var settingChangeLog: SettingChangeLog
    /// The durable remote-bolus idempotency ledger — the delivery audit trail.
    var remoteBolusLedger: RemoteBolusLedger

    private enum CodingKeys: String, CodingKey {
        case meta, glucose, boluses, carbs, sites, caffeine, alcohol, settingChangeLog, remoteBolusLedger
    }

    init(meta: Meta, glucose: [GlucosePoint], boluses: [BolusPoint], carbs: [CarbPoint],
         sites: [SitePoint] = [], caffeine: [CaffeinePoint] = [], alcohol: [AlcoholPoint] = [],
         settingChangeLog: SettingChangeLog, remoteBolusLedger: RemoteBolusLedger) {
        self.meta = meta; self.glucose = glucose; self.boluses = boluses; self.carbs = carbs
        self.sites = sites; self.caffeine = caffeine; self.alcohol = alcohol
        self.settingChangeLog = settingChangeLog; self.remoteBolusLedger = remoteBolusLedger
    }

    /// Back-compat decode: `sites`/`caffeine`/`alcohol` may be absent in a payload written before those
    /// surfaces shipped → [].
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(Meta.self, forKey: .meta)
        glucose = try c.decode([GlucosePoint].self, forKey: .glucose)
        boluses = try c.decode([BolusPoint].self, forKey: .boluses)
        carbs = try c.decode([CarbPoint].self, forKey: .carbs)
        sites = try c.decodeIfPresent([SitePoint].self, forKey: .sites) ?? []
        caffeine = try c.decodeIfPresent([CaffeinePoint].self, forKey: .caffeine) ?? []
        alcohol = try c.decodeIfPresent([AlcoholPoint].self, forKey: .alcohol) ?? []
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
