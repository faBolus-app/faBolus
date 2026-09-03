import XCTest
@testable import faBolusCore

final class BackupModelsTests: XCTestCase {
    func testBackupValueRoundTripsEveryCase() throws {
        let values: [BackupValue] = [
            .bool(true), .int(42), .double(0.05), .string("carbs"),
            .stringArray(["iob", "reservoir"]), .intArray([3, 6, 12, 24]),
            .data(Data([0x01, 0x02, 0xFF]))
        ]
        for v in values {
            let data = try JSONEncoder().encode(v)
            XCTAssertEqual(try JSONDecoder().decode(BackupValue.self, from: data), v)
        }
    }

    func testBackupRoundTripsWithAppSettings() throws {
        let meta = FaBolusBackup.Meta(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "0.1.0", pumpModel: "mobi", deviceName: "iPhone")
        let backup = FaBolusBackup(
            meta: meta,
            appSettings: [
                "defaultBolusMode": .string("carbs"),
                "bolusIncrement": .double(0.05),
                "watchChartRanges": .intArray([3, 6, 12, 24])
            ])
        let decoded = try FaBolusBackup.decode(backup.encoded())
        XCTAssertEqual(decoded.meta.schemaVersion, FaBolusBackup.currentSchema)
        XCTAssertEqual(decoded.meta.pumpModel, "mobi")
        XCTAssertEqual(decoded.appSettings?["defaultBolusMode"], .string("carbs"))
        XCTAssertEqual(decoded.appSettings?["watchChartRanges"], .intArray([3, 6, 12, 24]))
    }

    /// `appSettings` is independently optional: a backup that omits it decodes with it nil, one that
    /// provides it decodes with it populated.
    func testAppSettingsIsIndependentlyOptional() throws {
        let meta = FaBolusBackup.Meta(createdAt: Date(), appVersion: "0.1.0", pumpModel: "unknown", deviceName: "x")
        let withoutAppSettings = try FaBolusBackup.decode(FaBolusBackup(meta: meta).encoded())
        XCTAssertNil(withoutAppSettings.appSettings)
        let withAppSettings = try FaBolusBackup.decode(
            FaBolusBackup(meta: meta, appSettings: ["showStats": .bool(true)]).encoded())
        XCTAssertEqual(withAppSettings.appSettings?["showStats"], .bool(true))
    }

    func testCurrentSchemaIsThree() {
        XCTAssertEqual(FaBolusBackup.currentSchema, 3)
    }

    /// Back-compat: a minimal schema-1 backup (no `appSettings` key at all, as an older app version
    /// would have written before any section beyond `meta` existed) still decodes; `appSettings` is nil.
    func testSchema1BackupDecodesWithNilAppSettings() throws {
        let schema1JSON = """
            {
              "meta": {
                "appVersion": "0.1.0",
                "createdAt": "2023-11-14T22:13:20Z",
                "deviceName": "iPhone",
                "pumpModel": "mobi",
                "schemaVersion": 1
              }
            }
            """
        let decoded = try FaBolusBackup.decode(Data(schema1JSON.utf8))
        XCTAssertEqual(decoded.meta.schemaVersion, 1, "the fixture's own version is preserved")
        XCTAssertNil(decoded.appSettings)
    }

    /// A `dev/backup`-authored schema-3 payload — one that still carries the `secrets`/`pumpSettings`/
    /// `siteAtlas`/`trackers` keys this type no longer declares — still decodes on `main`: `Codable`'s
    /// synthesized keyed-container decoding silently ignores any key it doesn't recognize, so `meta`
    /// and `appSettings` come through untouched and no error is thrown. This is the proof for
    /// `FaBolusBackup.currentSchema`'s doc comment.
    func testOlderPayloadWithRemovedSectionKeysStillDecodesAndDropsThem() throws {
        let schema3WithRemovedSectionsJSON = """
            {
              "meta": {
                "appVersion": "0.3.0",
                "createdAt": "2023-11-14T22:13:20Z",
                "deviceName": "iPhone",
                "pumpModel": "mobi",
                "schemaVersion": 3
              },
              "appSettings": {
                "showStats": { "type": "bool", "value": true }
              },
              "secrets": { "items": { "nightscout.token": "abc" } },
              "pumpSettings": { "profiles": [] },
              "siteAtlas": { "entries": [] },
              "trackers": { "caffeine": [], "alcohol": [] }
            }
            """
        let decoded = try FaBolusBackup.decode(Data(schema3WithRemovedSectionsJSON.utf8))
        XCTAssertEqual(decoded.meta.schemaVersion, 3, "the fixture's own version is preserved")
        XCTAssertEqual(decoded.appSettings?["showStats"], .bool(true), "the surviving section decodes normally")
    }
}
