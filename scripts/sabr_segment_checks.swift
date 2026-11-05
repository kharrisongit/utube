extension String { var localized: String { self } }
import Foundation

// Only logging is replaced; the collector, UMP reader and protobuf parser are production code.
enum AppLog {
    static func hls(_ line: String) {}
    static func player(_ line: String) {}
}
enum CheckError: Error { case failed(String) }

@main enum SABRSegmentChecks {
    static var count = 0

    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw CheckError.failed(message) }
        count += 1
    }

    static func format(_ itag: Int, tags: String? = nil) -> SabrFormatInfo {
        SabrFormatInfo(itag: itag, lastModified: nil, xtags: tags, audioTrackId: nil,
                       isDrc: false, mimeType: nil, bitrate: nil, width: nil, height: nil)
    }

    static func collector(_ sequence: Int, tags: String? = nil, initRange: Int? = nil)
        -> SABRSegmentCollector {
        SABRSegmentCollector(request: SABRSegmentRequest(
            format: format(137, tags: tags), other: format(140), sequence: sequence,
            timeMs: 131400, initRange: initRange))
    }

    // Small synthetic UMP frames: each payload is under 128 bytes, so its UMP
    // length has a single byte. Distinct payloads make wrong-segment delivery visible.
    static func part(_ type: UInt8, _ payload: Data) -> Data {
        precondition(payload.count < 128)
        return Data([type, UInt8(payload.count)]) + payload
    }

    static func segment(_ number: Int, id: Int = 1, itag: Int = 137,
                        tags: String? = nil, isInit: Bool = false,
                        bytes: String) -> Data {
        var header = Protobuf.int(1, id) + Protobuf.int(3, itag)
        header += Protobuf.bool(8, isInit) + Protobuf.int(9, number)
        header += Protobuf.int(11, number * 5000) + Protobuf.int(12, 5000)
        if let tags { header += Protobuf.string(5, tags) }
        return part(20, header) + part(21, Data([UInt8(id)]) + Data(bytes.utf8))
            + part(22, Data([UInt8(id)]))
    }

    static func main() throws {
        try overlappingStartupRequests()
        try redirects()
        try throttleFailures()
        let protection = collector(1)
        protection.append(part(58, Protobuf.int(1, 3)))
        try expect(protection.failure as? PlaybackFailure == .tokenRejected && protection.isDone,
                   "Attestation rejection requests a fresh token rather than an empty-media retry")
        // The reported adjacent-segment failure: segment 26 arrives before 27.
        let ordered = collector(27)
        ordered.append(segment(26, bytes: "previous-segment"))
        try expect(!ordered.isDone && ordered.segment == nil,
                   "Earlier media must not satisfy a later playlist URL")
        ordered.append(segment(27, id: 2, bytes: "requested-segment"))
        try expect(ordered.isDone && ordered.segment == Data("requested-segment".utf8),
                   "Continue reading until the requested segment is complete")
        try expect(ordered.deliveredRange?.startSequence == 27,
                   "Acknowledge only the segment that was actually requested")

        let mixed = collector(22, tags: "original")
        let response = segment(21, bytes: "earlier")
            + segment(22, id: 2, itag: 140, bytes: "audio")
            + segment(22, id: 3, tags: "dub", bytes: "wrong-track")
            + segment(22, id: 4, tags: "original", bytes: "correct")
            + segment(23, id: 5, bytes: "later")
        // Network chunks can split a header or media part at any byte.
        for byte in response { mixed.append(Data([byte])) }
        try expect(mixed.segment == Data("correct".utf8),
                   "Fragmented responses must match sequence, format and audio track")
        try expect(mixed.isDone, "Stop at the matching segment's MEDIA_END")

        let missing = collector(27)
        missing.append(segment(26, bytes: "earlier") + segment(28, id: 2, bytes: "later"))
        try expect(missing.segment == nil && missing.deliveredRange == nil,
                   "A response without the requested segment must not return wrong bytes")

        let initialization = collector(1, initRange: 4)
        initialization.append(segment(0, isInit: true, bytes: "init-extra"))
        try expect(initialization.segment == Data("init".utf8),
                   "Init segments use init identity, not the media sequence")
        try expect(initialization.deliveredRange == nil,
                   "Init bytes must not be advertised as buffered media")

        try expect(SABRSegmentRequest.milliseconds(at: 112.999999999) == 113000,
                   "Floating-point drift must not seek into the preceding segment")
        try expect(SABRSegmentRequest.milliseconds(at: 131.3997) == 131400,
                   "Sub-millisecond boundaries must round forward")
        try expect(SABRSegmentRequest.milliseconds(at: 0) == 0,
                   "The first segment still starts at zero")
        let held = SABRBufferedRange(format: format(137), startMs: 127933, durationMs: 3466,
                                     startSequence: 26, endSequence: 26, timescale: 90000)
        try expect(held.acknowledged(for: collector(26).request) == nil,
                   "A repeated request must not tell the server the wanted bytes are held")
        try expect(held.acknowledged(for: collector(25).request) == nil,
                   "Out-of-order requests must not acknowledge media ahead of the target")
        try expect(held.acknowledged(for: collector(27).request)?.endSequence == 26,
                   "Sequential playback acknowledges the preceding segment")
        try expect(held.acknowledged(for: collector(27, initRange: 4).request) == nil,
                   "Initialization requests must not acknowledge media")
        let time = Protobuf.parse(held.timeRange)
        try expect(time.number(1) == 127933 && time.number(2) == 3466 && time.number(3) == 1000,
                   "Buffered tick values and timescale must use the same time unit")
        print("Passed \(count) SABR segment checks")
    }
}
