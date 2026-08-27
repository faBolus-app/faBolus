import Testing
import Foundation
@testable import faBolus

/// **G-M3 (phone half).** Pins `GarminImuWindowDecode` — the pure, ConnectIQ-free decode of the
/// out-of-band `imu_window` envelope, accepting BOTH the legacy v1 flat-`Float` envelope and the new
/// v2 compact int16 envelope 19-04's watch encoder will emit. Lives OUTSIDE `#if GARMIN` (Foundation
/// only — `Data`/`NSNumber`, no ConnectIQ import) so both wire versions get unit coverage in the
/// default (non-GARMIN) target.
///
/// WIRE CONTRACT (19-05 defines it; 19-04 `depends_on: [19-05]` and mirrors it EXACTLY):
///   - `ch` (Int) channel count, `n` (Int) samples per channel, sample-major layout (each sample's
///     `ch` channel values contiguous), oldest→newest — same layout in v1 and v2.
///   - v2 adds `scale` ([Number], length == `ch`) — one dequantization scale PER CHANNEL INDEX,
///     chosen/owned by the encoder and carried IN the envelope (never a hardcoded duplicate constant
///     on either side, so the two sides can never silently drift apart): `float = int16 * scale[ch]`.
///   - v2's `data` is the packed int16 "ByteArray": `n * ch * 2` raw bytes (0...255), little-endian
///     pairs, sample-major — OR (a defensive fallback, since the vendored ConnectIQ SDK's documented
///     message types are String/Number/Null/Array/Dictionary only, with no ByteArray/Data entry, so
///     the real bridged Swift type is genuinely unverified pre-device — DEFERRED OWNER) a `Data` value.
///
/// FAIL-SAFE (T-19-21): imu_window is advisory-only, never a dose input — ANY malformed, mismatched-
/// length, or oversized envelope decodes to an EMPTY array rather than a garbled/partial window.
struct GarminImuWindowDecodeTests {

    // MARK: v1 — unchanged legacy behavior

    @Test func v1FlatFloatArrayDecodesUnchanged() {
        let dict: [String: Any] = ["v": 1, "type": "imu_window", "data": [1.5, -2.25, 3.0] as [Any]]
        let out = GarminImuWindowDecode.decode(dict)
        #expect(out == [1.5, -2.25, 3.0])
    }

    /// No `v` key at all (an even older/legacy sender) must still decode as v1 — backward compatible.
    @Test func missingVersionKeyDefaultsToV1Decode() {
        let dict: [String: Any] = ["type": "imu_window", "data": [4.0, 5.0] as [Any]]
        #expect(GarminImuWindowDecode.decode(dict) == [4.0, 5.0])
    }

    @Test func v1MalformedDataDecodesEmpty() {
        let dict: [String: Any] = ["v": 1, "data": "not an array"]
        #expect(GarminImuWindowDecode.decode(dict).isEmpty)
    }

    // MARK: v2 — round-trips a synthetic quantizer (mirrors what 19-04's watch encoder will do)

    /// Test-only quantizer mirroring 19-04's Monkey C encoder: packs each channel's Float samples to
    /// int16 (round + clamp to the int16 range) using a fixed per-channel scale, little-endian byte
    /// pairs, sample-major — building the SAME envelope shape the production decoder must accept.
    private static func quantizeV2(samples: [Float], ch: Int, scale: [Double]) -> (bytes: [Int], scale: [Double]) {
        var bytes: [Int] = []
        bytes.reserveCapacity(samples.count * 2)
        for (i, sample) in samples.enumerated() {
            let s = scale[i % ch]
            let raw = (Double(sample) / s).rounded()
            let clamped = max(-32767.0, min(32767.0, raw))
            let int16Value = Int16(clamped)
            let bits = UInt16(bitPattern: int16Value)
            bytes.append(Int(bits & 0xFF))
            bytes.append(Int((bits >> 8) & 0xFF))
        }
        return (bytes, scale)
    }

