import Foundation

public enum PuffinHandshakeError: Error, Equatable {
    case ackTimeout(opcode: UInt8)
    case ackStatusFailure(opcode: UInt8, status: UInt8)
    case clockNotLatched
    case unexpectedResponse(opcode: UInt8)
    case cancelled
    case transportFailure(String)
}

public enum HandshakeState: Equatable {
    case idle
    case connecting
    case bonding
    case subscribing
    case sendingHello
    case readingClock
    case settingClock
    case verifyingClock
    case keyExchange
    case settingFlags(current: Int, total: Int)
    case queryingRange
    case startingHistorical
    case ready
    case offloadStarted
    case failed(PuffinHandshakeError)
}

public struct OffloadProgress: Equatable, Sendable {
    public let recordsReceived: Int
    public let cursorsAcknowledged: Int
    public let lastSeenTimestamp: Date?
    public let completed: Bool
    public let timedOut: Bool

    public init(recordsReceived: Int, cursorsAcknowledged: Int, lastSeenTimestamp: Date?, completed: Bool, timedOut: Bool) {
        self.recordsReceived = recordsReceived
        self.cursorsAcknowledged = cursorsAcknowledged
        self.lastSeenTimestamp = lastSeenTimestamp
        self.completed = completed
        self.timedOut = timedOut
    }
}

public protocol PuffinHandshakeDelegate: AnyObject {
    func handshake(_ handshake: PuffinHandshake, didChangeState state: HandshakeState)
    func handshake(_ handshake: PuffinHandshake, didReceiveRawFrame frame: PuffinFrame)
    func handshake(_ handshake: PuffinHandshake, didFailWith error: PuffinHandshakeError)
}

public final class PuffinHandshake {
    public private(set) var state: HandshakeState = .idle

    private weak var delegate: PuffinHandshakeDelegate?
    private let transport: PuffinTransport
    private let timeout: TimeInterval
    private var sequence: UInt8 = 1
    private var operation: Task<Void, Error>?
    private var offloadOperation: Task<Void, Never>?
    private var activeReader: FrameIteratorBox?
    private var didReportFailure = false

    private static let field: UInt16 = 0x0001
    private static let flags: [(String, UInt8)] = [
        ("enable_r22_packets", 2),
        ("enable_r22_v2_packets", 2),
        ("enable_r22_v3_packets", 2),
        ("enable_r22_v4_packets", 1),
        ("enable_r22_v5_packets", 2),
        ("enable_r22_v6_packets", 2),
        ("enable_r22_v8_packets", 2),
        ("make_hrfm_visible", 2),
        ("disable_pip_r26_packets", 2),
        ("wear_detect_bias", 2),
        ("hr_ch_switching", 2),
        ("ir_hw_switching", 2),
        ("enable_passive_strap_fit_gen5", 1),
        ("enable_sig11_during_sleep", 2),
        ("dorset_inhibit_wpt", 2),
        ("enable_sig12", 2)
    ]

    /// Il trasporto deve essere già connesso e bonded prima di chiamare start().
    public init(transport: PuffinTransport, delegate: PuffinHandshakeDelegate?, timeout: TimeInterval = 3) {
        self.transport = transport
        self.delegate = delegate
        self.timeout = max(0.001, timeout)
    }

    public func start() async throws {
        guard state == .idle else { throw PuffinHandshakeError.unexpectedResponse(opcode: 0) }
        let task = Task { try await self.run() }
        operation = task
        defer { operation = nil }
        do {
            try await task.value
        } catch let error as PuffinHandshakeError {
            fail(error)
            throw error
        } catch is CancellationError {
            fail(.cancelled)
            throw PuffinHandshakeError.cancelled
        } catch {
            let failure = PuffinHandshakeError.transportFailure(String(describing: error))
            fail(failure)
            throw failure
        }
    }

    public func cancel() {
        operation?.cancel()
        offloadOperation?.cancel()
    }

