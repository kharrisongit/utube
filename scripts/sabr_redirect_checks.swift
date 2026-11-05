import Foundation

// Network and player-script discovery are controlled; request construction,
// redirect parsing/following and throttle failure propagation are production code.
struct SABRTestClient: PlaybackClient {
    let name = "TEST", version = "1", headerName = "7", userAgent = "test"
    let playerURL = "/player", innertubeContext: [String: Any] = [:]
    let authorization = PlaybackAuthorization.anonymous
    let sendsCookies = false
    func sabrClientInfo() -> Data { Protobuf.int(16, 7) }
    func sabrAbrState(_ state: SABRPlayerState) -> Data { Protobuf.int(28, state.playerMs) }
}

final class SABRTestTransport: HTTPTransport {
    var requests: [HTTPRequest] = []
    var pending: [(Result<HTTPResponse, Error>) -> Void] = []
    var responses: [Data] = []
    var automatic = true
    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?,
              completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        requests.append(request)
        if automatic {
            let bytes = responses.isEmpty ? Data() : responses.removeFirst()
            completion(.success(HTTPResponse(status: 200, headers: [:], data: bytes)))
        } else {
            pending.append(completion)
        }
    }
    func respond(_ index: Int, _ bytes: Data) {
        pending[index](.success(HTTPResponse(status: 200, headers: [:], data: bytes)))
    }
}

enum SABRDelivery {}
final class HLSStreamResolver {
    static let shared = HLSStreamResolver()
    var value: String?
    var calls = 0
    func solveN(unsolved: String, jsPath: String?, completion: @escaping (String?) -> Void) {
        calls += 1
        completion(value)
    }
}
final class SignatureTimestampService {
    static let shared = SignatureTimestampService()
    func tvPlayerPath(completion: @escaping (String?) -> Void) { completion("/s/player/test/base.js") }
}

extension SABRSegmentChecks {
    static func redirected(_ url: String) -> Data { part(43, Protobuf.string(1, url)) }
    static func fetcher(_ transport: SABRTestTransport, url: String) -> SABRFetcher {
        SABRFetcher(transport: transport, url: URL(string: url)!, ustreamerConfig: Data([1]),
                    identity: SABRIdentity(client: SABRTestClient(), poToken: Data([7])))
    }
    static func succeeded(_ result: Result<Data, Error>?) -> Data? { try? result?.get() }
    static func failed(_ result: Result<Data, Error>?) -> Bool {
        guard case .failure? = result else { return false }
        return true
    }
    static func redirects() throws {
        let original = "https://r1.googlevideo.com/videoplayback?sig=a%2Bb%3D&rn=99"
        let target = "https://r2.googlevideo.com/videoplayback?sig=c%2Bd%3D&rn=77"
        let parser = collector(27)
        let redirect = redirected(target)
        for byte in redirect { parser.append(Data([byte])) }
        try expect(parser.isDone && parser.redirectURL?.absoluteString == target && parser.failure == nil,
                   "Fragmented part 43 must stop the old response and retain the target")
        try expect(parser.segment == nil && parser.deliveredRange == nil,
                   "Redirects must not be returned or acknowledged as media")
        for url in ["http://r2.googlevideo.com/v", "https://googlevideo.com.evil.invalid/v",
                    "https://evilgooglevideo.com/v", "https://evil.invalid/v", "/relative",
                    "https://user@r2.googlevideo.com/v", "https://r2.googlevideo.com:444/v"] {
            let invalid = collector(27)
            invalid.append(redirected(url))
            try expect(invalid.isDone && invalid.failure != nil && invalid.redirectURL == nil,
                       "Reject unsafe redirect \(url)")
        }
        let malformed = collector(27)
        malformed.append(part(43, Data()))
        try expect(malformed.failure != nil, "Missing redirect URL must fail explicitly")

        let partial = collector(27)
        let complete = segment(27, bytes: "partial")
        partial.append(Data(complete.dropLast(3)) + redirect)
        try expect(partial.segment == nil && partial.deliveredRange == nil,
                   "Media before a redirect must be discarded until a complete retry succeeds")

        let transport = SABRTestTransport()
        transport.responses = [redirect, segment(27, bytes: "exact-segment"), segment(28, bytes: "next")]
        let loader = fetcher(transport, url: original)
        var result: Result<Data, Error>?
        var completions = 0
        loader.fetch(collector(27).request) { result = $0; completions += 1 }
        try expect(succeeded(result) == Data("exact-segment".utf8) && completions == 1,
                   "Follow redirect and complete the original segment once")
        try expect(transport.requests.count == 2 && transport.requests[1].url.host == "r2.googlevideo.com",
                   "Retry the redirected media endpoint")
        try expect(transport.requests[1].url.absoluteString.contains("sig=c%2Bd%3D&rn=2"),
                   "Keep signed query bytes and replace stale request number")
        try expect(transport.requests[0].body == transport.requests[1].body,
                   "Redirect retry keeps format, playhead and attestation")
        loader.fetch(collector(28).request) { result = $0 }
        try expect(transport.requests.last?.url.host == "r2.googlevideo.com",
                   "Later segments retain the redirected endpoint")
        try expect(SABRRedirect.numberedURL(URL(string: "https://r1.googlevideo.com/v")!, number: 3)
                    .absoluteString == "https://r1.googlevideo.com/v?rn=3", "Targets without query are valid")

        let initTransport = SABRTestTransport()
        initTransport.responses = [redirect, segment(0, isInit: true, bytes: "init-extra")]
        let initLoader = fetcher(initTransport, url: original)
        initLoader.fetch(collector(1, initRange: 4).request) { result = $0 }
        try expect(succeeded(result) == Data("init".utf8), "Startup redirects must retain init request")

        let loopTransport = SABRTestTransport()
        loopTransport.responses = [redirect, redirect]
        let loopLoader = fetcher(loopTransport, url: original)
        loopLoader.fetch(collector(27).request) { result = $0 }
        try expect(failed(result) && loopTransport.requests.count == 2, "Stop redirect loops")
        let hops = SABRTestTransport()
        hops.responses = (2...6).map { redirected("https://r\($0).googlevideo.com/v") }
        let hopLoader = fetcher(hops, url: original)
        hopLoader.fetch(collector(27).request) { result = $0 }
        try expect(failed(result) && hops.requests.count == 4, "Bound even non-repeating redirects")
        try staleRedirects(original: original)
    }

