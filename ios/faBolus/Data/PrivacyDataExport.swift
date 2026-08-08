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

    var meta: Meta
    var glucose: [GlucosePoint]
    var boluses: [BolusPoint]
    var carbs: [CarbPoint]
    /// Full setting-change provenance log (latest-per-key + the chronological audit trail).
    var settingChangeLog: SettingChangeLog
    /// The durable remote-bolus idempotency ledger — the delivery audit trail.
    var remoteBolusLedger: RemoteBolusLedger

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
