import Foundation

enum CheckError: Error { case failed(String) }

@main enum AirPlayPlaybackChecks {
    static var count = 0

    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw CheckError.failed(message) }
        count += 1
    }

    static func format(_ json: [String: Any]) -> DashFormatInfo {
        let mime = json["mimeType"] as? String ?? "video/mp4"
        let codec = mime.components(separatedBy: "\"").dropFirst().first ?? ""
        return DashFormatInfo(
            url: URL(string: "https://media.invalid/test")!,
            itag: json["itag"] as? Int ?? 0, mimeType: mime, codecs: codec,
            bitrate: json["bitrate"] as? Int ?? 1, contentLength: 1000,
            initRangeEnd: 9, indexRangeStart: 10, indexRangeEnd: 99,
            width: json["width"] as? Int, height: json["height"] as? Int,
            fps: json["fps"] as? Int, qualityLabel: json["qualityLabel"] as? String,
            sigChallenge: nil, sigParam: nil, approxDurationMs: nil,
            lastModified: nil, audioTrackId: nil, audioTrackName: nil,
            audioIsDefault: true, xtags: nil
        )
    }

    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let samples = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for sample in samples {
            let formats = (sample["formats"] as! [[String: Any]]).map(format)
            let id = sample["videoId"] as! String
            let expected = sample["expectedAirPlayItag"] as! Int
            let selected = formats.max {
                ($0.height ?? 0, $0.bitrate) < ($1.height ?? 0, $1.bitrate)
            }!
            let replacement = AirPlayVideoPolicy.replacement(for: selected, in: formats)
            try expect(replacement?.itag == expected, "\(id): highest-quality AirPlay replacement")
            let av1 = formats.first { $0.codecs.hasPrefix("av01") && $0.height == 1080 }!
            try expect(AirPlayVideoPolicy.replacement(for: av1, in: formats)?.itag == expected,
                       "\(id): inspect AVC sibling even at the same height/label")
            let avc = formats.first { $0.itag == expected }!
            try expect(AirPlayVideoPolicy.replacement(for: avc, in: formats)?.itag == expected,
                       "\(id): already-working 1080p remains unchanged")
            try expect(AirPlayVideoPolicy.isCompatible(avc), "\(id): supported AVC level/frame rate")
            let retry = AirPlayVideoPolicy.replacement(for: avc, in: formats, afterRejection: true)
            try expect(retry?.itag == 136, "\(id): retry 720p30 when compatible 1080p is rejected")
            if let avc720p60 = formats.first(where: { $0.itag == 298 }) {
                try expect(AirPlayVideoPolicy.replacement(for: avc720p60, in: formats, afterRejection: true)?.itag == 136,
                           "Keep 720p and reduce frame rate when 720p60 is rejected")
            }
            try expect(AirPlayVideoPolicy.replacement(for: avc, in: [avc, av1], afterRejection: true) == nil,
                       "No automatic retry with the rejected itag or AV1")
            let small = formats.first { $0.itag == 134 }!
            try expect(AirPlayVideoPolicy.replacement(for: small, in: formats, afterRejection: true)?.itag == 133,
                       "Never raise the chosen resolution during recovery")
            try expect(AirPlayVideoPolicy.replacement(for: small, in: formats)?.itag == 134,
                       "\(id): never raise a deliberately lower quality")
            let smallAV1 = formats.first { $0.itag == 396 }!
            try expect(AirPlayVideoPolicy.replacement(for: smallAV1, in: formats)?.itag == 134,
                       "\(id): AV1 fallback honors lower quality")
            try expect(AirPlayVideoPolicy.replacement(for: av1, in: [av1]) == nil,
                       "\(id): do not invent missing compatible renditions")
        }
        let unsupported: [[String: Any]] = [
            ["mimeType": "video/mp4; codecs=\"av01.0.08M.08\"", "width": 1920, "height": 1080],
            ["mimeType": "video/mp4; codecs=\"avc1.64002A\"", "width": 2560, "height": 1440],
            ["mimeType": "video/mp4; codecs=\"avc1.640033\"", "width": 1920, "height": 1080],
            ["mimeType": "video/mp4; codecs=\"avc1.64002A\"", "width": 1920, "height": 1080, "fps": 120],
            ["mimeType": "video/mp4; codecs=\"avc1.640028\"", "width": 0, "height": 1080]
        ]
        for candidate in unsupported {
            try expect(!AirPlayVideoPolicy.isCompatible(format(candidate)), "Reject incompatible rendition")
        }
        print("Passed \(count) AirPlay format checks using both reported videos")
    }
}
