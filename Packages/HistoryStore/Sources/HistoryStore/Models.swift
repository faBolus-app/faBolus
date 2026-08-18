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

/// A logged caffeine intake (LoopInsights benign tracker, 09.18d-02, D-14/D-17). A standalone,
/// informational log entry — never a dose input. Ports ONLY the mirror `CaffeineTracker`'s benign
/// field shape (milligrams / source / timestamp / stable id); the mirror's AI-prompt builder and
/// UserDefaults persistence are NOT ported (persistence is faBolus SwiftData here). `entryID` is a
/// stable UUID string for delete + backup identity; carries the same `sourceID`/`recordedAt`
/// provenance columns as the other stores.
@Model public final class StoredCaffeine {
    public var entryID: String
    public var milligrams: Double
    public var source: String
    public var date: Date
    public var sourceID: String
    public var recordedAt: Date
    public init(entryID: String, milligrams: Double, source: String,
                date: Date, sourceID: String, recordedAt: Date) {
        self.entryID = entryID; self.milligrams = milligrams; self.source = source
        self.date = date; self.sourceID = sourceID; self.recordedAt = recordedAt
    }
}

/// A logged alcohol intake (LoopInsights benign tracker, 09.18d-02, D-14/D-17). Informational log
/// entry only. Ports ONLY the mirror `AlcoholTracker`'s benign field shape (standardDrinks / source /
/// timestamp / stable id); the mirror's `computeHypoRisk` medical inference and AI-prompt builder are
/// NOT ported (D-14 — novel medical advice). `entryID` is a stable UUID string for delete + backup
/// identity; carries the same `sourceID`/`recordedAt` provenance columns as the other stores.
@Model public final class StoredAlcohol {
    public var entryID: String
    public var standardDrinks: Double
    public var source: String
    public var date: Date
    public var sourceID: String
    public var recordedAt: Date
    public init(entryID: String, standardDrinks: Double, source: String,
                date: Date, sourceID: String, recordedAt: Date) {
        self.entryID = entryID; self.standardDrinks = standardDrinks; self.source = source
        self.date = date; self.sourceID = sourceID; self.recordedAt = recordedAt
    }
}
