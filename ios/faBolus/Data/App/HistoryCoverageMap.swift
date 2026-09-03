import Foundation

/// Persisted map of the pump history-log sequence ranges the phone already holds. Replaces the
/// boolean `didBackfill` gate — a SET of ranges (not a single high-water mark) can express both "the
/// phone missed records logged during a disconnect" (a trailing/forward gap) and "the phone has some but
/// not all past data" (an interior/non-sequential gap), which is exactly what
/// `TandemBackend.missingRanges` needs to compute the exact windows still worth fetching.
///
/// Persisted as JSON-in-UserDefaults, `backsUp: false` (derived/rebuildable local cache, not a user
/// preference; see `SettingsCatalog`'s "historyCoverage" row).
public struct HistoryCoverageMap: Codable, Equatable, Sendable {
    /// Held sequence ranges, always normalized (sorted ascending, no overlaps or adjacency) — the
    /// invariant `inserting(_:)` maintains, so callers never need to normalize separately.
    public private(set) var ranges: [ClosedRange<UInt32>]

    public init(ranges: [ClosedRange<UInt32>] = []) {
        self.ranges = HistoryCoverageMap.normalize(ranges)
    }

    /// Returns a new map with `range` merged in, coalescing it with any overlapping or directly-adjacent
    /// held range so a single contiguous span fetched across multiple pages/windows collapses into one
    /// entry instead of growing the held-range list unboundedly.
    public func inserting(_ range: ClosedRange<UInt32>) -> HistoryCoverageMap {
        HistoryCoverageMap(ranges: ranges + [range])
    }

    /// `true` if `seq` falls within any held range.
    public func contains(_ seq: UInt32) -> Bool {
        ranges.contains { $0.contains(seq) }
    }

    private static func normalize(_ input: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        guard !input.isEmpty else { return [] }
        let sorted = input.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<UInt32>] = [sorted[0]]
        for r in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            // Overlapping, or directly adjacent (last.upperBound + 1 == r.lowerBound) — guard the +1
            // against UInt32.max overflow (the pump's sequence numbers are real-world bounded, but the
            // arithmetic must never trap on a pathological/adversarial value).
            let adjacentOrOverlapping =
                last.upperBound >= r.lowerBound
                || (last.upperBound != UInt32.max && last.upperBound + 1 == r.lowerBound)
            if adjacentOrOverlapping {
                merged[merged.count - 1] = last.lowerBound...Swift.max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}
