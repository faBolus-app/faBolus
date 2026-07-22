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
}
