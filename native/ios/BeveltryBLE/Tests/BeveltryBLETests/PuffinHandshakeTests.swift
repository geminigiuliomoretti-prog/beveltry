import Foundation
import XCTest
@testable import BeveltryBLE

private final class MockPuffinTransport: PuffinTransport {
    let incomingFrames: AsyncStream<(PuffinFrame, PuffinCharacteristic)>
    private let continuation: AsyncStream<(PuffinFrame, PuffinCharacteristic)>.Continuation
    var writes: [(Data, PuffinCharacteristic)] = []
    var subscriptions: [PuffinCharacteristic] = []
    var initialClock: UInt32 = UInt32(Date().timeIntervalSince1970)
    var clockWillLatch = true
    var failClockSet = false
    var failFlagName: String?
    var withholdHelloAck = false
    var commandStatus: UInt8 = 1
    var clockStatus: UInt8 = 1
    var legacyAckLayout = false
    var historicalFrames: [(Data, PuffinCharacteristic)] = [
        (makeHistoricalInner([0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87]), .dataFromStrap)
    ]
    var flagWrites: [PuffinFrame] = []
    var clockSetFrames: [PuffinFrame] = []
    var ackFrames: [PuffinFrame] = []
    private var clockReads = 0
    private var latchedClock: UInt32?

    init() {
        let pair = AsyncStream<(PuffinFrame, PuffinCharacteristic)>.makeStream()
        incomingFrames = pair.stream
        continuation = pair.continuation
    }

    func subscribe(to characteristic: PuffinCharacteristic) async throws {
        subscriptions.append(characteristic)
    }

    func write(_ frameData: Data, to characteristic: PuffinCharacteristic) async throws {
        writes.append((frameData, characteristic))
        let frame = try PuffinFrameCodec.decode(frameData)
        let raw = Array(frame.rawPayload)
        guard raw.count >= 3 else { return }
        let seq = raw[1]
        let opcode = raw[2]
        switch opcode {
        case 0x91:
            if !withholdHelloAck { emitAck(sequence: seq, opcode: opcode, status: commandStatus) }
        case 0x0B:
            clockReads += 1
            let timestamp: UInt32
            if clockReads == 1 {
                timestamp = initialClock
            } else if clockWillLatch, let latchedClock {
                timestamp = latchedClock
            } else {
                timestamp = 0
            }
            var response: [UInt8] = [0x24, seq, opcode, 0x77, clockStatus]
            appendLE(timestamp, to: &response)
            emit(response, on: .cmdFromStrap)
        case 0x0A:
            clockSetFrames.append(frame)
            latchedClock = readU32(raw, 4)
            emitAck(sequence: seq, opcode: opcode, status: failClockSet ? 2 : commandStatus)
        case 0x73:
            emitAck(sequence: seq, opcode: opcode, status: 1)
        case 0x78:
            flagWrites.append(frame)
            let nameBytes = raw[4..<36].prefix { $0 != 0 }
            let name = String(bytes: nameBytes, encoding: .ascii)
            let status: UInt8 = name == failFlagName ? 2 : commandStatus
            emitAck(sequence: seq, opcode: opcode, status: status)
        case 0x22:
            emit(legacyAckLayout ? [0x24, seq, opcode, commandStatus] : [0x24, seq, opcode, 0x77, commandStatus], on: .cmdFromStrap)
        case 0x16:
            historicalFrames.forEach { emit(Array($0.0), on: $0.1) }
        case 0x17:
            ackFrames.append(frame)
        default:
            break
        }
    }

    private func emitAck(sequence: UInt8, opcode: UInt8, status: UInt8) {
        emit(legacyAckLayout ? [0x24, sequence, opcode, status] : [0x24, sequence, opcode, 0x77, status], on: .cmdFromStrap)
    }

    private func emit(_ payload: [UInt8], on characteristic: PuffinCharacteristic) {
        guard let encoded = try? PuffinFrameCodec.encode(field: 1, payload: Data(payload)),
              let frame = try? PuffinFrameCodec.decode(encoded) else { return }
        continuation.yield((frame, characteristic))
    }

