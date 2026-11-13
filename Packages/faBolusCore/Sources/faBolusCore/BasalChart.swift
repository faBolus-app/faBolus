import Foundation

/// A change in what the pump delivers, from its history: a new basal rate, or pumping stopped or started.
public struct DeliveryChange: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case basalRate, suspended, resumed
    }

    public let date: Date
    public let kind: Kind
    /// The new rate in U/h, for `basalRate`; 0 otherwise.
    public let unitsPerHour: Double

    public init(date: Date, kind: Kind, unitsPerHour: Double = 0) {
        self.date = date
        self.kind = kind
        self.unitsPerHour = kind == .basalRate ? unitsPerHour : 0
    }
}

/// The chart's basal line and suspended spans, as t:connect draws them: the basal rate steps at each rate
/// change and is 0 while pumping is suspended, and each suspend runs to the next resume, or to now when
/// none has come. Unlike t:connect, a long gap between records isn't drawn as a suspension: a gap is
/// history not yet read, not a pump that stopped.
public struct BasalChart: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let unitsPerHour: Double
    }

    /// Oldest first. None before the first rate the history holds: the rate then is unknown.
    public let steps: [Step]
    /// Oldest first.
    public let suspensions: [ClosedRange<Date>]

    /// The chart for `changes` between `start` and `now`. `changes` may hold changes from before `start`,
    /// so a rate or a suspension already under way is drawn from the window's edge.
    public init(changes: [DeliveryChange], from start: Date, to now: Date) {
        var steps: [Step] = []
        var suspensions: [ClosedRange<Date>] = []
        var rate: Double?
        var suspendedSince: Date?
        var since = start
        func close(at date: Date) {
            let lo = max(since, start), hi = min(date, now)
            if let rate, lo < hi {
                steps.append(Step(start: lo, end: hi, unitsPerHour: suspendedSince == nil ? rate : 0))
            }
            since = date
        }
        // Oldest first; changes at one time keep the order given (the pump's record order), as a plain sort
        // doesn't promise.
        let ordered = changes.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
        for change in ordered.map(\.element) where change.date <= now {
            switch change.kind {
            case .basalRate:
                close(at: change.date)
                rate = change.unitsPerHour
            case .suspended:
                guard suspendedSince == nil else { continue }
                close(at: change.date)
                suspendedSince = change.date
            case .resumed:
                guard let from = suspendedSince else { continue }
                close(at: change.date)
                suspendedSince = nil
                if change.date > start { suspensions.append(max(from, start)...change.date) }
            }
        }
        close(at: now)
        if let from = suspendedSince { suspensions.append(max(from, start)...now) }
        self.steps = steps
        self.suspensions = suspensions
    }
}
