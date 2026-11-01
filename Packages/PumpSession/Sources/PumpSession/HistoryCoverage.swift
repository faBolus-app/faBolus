import Foundation

/// The pump history sequence numbers the phone already holds, as normalized ranges (sorted, no overlap
/// or adjacency). A set of ranges rather than a high-water mark, so it can say both "records logged
/// during a disconnect are missing" and "some older records are missing", and a sync fetches exactly the
/// windows still missing.
public struct HistoryCoverage: Codable, Equatable, Sendable {
    public private(set) var ranges: [ClosedRange<UInt32>]

    public init(ranges: [ClosedRange<UInt32>] = []) {
        self.ranges = Self.normalize(ranges)
    }

    /// The coverage with `range` merged in.
    public func inserting(_ range: ClosedRange<UInt32>) -> HistoryCoverage {
        HistoryCoverage(ranges: ranges + [range])
    }

    public func contains(_ seq: UInt32) -> Bool { ranges.contains { $0.contains(seq) } }

    /// The windows of the pump's range `first...last` not yet held, oldest first.
    public func missing(first: UInt32, last: UInt32) -> [ClosedRange<UInt32>] {
        guard first <= last else { return [] }
        var missing: [ClosedRange<UInt32>] = [first...last]
        for held in ranges {
            missing = missing.flatMap { m -> [ClosedRange<UInt32>] in
                guard held.overlaps(m) else { return [m] }
                var pieces: [ClosedRange<UInt32>] = []
                if m.lowerBound < held.lowerBound { pieces.append(m.lowerBound...(held.lowerBound - 1)) }
                if m.upperBound > held.upperBound { pieces.append((held.upperBound + 1)...m.upperBound) }
                return pieces
            }
        }
        return missing
    }

    private static func normalize(_ input: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        guard !input.isEmpty else { return [] }
        let sorted = input.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<UInt32>] = [sorted[0]]
        for r in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            // The +1 is guarded: a pathological UInt32.max must not trap.
            let touches =
                last.upperBound >= r.lowerBound
                || (last.upperBound != UInt32.max && last.upperBound + 1 == r.lowerBound)
            if touches {
                merged[merged.count - 1] = last.lowerBound...Swift.max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    // Codable by hand: ClosedRange<UInt32> encodes as [lower, upper].
    private enum CodingKeys: String, CodingKey { case ranges }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pairs = try c.decode([[UInt32]].self, forKey: .ranges)
        self.init(ranges: pairs.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ranges.map { [$0.lowerBound, $0.upperBound] }, forKey: .ranges)
    }
}
