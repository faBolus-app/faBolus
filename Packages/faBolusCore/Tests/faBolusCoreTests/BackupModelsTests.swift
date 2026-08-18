import XCTest
@testable import faBolusCore

final class BackupModelsTests: XCTestCase {
    func testBackupValueRoundTripsEveryCase() throws {
        let values: [BackupValue] = [
            .bool(true), .int(42), .double(0.05), .string("carbs"),
            .stringArray(["iob", "reservoir"]), .intArray([3, 6, 12, 24]),
            .data(Data([0x01, 0x02, 0xFF])),
        ]
        for v in values {
            let data = try JSONEncoder().encode(v)
            XCTAssertEqual(try JSONDecoder().decode(BackupValue.self, from: data), v)
        }
    }

    func testFullBackupRoundTrips() throws {
        let meta = FaBolusBackup.Meta(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                      appVersion: "0.1.0", pumpModel: "mobi", deviceName: "iPhone")
        let seg = PumpSettingsBackup.SegmentBackup(startTimeMinutes: 0, basalRateUnitsPerHour: 0.8,
                                                   carbRatioGramsPerUnit: 10, isf: 40, targetBg: 110)
        let pump = PumpSettingsBackup(profiles: [.init(name: "Weekday", active: true, segments: [seg])],
                                      maxBolusUnits: 25, maxBasalUnitsPerHour: 3,
                                      controlIQEnabled: true, controlIQWeightLbs: 150, controlIQTotalDailyInsulin: 40)
        let backup = FaBolusBackup(meta: meta,
                                   appSettings: ["defaultBolusMode": .string("carbs"),
                                                 "bolusIncrement": .double(0.05),
                                                 "watchChartRanges": .intArray([3, 6, 12, 24])],
                                   secrets: SecretsBackup(items: ["nightscout.token": "abc"]),
                                   pumpSettings: pump)
        let decoded = try FaBolusBackup.decode(backup.encoded())
        XCTAssertEqual(decoded.meta.schemaVersion, FaBolusBackup.currentSchema)
        XCTAssertEqual(decoded.meta.pumpModel, "mobi")
        XCTAssertEqual(decoded.appSettings?["defaultBolusMode"], .string("carbs"))
        XCTAssertEqual(decoded.appSettings?["watchChartRanges"], .intArray([3, 6, 12, 24]))
        XCTAssertEqual(decoded.secrets?.items["nightscout.token"], "abc")
        XCTAssertEqual(decoded.pumpSettings?.profiles.first?.segments.first, seg)
        XCTAssertEqual(decoded.pumpSettings?.maxBolusUnits, 25)
    }

    /// App-only / pump-only backups omit the other sections entirely.
    func testSectionsAreIndependentlyOptional() throws {
        let meta = FaBolusBackup.Meta(createdAt: Date(), appVersion: "0.1.0", pumpModel: "unknown", deviceName: "x")
        let appOnly = try FaBolusBackup.decode(FaBolusBackup(meta: meta, appSettings: ["showStats": .bool(true)]).encoded())
        XCTAssertNotNil(appOnly.appSettings); XCTAssertNil(appOnly.pumpSettings); XCTAssertNil(appOnly.secrets)
        let pumpOnly = try FaBolusBackup.decode(FaBolusBackup(meta: meta, pumpSettings: PumpSettingsBackup()).encoded())
        XCTAssertNil(pumpOnly.appSettings); XCTAssertNotNil(pumpOnly.pumpSettings)
    }

    // MARK: SiteAtlas backup section (09.18a-01, D-10)

    func testCurrentSchemaIsTwo() {
        XCTAssertEqual(FaBolusBackup.currentSchema, 2)
    }

    /// D-10 back-compat: a schema-1 backup (no `siteAtlas` key) still decodes; `siteAtlas` is nil.
    func testSchema1BackupDecodesWithNilSiteAtlas() throws {
        // Hard-coded schema-1 payload — no siteAtlas key at all (as an older app version would have written).
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
        XCTAssertNil(decoded.siteAtlas, "a schema-1 backup has no siteAtlas section")
        XCTAssertNil(decoded.appSettings); XCTAssertNil(decoded.secrets); XCTAssertNil(decoded.pumpSettings)
    }

    func testSiteAtlasBackupRoundTrips() throws {
        let meta = FaBolusBackup.Meta(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                      appVersion: "0.3.0", pumpModel: "mobi", deviceName: "iPhone")
        let entry = SiteAtlasEntryBackup(siteID: "site-1", kind: "pump", bodySide: "front",
                                         normalizedX: 0.58, normalizedY: 0.44, note: "left abdomen",
                                         date: Date(timeIntervalSince1970: 1_700_000_000))
        let backup = FaBolusBackup(meta: meta, siteAtlas: SiteAtlasBackup(entries: [entry]))
        let decoded = try FaBolusBackup.decode(backup.encoded())
        XCTAssertEqual(decoded.meta.schemaVersion, 2)
        let out = try XCTUnwrap(decoded.siteAtlas?.entries.first)
        XCTAssertEqual(out.siteID, "site-1")
        XCTAssertEqual(out.kind, "pump")
        XCTAssertEqual(out.bodySide, "front")
        XCTAssertEqual(out.normalizedX, 0.58, accuracy: 1e-9)
        XCTAssertEqual(out.normalizedY, 0.44, accuracy: 1e-9)
        XCTAssertEqual(out.note, "left abdomen")
        // siteAtlas stays independently optional alongside the other sections.
        XCTAssertNil(decoded.appSettings); XCTAssertNil(decoded.secrets); XCTAssertNil(decoded.pumpSettings)
    }
}
