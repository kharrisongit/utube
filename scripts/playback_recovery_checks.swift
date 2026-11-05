import Foundation

extension String { var localized: String { self } }
enum AppLog { static func poToken(_ value: String) {} }
enum ServiceContainer { static let transport: HTTPTransport = MockTransport() }
enum AppURLs { enum PoTokenProvider { static var endpoint: URL? = URL(string: "https://provider.invalid/get_pot") } }
enum HTTPHeader { static let contentType = "Content-Type" }
enum HTTPHeaderValue { static let contentTypeJSON = "application/json" }
enum UserDefaultsKeys { enum Innertube {
    static let visitorData = "recovery-test-visitor"
    static let visitorDataDate = "recovery-test-date"
} }
enum InnertubeClient {
    static func extractVisitorData(from data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }
    }
}
final class MockTransport: HTTPTransport {
    var requests: [HTTPRequest] = []
    var tokens: [CancellationToken?] = []
    var replies: [(Result<HTTPResponse, Error>) -> Void] = []
    func send(_ request: HTTPRequest, cancellationToken: CancellationToken?,
              completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        requests.append(request); tokens.append(cancellationToken); replies.append(completion)
    }
    func reply(_ index: Int, status: Int = 200, body: String, headers: [String: String] = [:]) {
        replies[index](.success(HTTPResponse(status: status, headers: headers, data: Data(body.utf8))))
    }
}
enum CheckError: Error { case failed(String) }
@main enum RecoveryChecks {
    static var count = 0
    static func expect(_ result: Bool, _ message: String) throws {
        guard result else { throw CheckError.failed(message) }; count += 1
    }
    static func cookie(_ name: String, _ value: String = "value", domain: String = ".youtube.com") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"])!
    }
    static func main() throws {
        try classification(); try cooldown(); try tokenCache(); try identity(); try navigation()
        try stalls()
        print("Passed \(count) playback recovery checks")
    }
    static func stalls() throws {
        typealias Policy = PlaybackStallPolicy
        try expect(Policy.isStuck(from: 795, to: 795.49), "A stalled playhead can drift slightly")
        try expect(!Policy.isStuck(from: 795, to: 795.5), "Half a second of progress cancels recovery")
        try expect(!Policy.isStuck(from: 795, to: 794.5), "A backward seek cancels recovery")
        try expect(!Policy.isStuck(from: .nan, to: 10) && !Policy.isStuck(from: 10, to: .infinity), "Ignore invalid playheads")
        try expect(Policy.canRestart(at: 795, duration: 2204), "Allow recovery during the stalled video")
        try expect(Policy.canRestart(at: 1, duration: 2), "Include both one-second boundaries")
        try expect(!Policy.canRestart(at: 0.99, duration: 2), "Do not restart during initial buffering")
        try expect(!Policy.canRestart(at: 1.01, duration: 2), "Do not restart at the end")
        try expect(!Policy.canRestart(at: .nan, duration: 10) && !Policy.canRestart(at: 10, duration: .infinity), "Require a finite timeline")
    }
    static func classification() throws {
        let message = "Sign in to confirm you’re not a bot"
        try expect(PlaybackFailure.isBotCheck(["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": message]]), "Explicit bot check")
        for reason in ["Sign in to confirm your age", "This video is private", "Join this channel to watch"] {
            try expect(!PlaybackFailure.isBotCheck(["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": reason]]), "Do not reset for access restrictions")
        }
        try expect(!PlaybackFailure.isBotCheck(["playabilityStatus": ["status": "LOGIN_REQUIRED"]]), "Unknown login requirement is not bot evidence")
        try expect(!PlaybackFailure.isBotCheck(["playabilityStatus": ["status": "OK", "reason": message]]), "Successful response is not a bot check")
        try expect(PlaybackFailure.isBotCheck(["playabilityStatus": ["status": "ERROR", "errorScreen": ["text": "Unusual traffic"]]]), "Nested bot reason")
    }
    static func cooldown() throws {
        let gate = PlaybackRecoveryGate(); let now = Date()
        try expect(gate.claim(now: now), "First automatic reset allowed")
        try expect(!gate.claim(now: now.addingTimeInterval(3)), "Repeated resets blocked across videos")
        try expect(gate.delay(now: now) == 0, "Automatic retry not blocked by its own reset")
        gate.rateLimited(now: now)
        try expect(gate.delay(now: now.addingTimeInterval(2)) == 28, "429 has actual cooldown")
        try expect(gate.claim(now: now.addingTimeInterval(31)), "Cooldown expires")
    }
    static func tokenCache() throws {
        let wire = MockTransport(); let service = RemotePoTokenService(transport: wire)
        var values: [String] = []; var errors = 0
        let receive: (Result<String, Error>) -> Void = { result in
            switch result { case .success(let value): values.append(value); case .failure: errors += 1 }
        }
        service.fetchSessionToken(identifier: "video", client: "WEB", completion: receive)
        service.fetchSessionToken(identifier: "video", client: "WEB", completion: receive)
        try expect(wire.requests.count == 1, "Coalesce identical mints")
        wire.reply(0, body: #"{"poToken":"first"}"#)
        try expect(values == ["first", "first"], "All waiters receive mint")
        service.fetchSessionToken(identifier: "video", client: "WEB", completion: receive)
        try expect(wire.requests.count == 1 && values.count == 3, "Successful cache reuse")
        service.invalidateToken(identifier: "video", client: "WEB")
        service.fetchSessionToken(identifier: "video", client: "WEB", completion: receive)
        let payload = try JSONSerialization.jsonObject(with: wire.requests[1].body!) as! [String: Any]
        try expect(payload["bypass_cache"] as? Bool == true, "Force provider refresh with matching cache key")
        service.invalidateToken(identifier: "video", client: "WEB")
        try expect(wire.tokens[1]?.isCancelled == true && errors == 1, "Invalidation cancels mint and completes its waiters")
        service.fetchSessionToken(identifier: "video", client: "WEB", completion: receive)
        wire.reply(1, body: #"{"poToken":"late-rejected"}"#)
        wire.reply(2, body: #"{"poToken":"fresh"}"#)
        service.fetchSessionToken(identifier: "video", client: "WEB", completion: receive)
        try expect(values.suffix(2) == ["fresh", "fresh"] && !values.contains("late-rejected"), "Late mint cannot replace refreshed token")
        service.fetchSessionToken(identifier: "video", client: "TV", completion: receive)
        try expect(wire.requests.count == 4, "Different client never shares token")
        wire.reply(3, status: 500, body: #"{"poToken":"server-error-token"}"#)
        try expect(errors == 2 && !values.contains("server-error-token"), "HTTP failure never populates cache")
        service.fetchSessionToken(identifier: "video", client: "TV", completion: receive)
        wire.reply(4, body: #"{"poToken":"ERR:failed"}"#)
        try expect(errors == 3, "Reject provider error tokens")
        try expect(wire.requests.allSatisfy { !$0.sendsCookies }, "No account cookies sent to token provider")
    }
    static func identity() throws {
        let suite = "uTube-recovery-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage!
        let account = cookie("SID", "account"); jar.setCookie(account)
        jar.setCookie(cookie("VISITOR_INFO1_LIVE", "old"))
        let wire = MockTransport()
        let store = VisitorIdentityStore(defaults: defaults, cookies: jar, transport: wire)
        let parent = CancellationToken(); let child = store.childToken(parent: parent)
        var values: [String?] = []
        let request = HTTPRequest(method: .get, url: URL(string: "https://www.youtube.com/watch")!, sendsCookies: false)
        store.fetch(request) { values.append($0) }; store.fetch(request) { values.append($0) }
        try expect(wire.requests.count == 1, "Parallel preflights are coalesced")
        store.reset(notify: false)
        try expect(child.isCancelled && !parent.isCancelled && wire.tokens[0]?.isCancelled == true, "Reset cancels old anonymous requests only")
        try expect(jar.cookies?.contains(where: { $0.name == "SID" }) == true, "Account cookie preserved")
        try expect(jar.cookies?.contains(where: { $0.name.hasPrefix("VISITOR_") }) == false, "Rejected visitor cookies removed")
        wire.reply(0, body: "old", headers: ["Set-Cookie": "VISITOR_INFO1_LIVE=late; Domain=.youtube.com; Path=/"])
        try expect(store.visitorData == nil && values.isEmpty, "Stale preflight cannot resurrect identity or notify cancelled callers")
        store.fetch(request) { values.append($0) }
        wire.reply(1, body: "new", headers: ["Set-Cookie": "VISITOR_INFO1_LIVE=new; Domain=.youtube.com; Path=/"])
        try expect(store.visitorData == "new" && values == ["new"], "Fresh preflight committed")
        store.fetch(request) { values.append($0) }
        try expect(wire.requests.count == 2, "Keep working visitor cached")
        try expect(!store.adopt(visitor: "", browserCookies: [cookie("VISITOR_INFO1_LIVE")]), "Reject incomplete verification")
        try expect(!store.adopt(visitor: "bad", browserCookies: [cookie("VISITOR_INFO1_LIVE", domain: "evil.invalid")]), "Reject foreign cookies")
        try expect(store.adopt(visitor: "verified", browserCookies: [cookie("VISITOR_INFO1_LIVE", "verified"), cookie("SID", "browser-account")]), "Import browser visitor")
        try expect(store.visitorData == "verified", "Next native request uses verified visitor")
        try expect(jar.cookies?.first(where: { $0.name == "SID" })?.value == "account", "Browser import cannot replace signed-in account")
        try expect(jar.cookies?.first(where: { $0.name == "VISITOR_INFO1_LIVE" })?.value == "verified", "Paired visitor cookie imported")
    }
    static func navigation() throws {
        for raw in ["https://www.youtube.com/watch?v=aqz-KE-bpKQ", "https://accounts.google.com/", "https://consent.youtube.com/"] {
            try expect(VerificationURLPolicy.allowsNavigation(URL(string: raw)), "Allow genuine verification pages")
        }
        for raw in ["http://www.youtube.com", "https://youtube.com.evil.invalid", "https://evil.invalid", "https://user@www.youtube.com", "https://www.youtube.com:444", "file:///tmp/page"] {
            try expect(!VerificationURLPolicy.allowsNavigation(URL(string: raw)), "Reject unsafe navigation")
        }
        try expect(!VerificationURLPolicy.isYouTube(URL(string: "https://accounts.google.com")), "Only YouTube can supply visitor state")
        try expect(VerificationURLPolicy.page(videoID: "../../evil")?.path == "/", "Never interpolate an invalid video ID")
    }
}
