// Adapted from LoopKit's DoseEntry (LoopKit/LoopKit `a5beee96`, InsulinKit/DoseEntry.swift),
// Copyright © 2016 Nathan Racklyeft, MIT License: the field names and the programmed-versus-delivered
// split, without HealthKit and with only the bolus type this app reads.

import Foundation

/// A bolus as the pump records it: what was programmed, and what went in once the pump says.
public struct DoseEntry: Sendable, Hashable, Codable {
    /// When delivery started.
    public let startDate: Date
    /// When delivery ended or is expected to end. Equal to `startDate` for a bolus delivered now.
    public let endDate: Date
    /// The units the pump was asked for.
    public let programmedUnits: Double
    /// The units the pump says went in. `nil` until the pump reports it.
    public let deliveredUnits: Double?
    /// The pump's bolus ID, so the same bolus from a status read and from history is recognized as one.
    public let syncIdentifier: String?

    public init(
        startDate: Date, endDate: Date? = nil, programmedUnits: Double, deliveredUnits: Double? = nil,
        syncIdentifier: String? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate ?? startDate
        self.programmedUnits = programmedUnits
        self.deliveredUnits = deliveredUnits
        self.syncIdentifier = syncIdentifier
    }
}
