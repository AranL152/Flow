import Foundation

/// Aggregate device callback fragments into 100 ms PCM16 packets. Sending every
/// small microphone callback can overwhelm a bounded WebSocket send queue.
struct CloudSpeechAudioPackets {
    private let bytesPerPacket: Int
    private var pending = Data()

    init(sampleRate: UInt32) { bytesPerPacket = Int(sampleRate) / 10 * 2 }

    mutating func append(_ pcm: Data) -> [Data] {
        pending.append(pcm)
        var packets: [Data] = []
        while pending.count >= bytesPerPacket {
            packets.append(Data(pending.prefix(bytesPerPacket)))
            pending.removeFirst(bytesPerPacket)
        }
        return packets
    }

    mutating func finish() -> Data? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
