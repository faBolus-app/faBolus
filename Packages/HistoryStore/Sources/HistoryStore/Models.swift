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
        self.date = date
        self.mgdl = mgdl
        self.sourceID = sourceID
        self.priority = priority
        self.recordedAt = recordedAt
    }
}

@Model public final class StoredBolus {
    public var date: Date
    public var units: Double
    public var sourceID: String
    public var recordedAt: Date
    public init(date: Date, units: Double, sourceID: String, recordedAt: Date) {
        self.date = date
        self.units = units
        self.sourceID = sourceID
        self.recordedAt = recordedAt
    }
}

@Model public final class StoredCarb {
    public var date: Date
    public var grams: Double
    public var sourceID: String
    public var recordedAt: Date
    public init(date: Date, grams: Double, sourceID: String, recordedAt: Date) {
        self.date = date
        self.grams = grams
        self.sourceID = sourceID
        self.recordedAt = recordedAt
    }
}

/// A basal rate change, a suspend or a resume from pump history, for the chart's basal line.
@Model public final class StoredDeliveryChange {
    public var date: Date
    /// `DeliveryChange.Kind`'s raw value.
    public var kind: String
    public var unitsPerHour: Double
    public var sourceID: String
    public var recordedAt: Date
    public init(date: Date, kind: String, unitsPerHour: Double, sourceID: String, recordedAt: Date) {
        self.date = date
        self.kind = kind
        self.unitsPerHour = unitsPerHour
        self.sourceID = sourceID
        self.recordedAt = recordedAt
    }
}

/// One logbook entry from pump history, kept so the logbook comes back after a relaunch: history the
/// phone already holds isn't fetched from the pump again.
@Model public final class StoredHistoryEvent {
    /// The pump's sequence number.
    public var sequence: Int
    public var date: Date
    public var category: String
    public var title: String
    public var detail: String
    public var sourceID: String
    public init(sequence: Int, date: Date, category: String, title: String, detail: String, sourceID: String) {
        self.sequence = sequence
        self.date = date
        self.category = category
        self.title = title
        self.detail = detail
        self.sourceID = sourceID
    }
}