    @Test func v2DequantizesWithinScaleResolutionOfOriginals() {
        let ch = 6, n = 10
        let scale: [Double] = [8.0 / 32767.0, 8.0 / 32767.0, 8.0 / 32767.0,
                                2000.0 / 32767.0, 2000.0 / 32767.0, 2000.0 / 32767.0]
        // Synthetic window: n*ch samples within each channel's assumed full-scale range.
        var samples: [Float] = []
        for i in 0..<(n * ch) {
            let chIdx = i % ch
            samples.append(chIdx < 3 ? Float(i % 5) - 2.0 : Float(i % 7) * 100.0 - 300.0)
        }
        let (bytes, sc) = Self.quantizeV2(samples: samples, ch: ch, scale: scale)
        let dict: [String: Any] = [
            "v": 2, "type": "imu_window", "ch": ch, "n": n, "fs": 25, "t0": 1_700_000_000,
            "scale": sc as [Any], "data": bytes as [Any]
        ]
        let out = GarminImuWindowDecode.decode(dict)
        #expect(out.count == samples.count)
        for i in 0..<samples.count {
            let resolution = scale[i % ch]
            #expect(abs(Double(out[i]) - Double(samples[i])) <= resolution + 1e-6,
                    "dequantized value must be within one scale-step of the original")
        }
    }

    @Test func v2SmallerThanV1PayloadForTheSameWindow() {
        // Not a wire-size assertion here (that's 19-04's job on the Monkey C side, per CONTEXT.md) —
        // just confirms the v2 element type (bytes, 0...255) is smaller-VALUED than v1's raw floats,
        // consistent with "compact" — a sanity check on this decoder's own contract, not a byte-count.
        let ch = 6, n = 150
        let scale = [Double](repeating: 8.0 / 32767.0, count: ch)
        let samples = [Float](repeating: 1.0, count: n * ch)
        let (bytes, sc) = Self.quantizeV2(samples: samples, ch: ch, scale: scale)
        #expect(bytes.allSatisfy { $0 >= 0 && $0 <= 255 })
        #expect(bytes.count == n * ch * 2)
        let dict: [String: Any] = ["v": 2, "ch": ch, "n": n, "scale": sc as [Any], "data": bytes as [Any]]
        #expect(GarminImuWindowDecode.decode(dict).count == n * ch)
    }

    // MARK: v2 fail-safe — malformed/oversized ⇒ empty (never garbled/partial, never a dose input)

    @Test func v2MissingScaleDecodesEmpty() {
        let dict: [String: Any] = ["v": 2, "ch": 6, "n": 10, "data": [Int](repeating: 0, count: 120) as [Any]]
        #expect(GarminImuWindowDecode.decode(dict).isEmpty)
    }

    @Test func v2ScaleLengthMismatchDecodesEmpty() {
        let dict: [String: Any] = [
            "v": 2, "ch": 6, "n": 10,
            "scale": [1.0, 2.0] as [Any],   // wrong length (should be 6)
            "data": [Int](repeating: 0, count: 120) as [Any]
        ]
        #expect(GarminImuWindowDecode.decode(dict).isEmpty)
    }

    @Test func v2DataByteCountMismatchDecodesEmpty() {
        let dict: [String: Any] = [
            "v": 2, "ch": 6, "n": 10,
            "scale": [Double](repeating: 1.0, count: 6) as [Any],
            "data": [Int](repeating: 0, count: 10) as [Any]   // should be 10*6*2 = 120
        ]
        #expect(GarminImuWindowDecode.decode(dict).isEmpty)
    }

    @Test func v2OversizedNChDecodesEmpty() {
        let dict: [String: Any] = [
            "v": 2, "ch": 6, "n": 100_000,   // n*ch far exceeds maxTotalSamples
            "scale": [Double](repeating: 1.0, count: 6) as [Any],
            "data": [Int](repeating: 0, count: 2) as [Any]
        ]
        #expect(GarminImuWindowDecode.decode(dict).isEmpty)
    }

    @Test func v2ZeroChOrZeroNDecodesEmpty() {
        #expect(GarminImuWindowDecode.decode(["v": 2, "ch": 0, "n": 10, "scale": [], "data": []]).isEmpty)
        #expect(GarminImuWindowDecode.decode(["v": 2, "ch": 6, "n": 0, "scale": [Double](repeating: 1.0, count: 6), "data": []]).isEmpty)
    }

    @Test func v2MissingChOrNDecodesEmpty() {
        #expect(GarminImuWindowDecode.decode(["v": 2, "n": 10, "scale": [], "data": []]).isEmpty)
        #expect(GarminImuWindowDecode.decode(["v": 2, "ch": 6, "scale": [], "data": []]).isEmpty)
    }

    @Test func v2ByteOutOfRangeDecodesEmpty() {
        let dict: [String: Any] = [
            "v": 2, "ch": 1, "n": 1,
            "scale": [1.0] as [Any],
            "data": [999] as [Any]   // not a valid byte (0...255)
        ]
        #expect(GarminImuWindowDecode.decode(dict).isEmpty)
    }

    /// A `Data` value for `data` (the defensive fallback shape) must ALSO decode correctly, in case the
    /// real device bridges ByteArray that way instead of as a Number array.
    @Test func v2DataAsFoundationDataAlsoDecodes() {
        let ch = 2, n = 2
        let scale: [Double] = [1.0, 2.0]
        let (bytesInt, sc) = Self.quantizeV2(samples: [1.0, 2.0, -1.0, -2.0], ch: ch, scale: scale)
        let data = Data(bytesInt.map { UInt8($0) })
        let dict: [String: Any] = ["v": 2, "ch": ch, "n": n, "scale": sc as [Any], "data": data]
        let out = GarminImuWindowDecode.decode(dict)
        #expect(out.count == 4)
        #expect(abs(Double(out[0]) - 1.0) < 0.01)
    }
}
