import Foundation
import SwiftData

// SwiftData persistence models. Each carries the SOURCE that produced it (its `GlucoseSourceDescriptor.id`
// or "pump") + that source's priority + when we recorded it, so multi-source data is de-duplicated by
// (priority, recency) on read — the higher-priority/import source wins, matching GlucoseArbiter.

@Model public final class StoredGlucose {
    public var date: Date
    public var mgdl: Int
    public var sourceID: String
    public var priority: Int
    public var recordedAt: Date
    public init(date: Date, mgdl: Int, sourceID: String, priority: Int, recordedAt: Date) {
        self.date = date; self.mgdl = mgdl; self.sourceID = sourceID
        self.priority = priority; self.recordedAt = recordedAt
    }
}

@Model public final class StoredBolus {
    public var date: Date
    public var units: Double
    public var sourceID: String
    public var recordedAt: Date
    public init(date: Date, units: Double, sourceID: String, recordedAt: Date) {
        self.date = date; self.units = units; self.sourceID = sourceID; self.recordedAt = recordedAt
    }
}

@Model public final class StoredCarb {
    public var date: Date
    public var grams: Double
    public var sourceID: String
    public var recordedAt: Date
    public init(date: Date, grams: Double, sourceID: String, recordedAt: Date) {
        self.date = date; self.grams = grams; self.sourceID = sourceID; self.recordedAt = recordedAt
    }
}

/// A recorded infusion-site / CGM-sensor placement (SiteAtlas, 09.18a, D-10). Ports the mirror's
/// `SiteAtlas_SiteEntry` field shape onto a primitive SwiftData schema: `kind`/`bodySide` are the raw
/// String enum values ("pump"|"sensor", "front"|"back") so the store stays enum-free and stable across
/// upstream drift. `siteID` is a stable UUID string used for delete + backup identity. Carries the same
/// `sourceID`/`recordedAt` provenance columns as the other stores.
@Model public final class StoredSite {
    public var siteID: String
    public var kind: String            // "pump" | "sensor"
    public var bodySide: String        // "front" | "back"
    public var normalizedX: Double
    public var normalizedY: Double
    public var note: String?
    public var date: Date
    public var sourceID: String
    public var recordedAt: Date
    public init(siteID: String, kind: String, bodySide: String,
                normalizedX: Double, normalizedY: Double, note: String?,
                date: Date, sourceID: String, recordedAt: Date) {
        self.siteID = siteID; self.kind = kind; self.bodySide = bodySide
        self.normalizedX = normalizedX; self.normalizedY = normalizedY
        self.note = note
        self.date = date; self.sourceID = sourceID; self.recordedAt = recordedAt
    }
}