    static func staleRedirects(original: String) throws {
        let transport = SABRTestTransport()
        transport.automatic = false
        let loader = fetcher(transport, url: original)
        var results: [Result<Data, Error>] = []
        loader.fetch(collector(27).request) { results.append($0) }
        loader.fetch(collector(28).request) { results.append($0) }
        transport.respond(0, redirected("https://r2.googlevideo.com/v")) // retry 2
        transport.respond(2, redirected("https://r3.googlevideo.com/v")) // retry 3
        transport.respond(1, redirected("https://r2.googlevideo.com/v")) // stale response; retry 4
        try expect(transport.requests[4].url.host == "r3.googlevideo.com",
                   "Concurrent old responses must not roll back the session endpoint")
        transport.respond(3, segment(27, bytes: "one"))
        transport.respond(4, segment(28, bytes: "two"))
        try expect(results.count == 2 && succeeded(results[0]) == Data("one".utf8)
                    && succeeded(results[1]) == Data("two".utf8), "Concurrent fetches retain segment identity")
        loader.fetch(collector(29).request) { results.append($0) }
        loader.stop()
        transport.respond(5, redirected("https://r4.googlevideo.com/v"))
        try expect(results.count == 3 && failed(results[2]) && transport.requests.count == 6,
                   "Stopped sessions finish without following another redirect")
    }

    static func overlappingStartupRequests() throws {
        let transport = SABRTestTransport()
        transport.automatic = false
        let loader = fetcher(transport, url: "https://r1.googlevideo.com/v")
        var results: [Result<Data, Error>] = []
        let opening = collector(1).request
        loader.fetch(opening) { results.append($0) }
        loader.fetch(opening) { results.append($0) }
        try expect(transport.requests.count == 1, "Overlapping startup probes share their transfer")
        transport.respond(0, Data())
        try expect(results.count == 2 && results.allSatisfy { failed($0) },
                   "Both probes receive the same upstream failure")
        results.removeAll()
        loader.fetch(opening) { results.append($0) }
        loader.fetch(opening) { results.append($0) }
        try expect(transport.requests.count == 2, "A failed opening can be retried")
        transport.respond(1, segment(1, bytes: "video-start"))
        try expect(results.count == 2 && results.allSatisfy { succeeded($0) == Data("video-start".utf8) },
                   "Both probes receive the complete opening segment")
    }

    static func throttleFailures() throws {
        let resolver = HLSStreamResolver()
        let url = URL(string: "https://r1.googlevideo.com/v?n=challenge")!
        var result: Result<URL, Error>?
        SABRDelivery.solvingThrottle(url, resolver: resolver) { result = $0 }
        if case .failure? = result { count += 1 }
        else { throw CheckError.failed("Never send an unsolved challenge after solver failure") }
        resolver.value = "solved"
        SABRDelivery.solvingThrottle(url, resolver: resolver) { result = $0 }
        try expect((try? result?.get())?.query == "n=solved", "Successful solve replaces challenge")
        let clean = URL(string: "https://r1.googlevideo.com/v")!
        SABRDelivery.solvingThrottle(clean, resolver: resolver) { result = $0 }
        try expect((try? result?.get()) == clean && resolver.calls == 2,
                   "Unchallenged streams never wait for the solver")
    }
}
