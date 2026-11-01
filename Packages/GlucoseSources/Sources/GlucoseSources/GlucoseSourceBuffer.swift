import Foundation
import faBolusCore

/// The readings a source holds: its latest, 24 hours of history and the newest below-range time.
/// Shared by every source so they agree on how a new batch is merged.
struct GlucoseSourceBuffer: Sendable, Equatable {
    static let historyWindow: TimeInterval = 24 * 3600
    static let bucket: TimeInterval = 5 * 60

    private(set) var latest: GlucoseSample?
    private(set) var history: [GlucoseReading] = []
    private(set) var belowRangeAt: Date?

    /// Adds a batch. `latest` only moves forward in time: a late or repeated poll can't step it back,
    /// and an equal time doesn't replace it. History keeps one reading per 5-minute bucket, the
    /// newest batch winning, for the last 24 hours.
    mutating func add(_ samples: [GlucoseSample], belowRange: [Date] = [], now: Date) {
        if let newest = samples.max(by: { $0.date < $1.date }), latest.map({ newest.date > $0.date }) ?? true {
            latest = newest
        }
        if let newestLow = belowRange.max(), belowRangeAt.map({ newestLow > $0 }) ?? true {
            belowRangeAt = newestLow
        }
        guard !samples.isEmpty else { return }
        var byBucket: [Int: GlucoseReading] = [:]
        for reading in history + samples.map(\.reading) {
            byBucket[Int((reading.date.timeIntervalSince1970 / Self.bucket).rounded(.down))] = reading
        }
        let cutoff = now.addingTimeInterval(-Self.historyWindow)
        history = byBucket.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    /// Splits raw readings into samples and below-range times. A value under the plausible range is
    /// the sensor's "LOW": never a sample (it can't fill a correction), but kept for the urgent-low
    /// alarm. A value over the range is decode garbage and dropped, as is zero or less.
    static func partition(
        _ readings: [(mgdl: Int, date: Date, trend: GlucoseTrend?)], sourceID: String
    ) -> (samples: [GlucoseSample], belowRange: [Date]) {
        var samples: [GlucoseSample] = []
        var belowRange: [Date] = []
        for reading in readings where reading.mgdl > 0 {
            if let sample = GlucoseSample(
                mgdl: reading.mgdl, date: reading.date, trend: reading.trend, sourceID: sourceID)
            {
                samples.append(sample)
            } else if reading.mgdl < GlucosePlausibility.minimum {
                belowRange.append(reading.date)
            }
        }
        return (samples, belowRange)
    }
}

/// Hands each `updates()` caller its own stream of a source's state.
struct GlucoseSourceUpdates: Sendable {
    private var continuations: [UUID: AsyncStream<GlucoseSourceState>.Continuation] = [:]

    mutating func stream(onEnd: @escaping @Sendable (UUID) -> Void) -> AsyncStream<GlucoseSourceState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GlucoseSourceState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        continuation.onTermination = { _ in onEnd(id) }
        continuations[id] = continuation
        return stream
    }

    mutating func remove(_ id: UUID) {
        continuations[id] = nil
    }

    func yield(_ state: GlucoseSourceState) {
        for continuation in continuations.values { continuation.yield(state) }
    }
}

/// The status a source reports: a problem always shows; otherwise connected while its newest reading
/// (a LOW counts) is fresh and stale once it isn't. Freshness comes from the measurement time.
func reportedStatus(_ buffer: GlucoseSourceBuffer, link: GlucoseSourceStatus, now: Date) -> GlucoseSourceStatus {
    if case .unavailable = link { return link }
    let newest = [buffer.latest?.date, buffer.belowRangeAt].compactMap { $0 }.max()
    if let newest, !GlucoseFreshness.isStale(newest, now: now) { return .connected }
    return link == .connected ? .stale : link
}