    private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private func appendLE(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

private func makeHistoricalInner(_ cursor: [UInt8]) -> Data {
    var payload = [UInt8](repeating: 0, count: 40)
    payload[0] = 0x31
    payload.replaceSubrange(13..<21, with: cursor)
    return Data(payload)
}

private func makeV18Inner(_ timestamp: UInt32) -> Data {
    var payload = [UInt8](repeating: 0, count: 112)
    payload[0] = 0x2F
    payload[1] = 0x12
    for index in 0..<4 { payload[7 + index] = UInt8(truncatingIfNeeded: timestamp >> (8 * index)) }
    return Data(payload)
}

private final class MockHandshakeDelegate: PuffinHandshakeDelegate {
    var states: [HandshakeState] = []
    var received: [PuffinFrame] = []
    var failures: [PuffinHandshakeError] = []

    func handshake(_ handshake: PuffinHandshake, didChangeState state: HandshakeState) { states.append(state) }
    func handshake(_ handshake: PuffinHandshake, didReceiveRawFrame frame: PuffinFrame) { received.append(frame) }
    func handshake(_ handshake: PuffinHandshake, didFailWith error: PuffinHandshakeError) { failures.append(error) }
}

final class PuffinHandshakeTests: XCTestCase {
    func testHappyPathCompletesBootstrapBeforeHistoricalStreaming() async throws {
        let transport = MockPuffinTransport()
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()

        XCTAssertEqual(handshake.state, .ready)
        XCTAssertEqual(transport.subscriptions, [.cmdFromStrap, .eventsFromStrap, .dataFromStrap])
        XCTAssertEqual(transport.flagWrites.count, 32)
        XCTAssertEqual(transport.ackFrames.count, 0)
        XCTAssertEqual(transport.writes.first?.0,
                       Data([0xAA, 0x01, 0x08, 0x00, 0x01, 0x00, 0x26, 0x21,
                             0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D]))
        for try await _ in handshake.offloadHistorical(timeout: 0.05) { }
        XCTAssertEqual(handshake.state, .ready)
        XCTAssertEqual(transport.ackFrames.count, 1)
        XCTAssertEqual(Array(transport.ackFrames[0].rawPayload[4..<12]), [0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87])
        let expectedFlags: [(String, UInt8)] = [
            ("enable_r22_packets", 2), ("enable_r22_v2_packets", 2),
            ("enable_r22_v3_packets", 2), ("enable_r22_v4_packets", 1),
            ("enable_r22_v5_packets", 2), ("enable_r22_v6_packets", 2),
            ("enable_r22_v8_packets", 2), ("make_hrfm_visible", 2),
            ("disable_pip_r26_packets", 2), ("wear_detect_bias", 2),
            ("hr_ch_switching", 2), ("ir_hw_switching", 2),
            ("enable_passive_strap_fit_gen5", 1), ("enable_sig11_during_sleep", 2),
            ("dorset_inhibit_wpt", 2), ("enable_sig12", 2)
        ]
        for (index, expected) in expectedFlags.enumerated() {
            for duplicate in 0..<2 {
                let raw = transport.flagWrites[index * 2 + duplicate].rawPayload
                XCTAssertEqual(String(bytes: raw[4..<36].prefix { $0 != 0 }, encoding: .ascii), expected.0)
                XCTAssertEqual(raw[36], expected.1)
            }
        }
        let keyFrame = try XCTUnwrap(transport.writes.compactMap { try? PuffinFrameCodec.decode($0.0) }
            .first { $0.rawPayload.count == 40 && $0.rawPayload[2] == 0x73 })
        XCTAssertEqual(keyFrame.rawPayload[4], 0x01)
        XCTAssertEqual(keyFrame.rawPayload[5..<37].count, 32)
        XCTAssertEqual(Array(keyFrame.rawPayload[37..<40]), [0, 0, 0])
    }

    func testValidClockIsStillSetAndSetClockBytesMatchFormat() async throws {
        let transport = MockPuffinTransport()
        transport.initialClock = UInt32(Date().timeIntervalSince1970)
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()

        XCTAssertEqual(transport.clockSetFrames.count, 1)
        let raw = Array(transport.clockSetFrames[0].rawPayload)
        XCTAssertEqual(Array(raw[0..<4]), [0x23, raw[1], 0x0A, 0x01])
        XCTAssertEqual(raw.count, 8)
        let timestamp = UInt32(raw[4]) | (UInt32(raw[5]) << 8) | (UInt32(raw[6]) << 16) | (UInt32(raw[7]) << 24)
        XCTAssertLessThanOrEqual(abs(Int64(timestamp) - Int64(Date().timeIntervalSince1970)), 2)
        let expectedPayload = Data([0x23, raw[1], 0x0A, 0x01, raw[4], raw[5], raw[6], raw[7]])
        let expectedFrame = try PuffinFrameCodec.encode(field: 1, payload: expectedPayload)
        let wireFrame = try XCTUnwrap(transport.writes.first(where: {
            (try? PuffinFrameCodec.decode($0.0).rawPayload[2]) == 0x0A
        })?.0)
        XCTAssertEqual(wireFrame, expectedFrame)
    }

    func testStatusZeroAndClockResponseAtByteFiveAreAccepted() async throws {
        let transport = MockPuffinTransport()
        transport.initialClock = 1_793_679_344
        transport.commandStatus = 0
        transport.clockStatus = 0
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()
        XCTAssertEqual(handshake.state, .ready)
        XCTAssertEqual(transport.clockSetFrames.count, 1)
    }

    func testFourByteCommandResponseUsesByteThreeForStatus() async throws {
        let transport = MockPuffinTransport()
        transport.commandStatus = 0
        transport.clockStatus = 0
        transport.legacyAckLayout = true
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()
        XCTAssertEqual(handshake.state, .ready)
    }

    func testZeroClockTimestampWarnsAndReachesReady() async throws {
        let transport = MockPuffinTransport()
        transport.initialClock = 0
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()
        XCTAssertEqual(handshake.state, .ready)
    }

    func testGetHelloTimeoutFailsHandshake() async {
        let transport = MockPuffinTransport()
        transport.withholdHelloAck = true
        let delegate = MockHandshakeDelegate()
        let handshake = PuffinHandshake(transport: transport, delegate: delegate, timeout: 0.01)
        do {
            try await handshake.start()
            XCTFail("Era atteso un timeout")
        } catch let error as PuffinHandshakeError {
            XCTAssertEqual(error, .ackTimeout(opcode: 0x91))
            XCTAssertEqual(handshake.state, .failed(.ackTimeout(opcode: 0x91)))
            XCTAssertEqual(delegate.failures, [.ackTimeout(opcode: 0x91)])
        } catch {
            XCTFail("Errore inatteso: \(error)")
        }
    }

    func testOptionalStepFailuresWarnAndContinueToReady() async throws {
        let transport = MockPuffinTransport()
        transport.failClockSet = true
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()
        XCTAssertEqual(handshake.state, .ready)

        let flagTransport = MockPuffinTransport()
        flagTransport.failFlagName = "enable_r22_packets"
        let flagHandshake = PuffinHandshake(transport: flagTransport, delegate: nil, timeout: 0.2)
        try await flagHandshake.start()
        XCTAssertEqual(flagHandshake.state, .ready)
    }

    func testHelloStatusErrorFailsHandshake() async {
        let transport = MockPuffinTransport()
        transport.commandStatus = 0xFF
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        do {
            try await handshake.start()
            XCTFail("Era atteso un fallimento status")
        } catch let error as PuffinHandshakeError {
            XCTAssertEqual(error, .ackStatusFailure(opcode: 0x91, status: 0xFF))
        } catch {
            XCTFail("Errore inatteso: \(error)")
        }
    }

    func testHistoricalStreamAcknowledgesThreeDistinctCursors() async throws {
        let transport = MockPuffinTransport()
        let cursors = (0..<3).map { index in (0..<8).map { UInt8(index * 10 + $0) } }
        transport.historicalFrames = cursors.map { (makeHistoricalInner($0), .dataFromStrap) }
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()
        for try await _ in handshake.offloadHistorical(timeout: 0.05) { }
        XCTAssertEqual(transport.ackFrames.count, 3)
        XCTAssertEqual(transport.ackFrames.map { Array($0.rawPayload[4..<12]) }, cursors)
        XCTAssertTrue(transport.ackFrames.allSatisfy { $0.rawPayload[2] == 0x17 && $0.rawPayload[3] == 0x01 })
    }

    func testRepeatedCursorIsAcknowledgedOnce() async throws {
        let cursor: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let transport = MockPuffinTransport()
        transport.historicalFrames = [makeHistoricalInner(cursor), makeHistoricalInner(cursor)].map { ($0, .dataFromStrap) }
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()
        for try await _ in handshake.offloadHistorical(timeout: 0.05) { }
        XCTAssertEqual(transport.ackFrames.count, 1)
    }

    func testHistoricalStreamDeliversFiveRecordsWithoutAcknowledgingThem() async throws {
        let cursor: [UInt8] = [8, 7, 6, 5, 4, 3, 2, 1]
        let timestamp: UInt32 = 1_793_679_344
        let transport = MockPuffinTransport()
        transport.historicalFrames = (0..<5).map { _ in (makeV18Inner(timestamp), .dataFromStrap) }
            + [(makeHistoricalInner(cursor), .dataFromStrap)]
        var delivered: [PuffinFrame] = []
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()
        for try await _ in handshake.offloadHistorical(timeout: 0.05, onRecord: { delivered.append($0) }) { }
        XCTAssertEqual(delivered.count, 5)
        XCTAssertEqual(transport.ackFrames.count, 1)
        XCTAssertEqual(transport.ackFrames[0].rawPayload[2], 0x17)
    }

    func testFlagFrameHasExpectedWireSizeAndLength() async throws {
        let transport = MockPuffinTransport()
        let handshake = PuffinHandshake(transport: transport, delegate: nil, timeout: 0.2)
        try await handshake.start()
        let firstFlag = try XCTUnwrap(transport.flagWrites.first)
        let flagWire = try XCTUnwrap(transport.writes.first(where: {
            guard let decoded = try? PuffinFrameCodec.decode($0.0) else { return false }
            return decoded.rawPayload.count == 40 && decoded.rawPayload[2] == 0x78
        })?.0)
        XCTAssertEqual(flagWire.count, 52)
        XCTAssertEqual(UInt16(flagWire[2]) | (UInt16(flagWire[3]) << 8), 44)
        XCTAssertEqual(firstFlag.rawPayload.count, 40)
        XCTAssertEqual(String(bytes: firstFlag.rawPayload[4..<36].prefix { $0 != 0 }, encoding: .ascii), "enable_r22_packets")
    }
}
