import Testing
import Foundation
@testable import faBolusCore

/// D1-03 (17-07) — the missing Swift↔schema conformance test for the phone↔remote command contract.
/// `scripts/check-schema-drift.sh` already guards ONE direction (every `schema/command.schema.json`
/// property has a matching `RemoteCommand` field) but nothing previously pinned the `kind.enum`
/// vocabulary, and nothing asserted that a specific field present on BOTH sides today (`activeMode`,
/// `watchChartRanges`) can't silently disappear from just one side — the exact
/// drift class Codex HIGH finding #3 flagged (a schema-only or Swift-only deletion of one of those two
/// creates drift invisible to a kinds-only test). `watchBolusEnabled` was retired end-to-end (Swift +
/// schema) in Phase 17.5 Plan 01 (D1-01/REMED-17) — it is no longer a member of this at-risk set because
/// it no longer exists on either side. This test does NOT audit the full ~100-field
/// `RemoteCommand` surface against the schema: many additive Swift-only/BLE-only fields (the `auth*`
/// handshake, `sealed`/`sealedPayload`, `eatingProb`/`eatingSensingOn`, `diagnosticsText`, the Control-IQ
/// telemetry fields, etc.) are DELIBERATELY not part of the shared `command.schema.json` contract per
/// their own doc comments in `RemoteCommand.swift` — auditing those would manufacture false "drift"
/// findings outside this plan's D1-02/D1-03 scope. "Shared top-level properties" here means exactly the
/// schema's own declared property vocabulary (that IS the definition of "shared" — the schema is the
/// contract both the Swift host and the Garmin Monkey C mirror validate/generate against).
///
/// Mirrors `HeartRateSchemaAbsenceGuardTests`' `#filePath`-rooted `resolve()` walk-up idiom verbatim.
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

    /// The documented BLE-only / Mac-pairing / advisory `RemoteCommand.Kind` cases, per their own doc
    /// comments (RemoteCommand.swift:16-43): the Mac pairing handshake (`auth*`), the sealed BLE envelope
    /// (`sealed`), reverse-approval (`bolusApproval*`), advisory eating-detection (`eatingEvent`), and the
    /// watch-only diagnostics round-trip (`diagnosticsRead`). None of these are part of the shared
    /// watch/Garmin `command.schema.json` — each doc comment says so explicitly.
    private static let bleOrSwiftOnlyKinds: Set<RemoteCommand.Kind> = [
        .authHello, .authChallenge, .authProof, .authResult,
        .sealed,
        .bolusApprovalRequest, .bolusApprovalResponse,
        .eatingEvent,
        .diagnosticsRead,
    ]

    /// The specific fields Codex HIGH finding #3 flagged: LIVE Swift fields (frozen `AppModel.swift`
    /// still populates them) that must stay present on BOTH sides — a schema-only deletion would create
    /// drift, and a Swift-side deletion would cross the frozen boundary.
    private static let atRiskSharedFields = ["activeMode", "watchChartRanges"]

    // MARK: - Path resolution can't pass vacuously

    @Test func fileResolutionActuallyFoundTheSchema() {
        #expect(Self.resolve("schema/command.schema.json") != nil,
                "path resolution broke — could not resolve schema/command.schema.json; the conformance checks below would pass vacuously")
    }

    // MARK: - kind.enum

    @Test func schemaKindEnumEqualsTheDocumentedSharedSubsetOfRemoteCommandKind() throws {
        let schema = try Self.loadSchema()
        guard let properties = schema["properties"] as? [String: Any],
              let kindSchema = properties["kind"] as? [String: Any],
              let schemaKinds = kindSchema["enum"] as? [String] else {
            Issue.record("schema/command.schema.json has no properties.kind.enum array — conformance check cannot run")
            return
        }

        let sharedSwiftKinds = RemoteCommand.Kind.allCases.filter { !Self.bleOrSwiftOnlyKinds.contains($0) }
        let sharedSwiftKindRawValues = Set(sharedSwiftKinds.map(\.rawValue))

        #expect(Set(schemaKinds) == sharedSwiftKindRawValues,
                "schema kind.enum \(schemaKinds.sorted()) must equal the documented shared subset of RemoteCommand.Kind \(sharedSwiftKindRawValues.sorted()) — a BLE-only/Mac-pairing/advisory kind leaked into the schema, or a shared kind is missing from it")

        // Belt-and-suspenders: every excluded case really is excluded (catches a typo in the exclusion set
        // itself hiding a real omission from the shared subset).
        for excluded in Self.bleOrSwiftOnlyKinds {
            #expect(!schemaKinds.contains(excluded.rawValue),
                    "'\(excluded.rawValue)' is documented BLE-only/Mac-pairing/advisory (RemoteCommand.swift) but appears in schema kind.enum")
        }
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
        #expect(schemaOnly.isEmpty,
                "schema/command.schema.json declares propert\(schemaOnly.count == 1 ? "y" : "ies") with no matching RemoteCommand field: \(schemaOnly.sorted()) — update RemoteCommand.swift (and the Garmin Monkey C mirror)")

        // Direction 2 (the gap Codex HIGH finding #3 flagged: a kinds-only test would pass while these
        // silently diverge): the three fields with a LIVE frozen-AppModel producer must stay declared on
        // BOTH sides — neither a schema-only deletion nor a Swift-side deletion is safe here.
        for field in Self.atRiskSharedFields {
            #expect(schemaPropertyNames.contains(field),
                    "'\(field)' must stay in schema/command.schema.json — frozen AppModel.swift still populates it; its retirement is a coordinated frozen change deferred beyond this UI phase")
            #expect(swiftFieldNames.contains(field),
                    "'\(field)' must stay a RemoteCommand field — the schema still declares it and frozen AppModel.swift still populates it")
        }
    }
}
