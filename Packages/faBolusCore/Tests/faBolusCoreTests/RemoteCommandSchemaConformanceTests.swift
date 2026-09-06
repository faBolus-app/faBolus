import Testing
import Foundation
@testable import faBolusCore

/// Pins that `command.schema.json` `kind.enum` and the shared `watchChartRanges` field stay
/// aligned with `RemoteCommand`. BLE-only kinds and additive Swift-only fields are deliberately outside this contract.
struct RemoteCommandSchemaConformanceTests {

    /// Resolve a repo-relative path by walking up from `#filePath`
    /// (`<root>/Packages/faBolusCore/Tests/faBolusCoreTests/RemoteCommandSchemaConformanceTests.swift`).
    private static func resolve(_ relativePath: String) -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func loadSchema() throws -> [String: Any] {
        guard let url = resolve("schema/command.schema.json") else {
            Issue.record("could not resolve schema/command.schema.json from #filePath=\(#filePath)")
            return [:]
        }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }

    /// LIVE Swift fields that must stay present on BOTH sides — a schema-only or Swift-only deletion
    /// would create drift invisible to a kinds-only test.
    private static let atRiskSharedFields = ["watchChartRanges"]

    // MARK: - Path resolution can't pass vacuously

    @Test func fileResolutionActuallyFoundTheSchema() {
        #expect(
            Self.resolve("schema/command.schema.json") != nil,
            "path resolution broke — could not resolve schema/command.schema.json; the conformance checks below would pass vacuously"
        )
    }

    // MARK: - kind.enum

    @Test func schemaKindEnumEqualsTheDocumentedSharedSubsetOfRemoteCommandKind() throws {
        let schema = try Self.loadSchema()
        guard let properties = schema["properties"] as? [String: Any],
            let kindSchema = properties["kind"] as? [String: Any],
            let schemaKinds = kindSchema["enum"] as? [String]
        else {
            Issue.record("schema/command.schema.json has no properties.kind.enum array — conformance check cannot run")
            return
        }

        let allKindRawValues = Set(RemoteCommand.Kind.allCases.map(\.rawValue))

        #expect(
            Set(schemaKinds) == allKindRawValues,
            "schema kind.enum \(schemaKinds.sorted()) must equal every RemoteCommand.Kind \(allKindRawValues.sorted()) — a kind leaked into the schema, or a Swift kind is missing from it"
        )
    }

    // MARK: - shared top-level properties

    @Test func sharedTopLevelPropertiesStayConsistentBetweenSchemaAndSwift() throws {
        let schema = try Self.loadSchema()
        guard let properties = schema["properties"] as? [String: Any] else {
            Issue.record("schema/command.schema.json has no top-level properties object — conformance check cannot run")
            return
        }
        let schemaPropertyNames = Set(properties.keys)
        #expect(!schemaPropertyNames.isEmpty, "schema properties parsed empty — path/parse resolution broke")

        // Reflect the REAL stored properties of RemoteCommand (not a hand-maintained list) so a renamed
        // or deleted field is caught even if this test file is never touched again.
        let sample = RemoteCommand(kind: .statusRead)
        let swiftFieldNames = Set(Mirror(reflecting: sample).children.compactMap(\.label))
        #expect(!swiftFieldNames.isEmpty, "Mirror reflected no fields off RemoteCommand — reflection broke")

        // Direction 1 (already enforced by scripts/check-schema-drift.sh, re-asserted here so the two
        // conformance concerns — kinds and shared properties — live in one Swift-side test): every schema
        // property must have a matching RemoteCommand field.
        let schemaOnly = schemaPropertyNames.subtracting(swiftFieldNames)
        #expect(
            schemaOnly.isEmpty,
            "schema/command.schema.json declares propert\(schemaOnly.count == 1 ? "y" : "ies") with no matching RemoteCommand field: \(schemaOnly.sorted()) — update RemoteCommand.swift (and the Garmin Monkey C mirror)"
        )

        // Direction 2: a kinds-only test would pass while these silently diverge. The fields with a
        // live AppModel producer must stay declared on BOTH sides.
        for field in Self.atRiskSharedFields {
            #expect(
                schemaPropertyNames.contains(field),
                "'\(field)' must stay in schema/command.schema.json — frozen AppModel.swift still populates it; its retirement is a coordinated frozen change deferred beyond this UI phase"
            )
            #expect(
                swiftFieldNames.contains(field),
                "'\(field)' must stay a RemoteCommand field — the schema still declares it and frozen AppModel.swift still populates it"
            )
        }
    }

    // MARK: - additive per-surface watch-intent wire property

    /// The additive field must exist in the schema (so a receiver can rely on it) while the version
    /// stays pinned — adding a property is safe, bumping the const would break every older watch.
    @Test func schemaDeclaresTheAdditiveWatchIntentPropertyUnderAnUnchangedVersion() throws {
        let schema = try Self.loadSchema()
        guard let properties = schema["properties"] as? [String: Any] else {
            Issue.record("schema/command.schema.json has no top-level properties object")
            return
        }
        #expect(
            properties["watchNotificationIntents"] != nil,
            "schema/command.schema.json must declare the additive watchNotificationIntents property"
        )

        // version.const is unchanged (== 1); a bump breaks the watch immediately.
        guard let version = properties["version"] as? [String: Any] else {
            Issue.record("schema has no properties.version")
            return
        }
        #expect(
            version["const"] as? Int == 1,
            "version.const must stay 1 — bumping it breaks every older watch; this landing is additive"
        )

        // Root additionalProperties stays false — an additive field never loosens the guard.
        #expect(
            schema["additionalProperties"] as? Bool == false,
            "root additionalProperties must stay false; the new field is a declared property, not an escape hatch"
        )
    }

    /// The Swift mirror carries the field as an Optional (so a legacy host simply omits it) and it
    /// round-trips through the same JSON encode/decode the wire uses.
    @Test func watchNotificationIntentsIsOptionalAndRoundTrips() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        #expect(cmd.watchNotificationIntents == nil, "the field must be Optional and default to absent")

        cmd.watchNotificationIntents = ["deliveryStopped": "alert", "pumpRoutine": "quiet"]
        let data = try cmd.encoded()
        let decoded = try JSONDecoder().decode(RemoteCommand.self, from: data)
        #expect(
            decoded.watchNotificationIntents == cmd.watchNotificationIntents,
            "watchNotificationIntents must round-trip encode/decode on the wire"
        )
    }

    /// The contract enforced downstream: an absent field, an absent key, or an unrecognized token all
    /// resolve to the vibrating rung — never silence — so an old host or a corrupted value can never
    /// quiet a pump safety alert. An explicit, recognized value (including an intentional "off") is the
    /// user's own choice and is honored verbatim.
    @Test func absentOrMalformedWatchIntentFailsSafeToVibrateNeverSilent() {
        // Legacy host: the field is absent entirely.
        let legacy = RemoteCommand(kind: .statusRead)
        #expect(
            legacy.resolvedWatchIntent(for: "deliveryStopped") == .alert,
            "an absent field must fail safe to the vibrating rung, never to silence"
        )

        // New host, but this category's key is missing from the map.
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.watchNotificationIntents = ["runningLow": "quiet"]
        #expect(
            cmd.resolvedWatchIntent(for: "deliveryStopped") == .alert,
            "an absent key must fail safe to the vibrating rung"
        )

        // Malformed / unrecognized token.
        cmd.watchNotificationIntents = ["deliveryStopped": "banana"]
        #expect(
            cmd.resolvedWatchIntent(for: "deliveryStopped") == .alert,
            "an unrecognized token must fail safe to the vibrating rung"
        )

        // Explicit recognized values are honored — including an intentional silence.
        cmd.watchNotificationIntents = ["deliveryStopped": "off", "runningLow": "quiet"]
        #expect(cmd.resolvedWatchIntent(for: "deliveryStopped") == .off, "an explicit off is the user's own choice")
        #expect(cmd.resolvedWatchIntent(for: "runningLow") == .quiet, "an explicit quiet is honored verbatim")
    }

    // MARK: - additive source-agnostic app-own alert relay property

    /// The additive app-own relay property must exist in the schema (so the watch can annunciate the
    /// app-generated subset) while the version stays pinned — adding a property is safe, bumping the
    /// const would break every older watch.
    @Test func schemaDeclaresTheAdditiveAppOwnAlertsPropertyUnderAnUnchangedVersion() throws {
        let schema = try Self.loadSchema()
        guard let properties = schema["properties"] as? [String: Any] else {
            Issue.record("schema/command.schema.json has no top-level properties object")
            return
        }
        #expect(
            properties["appOwnAlerts"] != nil,
            "schema/command.schema.json must declare the additive appOwnAlerts property"
        )

        guard let version = properties["version"] as? [String: Any] else {
            Issue.record("schema has no properties.version")
            return
        }
        #expect(
            version["const"] as? Int == 1,
            "version.const must stay 1 — bumping it breaks every older watch; this landing is additive"
        )
        #expect(
            schema["additionalProperties"] as? Bool == false,
            "root additionalProperties must stay false; the new field is a declared property, not an escape hatch"
        )
    }

    /// The Swift mirror carries the field as an Optional (so a legacy host simply omits it) and each
    /// item round-trips through the same JSON encode/decode the wire uses.
    @Test func appOwnAlertsIsOptionalAndRoundTrips() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        #expect(cmd.appOwnAlerts == nil, "the field must be Optional and default to absent")

        cmd.appOwnAlerts = [
            RemoteCommand.AppOwnAlert(key: "appOwn:bolusIndeterminate", title: "Bolus outcome unknown"),
            RemoteCommand.AppOwnAlert(key: "appOwn:pumpDisconnect", title: "Pump disconnected"),
        ]
        let data = try cmd.encoded()
        let decoded = try JSONDecoder().decode(RemoteCommand.self, from: data)
        #expect(
            decoded.appOwnAlerts == cmd.appOwnAlerts,
            "appOwnAlerts must round-trip encode/decode on the wire"
        )
    }
}
