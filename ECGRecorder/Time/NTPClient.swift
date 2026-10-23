import Foundation
import Network

/// Optional, non-blocking SNTP query. Returns nil offline or on timeout.
/// Offset = server clock minus phone clock, in seconds.
enum NTPClient {
    private static let ntpEpochToUnix = 2_208_988_800.0

    static func offset(host: String = "time.apple.com", timeout: Double = 2) async -> Double? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 123, using: .udp)
            let gate = Gate(continuation, connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let sent = Date().timeIntervalSince1970
                    gate.sentAt = sent
                    let packet = request(sentAt: sent)
                    connection.send(content: packet, completion: .contentProcessed { error in
                        if error != nil { gate.finish(nil) }
                    })
                    connection.receiveMessage { data, _, _, _ in
                        let received = Date().timeIntervalSince1970
                        gate.finish(data.flatMap { parse($0, sentAt: gate.sentAt, receivedAt: received) })
                    }
                case .failed, .waiting: gate.finish(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.finish(nil) }
        }
    }

    /// Client request carrying our send time in the transmit field; a genuine server echoes it back as the
    /// originate time, which is how a reply is matched to this request.
    static func request(sentAt t1: Double) -> Data {
        var packet = Data(count: 48)
        packet[0] = 0x1B   // LI 0, version 3, client mode
        packet.replaceSubrange(40..<48, with: encode(t1))
        return packet
    }

    /// Standard NTP offset from the four timestamps. Rejects replies that are not an answer to our request
    /// (spoofed or stale), unsynchronized servers, and kiss-of-death packets.
    static func parse(_ data: Data, sentAt t1: Double, receivedAt t4: Double) -> Double? {
        guard data.count >= 48 else { return nil }
        let bytes = [UInt8](data.prefix(48))
        let leap = bytes[0] >> 6, mode = bytes[0] & 0x7, stratum = bytes[1]
        guard mode == 4, leap != 3, (1...15).contains(stratum) else { return nil }
        guard Array(bytes[24..<32]) == Array(encode(t1)) else { return nil }
        let t2 = timestamp(bytes, at: 32), t3 = timestamp(bytes, at: 40)
        guard t3 > 0, t4 >= t1 else { return nil }
        return ((t2 - t1) + (t3 - t4)) / 2
    }

    private static func timestamp(_ bytes: [UInt8], at offset: Int) -> Double {
        let seconds = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let fraction = bytes[offset + 4..<offset + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Double(seconds) - ntpEpochToUnix + Double(fraction) / 4_294_967_296
    }

    private static func encode(_ unix: Double) -> Data {
        let ntp = unix + ntpEpochToUnix
        let seconds = UInt32(ntp.rounded(.down))
        let fraction = UInt32(((ntp - ntp.rounded(.down)) * 4_294_967_296).rounded(.down))
        return Data([seconds >> 24, seconds >> 16, seconds >> 8, seconds, fraction >> 24, fraction >> 16, fraction >> 8, fraction]
            .map { UInt8(truncatingIfNeeded: $0) })
    }

    /// Resumes the continuation exactly once, whichever of reply, error or timeout comes first.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var sent = 0.0
        private let continuation: CheckedContinuation<Double?, Never>
        private let connection: NWConnection

        init(_ continuation: CheckedContinuation<Double?, Never>, _ connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        /// Send time, written before the reply handler can run.
        var sentAt: Double {
            get { lock.withLock { sent } }
            set { lock.withLock { sent = newValue } }
        }

        func finish(_ value: Double?) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            guard first else { return }
            connection.cancel()
            continuation.resume(returning: value)
        }
    }
}