    private func run() async throws {
        do {
            let reader = FrameIteratorBox(transport.incomingFrames)
            activeReader = reader
            transition(.subscribing)
            try await transport.subscribe(to: .cmdFromStrap)
            try await transport.subscribe(to: .eventsFromStrap)
            try await transport.subscribe(to: .dataFromStrap)

            transition(.sendingHello)
            let helloSequence = nextSequence()
            try await sendAndAcknowledge(
                payload: [0x23, helloSequence, 0x91, 0x01], opcode: 0x91, sequence: helloSequence,
                reader: reader, field: 0x0001, allowedStatuses: [0x00, 0x01, 0x02]
            )

            transition(.readingClock)
            _ = try? await readClock(reader: reader)

            transition(.settingClock)
            let setTimestamp = UInt32(Date().timeIntervalSince1970)
            do {
                let clockSequence = nextSequence()
                var clockPayload: [UInt8] = [0x23, clockSequence, 0x0A, 0x01]
                appendLE(setTimestamp, to: &clockPayload)
                try await sendAndAcknowledge(
                    payload: clockPayload, opcode: 0x0A, sequence: clockSequence, reader: reader,
                    allowedStatuses: [0x00, 0x01, 0x02]
                )

                transition(.verifyingClock)
                _ = try? await readClock(reader: reader)
            } catch {
                // Non-fatal warning su allineamento clock
            }

            transition(.keyExchange)
            do {
                var keyPayload: [UInt8] = [0x23, nextSequence(), 0x73, 0x01, 0x01]
                keyPayload.append(contentsOf: (0..<32).map { _ in UInt8.random(in: 0...255) })
                let keySequence = keyPayload[1]
                try await sendAndAcknowledge(
                    payload: keyPayload, opcode: 0x73, sequence: keySequence, reader: reader,
                    allowedStatuses: [0x00, 0x01, 0x02]
                )
            } catch {
                // Non-fatal warning su key exchange
            }

            for (index, flag) in Self.flags.enumerated() {
                transition(.settingFlags(current: index + 1, total: Self.flags.count))
                // L'app ufficiale invia ogni flag due volte; ogni invio ha una propria sequenza e ACK.
                for _ in 0..<2 {
                    do {
                        let flagSequence = nextSequence()
                        var payload: [UInt8] = [0x23, flagSequence, 0x78, 0x01]
                        let name = Array(flag.0.utf8.prefix(32))
                        payload.append(contentsOf: name)
                        payload.append(contentsOf: Array(repeating: UInt8(0), count: 32 - name.count))
                        payload.append(flag.1)
                        try await sendAndAcknowledge(
                            payload: payload, opcode: 0x78, sequence: flagSequence,
                            reader: reader, retryOnce: true, allowedStatuses: [0x00, 0x01, 0x02]
                        )
                    } catch {
                        // Non-fatal warning su singola flag
                    }
                }
            }

            transition(.queryingRange)
            do {
                let rangeSequence = nextSequence()
                let rangeFrame = try encode([0x23, rangeSequence, 0x22, 0x00])
                try await transport.write(rangeFrame, to: .cmdToStrap)
                _ = try await waitForResponse(opcode: 0x22, sequence: rangeSequence, reader: reader, allowedStatuses: [0x00, 0x01, 0x02])
            } catch {
                // Non-fatal warning su query range
            }

            transition(.ready)
        } catch let error as PuffinHandshakeError {
            fail(error)
            throw error
        } catch is CancellationError {
            fail(.cancelled)
            throw PuffinHandshakeError.cancelled
        } catch {
            let failure = PuffinHandshakeError.transportFailure(String(describing: error))
            fail(failure)
            throw failure
        }
    }

