//
//  Ported from CGMBLEKit's GlucoseRxMessageTests, TransmitterTimeRxMessageTests and
//  GlucoseBackfillMessageTests (MIT), keeping their fixtures and expectations.
//  Copyright © 2016 Nathan Racklyeft; © 2018 LoopKit Authors.
//

import DexcomBLE
import Foundation
import Testing

@testable import DexcomG6

@Suite("G6 messages (CGMBLEKit fixtures)")
struct G6MessageTests {
    @Test func glucoseMessageData() throws {
        let message = try #require(GlucoseRxMessage(data: hex("3100680a00008a715700cc0006ffc42a")))
        #expect(message.status == 0)
        #expect(message.sequence == 2664)
        #expect(message.glucose.timestamp == 5_730_698)
        #expect(!message.glucose.glucoseIsDisplayOnly)
        #expect(message.glucose.glucose == 204)
        #expect(message.glucose.state == 6)
        #expect(message.glucose.trend == -1)
    }

    @Test func glucoseNegativeTrend() throws {
        let message = try #require(GlucoseRxMessage(data: hex("31006f0a0000be7957007a0006e4818d")))
        #expect(message.sequence == 2671)
        #expect(message.glucose.timestamp == 5_732_798)
        #expect(message.glucose.glucose == 122)
        #expect(message.glucose.trend == -28)
    }

    @Test func glucoseDisplayOnly() throws {
        let message = try #require(GlucoseRxMessage(data: hex("3100700a0000f17a5700584006e3cee9")))
        #expect(message.sequence == 2672)
        #expect(message.glucose.timestamp == 5_733_105)
        #expect(message.glucose.glucoseIsDisplayOnly)
        #expect(message.glucose.glucose == 88)
        #expect(message.glucose.trend == -29)
    }

    @Test func glucoseOldTransmitter() throws {
        let message = try #require(GlucoseRxMessage(data: hex("3100aa00000095a078008b00060a8b34")))
        #expect(message.sequence == 170)
        #expect(message.glucose.timestamp == 7_905_429)  // 90 days, status is still OK
        #expect(message.glucose.glucose == 139)
        #expect(message.glucose.trend == 10)
    }

    @Test func glucoseZeroSequence() throws {
        let message = try #require(GlucoseRxMessage(data: hex("3100000000008eb14d00820006f6a038")))
        #expect(message.sequence == 0)
        #expect(message.glucose.timestamp == 5_091_726)
        #expect(message.glucose.glucose == 130)
        #expect(message.glucose.state == 6)
        #expect(message.glucose.trend == -10)
    }

    @Test func glucoseRejectsBadCRCAndWrongOpcode() {
        #expect(GlucoseRxMessage(data: hex("3100000000008eb14d00820006f6a039")) == nil)
        #expect(GlucoseRxMessage(data: hex("2500beb24d00f22d4d000100000083c0")) == nil)
    }

    @Test func timeNoSession() throws {
        for (frame, time) in [
            ("2500e8f87100ffffffff010000000a70", 7_469_288), ("250096fd7100ffffffff01000000226d", 7_470_486),
            ("2500eeff7100ffffffff010000008952", 7_471_086)
        ] {
            let message = try #require(TransmitterTimeRxMessage(data: hex(frame)))
            #expect(message.status == 0)
            #expect(message.currentTime == UInt32(time))
            #expect(message.sessionStartTime == 0xffff_ffff)
            #expect(!message.hasValidSensorSession)
        }
    }

    @Test func timeInSession() throws {
        var message = try #require(TransmitterTimeRxMessage(data: hex("2500470272007cff710001000000fa1d")))
        #expect(message.currentTime == 7_471_687)
        #expect(message.sessionStartTime == 7_470_972)
        #expect(message.hasValidSensorSession)

        message = try #require(TransmitterTimeRxMessage(data: hex("2500beb24d00f22d4d000100000083c0")))
        #expect(message.currentTime == 5_092_030)
        #expect(message.sessionStartTime == 5_058_034)
        #expect(message.hasValidSensorSession)
    }

    @Test func backfillReplyAndBuffer() throws {
        let message = try #require(GlucoseBackfillRxMessage(data: hex("51000100b7ff52006604530032000000e6cb9805")))
        #expect(TransmitterStatus(rawValue: message.status) == .ok)
        #expect(message.backfillStatus == 1)
        #expect(message.identifier == 0)
        #expect(message.startTime == 5_439_415)
        #expect(message.endTime == 5_440_614)
        #expect(message.bufferLength == 50)
        #expect(message.bufferCRC == 0xcbe6)

        var buffer = GlucoseBackfillFrameBuffer(identifier: message.identifier)
        buffer.append(hex("0100bc460000b7ff52008b0006eee30053008500"))
        buffer.append(hex("020006eb0f025300800006ee3a0353007e0006f5"))
        buffer.append(hex("030066045300790006f8"))
        #expect(Int(message.bufferLength) == buffer.count)
        #expect(message.bufferCRC == buffer.crc16)

        let messages = buffer.glucose
        #expect(messages.map(\.glucose) == [139, 133, 128, 126, 121])
        #expect(messages.map(\.timestamp) == [5_439_415, 5_439_715, 5_440_015, 5_440_314, 5_440_614])
        #expect(messages.map(\.trend) == [-18, -21, -18, -11, -8])
        #expect(messages.allSatisfy { CalibrationState(rawValue: $0.state) == .known(.ok) })
    }

    @Test func backfillMalformedFrameKeepsWholeReadings() {
        var buffer = GlucoseBackfillFrameBuffer(identifier: 0)
        buffer.append(hex("0100bc460000b7ff52008b0006eee30053008500"))
        buffer.append(hex("020006eb0f025300800006ee3a0353007e0006"))
        #expect(buffer.glucose.count == 3)
    }

    @Test func backfillFrameOutOfOrderIsDropped() {
        var buffer = GlucoseBackfillFrameBuffer(identifier: 0x80)
        buffer.append(hex("028007ff956c0e005e000700c16d0e005d000700"))
        #expect(buffer.count == 0)
    }
}
