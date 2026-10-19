import XCTest
@testable import Flow

final class CloudSpeechAudioPacketsTests: XCTestCase {
    func testNative44100HzFragmentsPreserveEveryByteInTenPacketsPerSecond() {
        let pcm = Data((0..<88200).map { UInt8(truncatingIfNeeded: $0) })
        var packets = CloudSpeechAudioPackets(sampleRate: 44100)
        var output: [Data] = []
        var offset = 0, chunk = 0
        let callbackFrames = [256, 512, 8192, 1470, 17]
        while offset < pcm.count {
            let end = min(pcm.count, offset + callbackFrames[chunk % callbackFrames.count] * 2)
            output += packets.append(pcm.subdata(in: offset..<end))
            offset = end; chunk += 1
        }
        XCTAssertNil(packets.finish())
        XCTAssertEqual(output.count, 10)
        XCTAssertTrue(output.allSatisfy { $0.count == 8820 })
        XCTAssertEqual(output.reduce(into: Data()) { $0.append($1) }, pcm)
    }

    func testStopFlushesTheSubPacketTailExactlyOnce() {
        var packets = CloudSpeechAudioPackets(sampleRate: 16000)
        let pcm = Data((0..<3214).map { UInt8(truncatingIfNeeded: $0) })
        let output = packets.append(pcm)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].count, 3200)
        XCTAssertEqual(packets.finish(), pcm.suffix(14))
        XCTAssertNil(packets.finish())
    }

    func testMicrophoneCallbacksWaitFor100MillisecondsOfAudio() {
        var packets = CloudSpeechAudioPackets(sampleRate: 48000)
        for _ in 0..<9 { XCTAssertTrue(packets.append(Data(repeating: 1, count: 960)).isEmpty) }
        XCTAssertEqual(packets.append(Data(repeating: 1, count: 960)).map(\.count), [9600])
    }
}