    /// Avvia lo streaming storico e invia ACK solo per cursori consecutivi nuovi.
    public func offloadHistorical(
        endTimestamp: Date? = nil,
        timeout: TimeInterval = 60,
        onRecord: @escaping (PuffinFrame) -> Void = { _ in }
    ) -> AsyncThrowingStream<OffloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runOffload(endTimestamp: endTimestamp, timeout: max(0.001, timeout), onRecord: onRecord, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            offloadOperation = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func runOffload(
        endTimestamp: Date?, timeout: TimeInterval, onRecord: @escaping (PuffinFrame) -> Void,
        continuation: AsyncThrowingStream<OffloadProgress, Error>.Continuation
    ) async throws {
        guard state == .ready || state == .offloadStarted else {
            throw PuffinHandshakeError.unexpectedResponse(opcode: 0x16)
        }
        let reader = activeReader ?? FrameIteratorBox(transport.incomingFrames)
        activeReader = reader
        transition(.startingHistorical)
        let sequence = nextSequence()
        try await transport.write(try encode([0x23, sequence, 0x16, 0x00]), to: .cmdToStrap)
        transition(.offloadStarted)

        let deadline = Date().addingTimeInterval(timeout)
        var recordsReceived = 0
        var cursorsAcknowledged = 0
        var lastSeenTimestamp: Date?
        var lastCursor: Data?
        var completed = false
        var timedOut = false

        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; break }
            let incoming: (PuffinFrame, PuffinCharacteristic)
            do {
                incoming = try await nextIncoming(opcode: 0x16, reader: reader, timeout: remaining)
            } catch PuffinHandshakeError.ackTimeout(_) {
                timedOut = true
                break
            }
            let (frame, characteristic) = incoming
            let bytes = Array(frame.rawPayload)
            switch bytes.first ?? 0 {
            case 0x2F:
                onRecord(frame)
                recordsReceived += 1
                if bytes.count >= 11 {
                    let seconds = readUInt32LE(bytes, 7)
                    lastSeenTimestamp = Date(timeIntervalSince1970: TimeInterval(seconds))
                }
                continuation.yield(OffloadProgress(recordsReceived: recordsReceived, cursorsAcknowledged: cursorsAcknowledged, lastSeenTimestamp: lastSeenTimestamp, completed: false, timedOut: false))
                if let endTimestamp, let lastSeenTimestamp, lastSeenTimestamp >= endTimestamp {
                    completed = true
                    break
                }
            case 0x31 where characteristic == .dataFromStrap && bytes.count >= 21:
                let cursor = Data(bytes[13..<21])
                if cursor != lastCursor {
                    var payload: [UInt8] = [0x23, nextSequence(), 0x17, 0x01]
                    payload.append(contentsOf: cursor)
                    try await writeWithTimeout(try encode(payload), timeout: 0.8)
                    lastCursor = cursor
                    cursorsAcknowledged += 1
                    continuation.yield(OffloadProgress(recordsReceived: recordsReceived, cursorsAcknowledged: cursorsAcknowledged, lastSeenTimestamp: lastSeenTimestamp, completed: false, timedOut: false))
                }
            case 0x24:
                delegate?.handshake(self, didReceiveRawFrame: frame)
            default:
                break
            }
            if completed { break }
        }
        transition(.ready)
        continuation.yield(OffloadProgress(recordsReceived: recordsReceived, cursorsAcknowledged: cursorsAcknowledged, lastSeenTimestamp: lastSeenTimestamp, completed: completed, timedOut: timedOut))
    }

    public func stop() {
        offloadOperation?.cancel()
    }

    private func writeWithTimeout(_ frame: Data, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.transport.write(frame, to: .cmdToStrap) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PuffinHandshakeError.ackTimeout(opcode: 0x17)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private func readClock(reader: FrameIteratorBox) async throws -> UInt32 {
        let seq = nextSequence()
        let response = try await sendAndAcknowledge(
            payload: [0x23, seq, 0x0B, 0x00], opcode: 0x0B, sequence: seq,
            reader: reader, returnsFrame: true, allowedStatuses: [0x00, 0x01, 0x02]
        )
        guard let response else { throw PuffinHandshakeError.unexpectedResponse(opcode: 0x0B) }
        let bytes = Array(response.rawPayload)
        let offset = bytes.count >= 9 ? 5 : (bytes.count >= 8 ? 4 : -1)
        guard offset >= 0, bytes.count >= offset + 4 else {
            throw PuffinHandshakeError.unexpectedResponse(opcode: 0x0B)
        }
        let timestamp = readUInt32LE(bytes, offset)
        return timestamp
    }

    @discardableResult
    private func sendAndAcknowledge(
        payload: [UInt8], opcode: UInt8, sequence: UInt8, reader: FrameIteratorBox,
        field: UInt16 = 0x0001,
        retryOnce: Bool = false, returnsFrame: Bool = false,
        allowedStatuses: Set<UInt8> = [0x00, 0x01]
    ) async throws -> PuffinFrame? {
        let frame = try encode(payload, field: field)
        var lastError: PuffinHandshakeError = .ackTimeout(opcode: opcode)
        for attempt in 0..<(retryOnce ? 2 : 1) {
            if attempt > 0 { try Task.checkCancellation() }
            try await transport.write(frame, to: .cmdToStrap)
            do {
                let response = try await waitForResponse(
                    opcode: opcode, sequence: sequence, reader: reader, allowedStatuses: allowedStatuses
                )
                return returnsFrame ? response : nil
            } catch let error as PuffinHandshakeError {
                lastError = error
                if retryOnce && attempt == 0 { continue }
                throw error
            }
        }
        throw lastError
    }

    private func waitForResponse(
        opcode: UInt8, sequence: UInt8, reader: FrameIteratorBox,
        allowedStatuses: Set<UInt8> = [0x00, 0x01]
    ) async throws -> PuffinFrame {
        while true {
            let (frame, characteristic) = try await nextIncoming(opcode: opcode, reader: reader)
            delegate?.handshake(self, didReceiveRawFrame: frame)
            let raw = frame.rawPayload
            guard characteristic == .cmdFromStrap, raw.count >= 4, raw[0] == 0x24, raw[1] == sequence else {
                continue
            }
            guard raw[2] == opcode else { throw PuffinHandshakeError.unexpectedResponse(opcode: raw[2]) }
            let status = responseStatus(frame.rawPayload)
            guard allowedStatuses.contains(status) else {
                throw PuffinHandshakeError.ackStatusFailure(opcode: opcode, status: status)
            }
            return frame
        }
    }

    private func nextIncoming(
        opcode: UInt8, reader: FrameIteratorBox, timeout: TimeInterval? = nil
    ) async throws -> (PuffinFrame, PuffinCharacteristic) {
        let wait = timeout ?? self.timeout
        return try await withThrowingTaskGroup(of: (PuffinFrame, PuffinCharacteristic)?.self) { group in
            group.addTask { await reader.next() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                throw PuffinHandshakeError.ackTimeout(opcode: opcode)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next(), let incoming = result else {
                throw PuffinHandshakeError.ackTimeout(opcode: opcode)
            }
            return incoming
        }
    }

    private func responseStatus(_ bytes: Data) -> UInt8 {
        bytes.count >= 5 ? bytes[4] : (bytes.count >= 4 ? bytes[3] : 0)
    }

    private func encode(_ payload: [UInt8], field: UInt16 = 0x0001) throws -> Data {
        try PuffinFrameCodec.encode(field: field, payload: Data(payload))
    }

    private func nextSequence() -> UInt8 {
        defer { sequence = sequence == 0xFF ? 1 : sequence &+ 1 }
        return sequence
    }

    private func transition(_ newState: HandshakeState) {
        state = newState
        delegate?.handshake(self, didChangeState: newState)
    }

    private func fail(_ error: PuffinHandshakeError) {
        guard !didReportFailure else { return }
        didReportFailure = true
        transition(.failed(error))
        delegate?.handshake(self, didFailWith: error)
    }

    private func appendLE(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
