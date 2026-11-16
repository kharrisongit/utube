import Foundation

// Standalone macOS checks compile the same pure models the iOS app uses.
extension String { var localized: String { self } }

enum CheckFailure: Error { case failed(String) }

@main
enum NativeCommentsChecks {
    static var checks = 0

    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw CheckFailure.failed(message) }
        checks += 1
    }

    static func rejects(_ reason: String, _ block: () throws -> Void) throws {
        do {
            try block()
            throw CheckFailure.failed("Expected rejection: \(reason)")
        } catch let error as CommentAPIError {
            try expect(error.reason == reason, "Expected \(reason), got \(error.reason)")
        }
    }

    static func main() throws {
        try oauth()
        try comments()
        try tokens()
        try playback()
        try drafts()
        try nestedReplyRecipients()
        try websiteSession()
        try websiteComments()
        try interruptions()
        print("Passed \(checks) native commenting and AirPlay checks")
    }

    static func oauth() throws {
        let request = try CommentOAuthRequest(clientID: "123-test.apps.googleusercontent.com")
        try expect(request.verifier.count == 43 && request.state.count == 43, "Random entropy length")
        let other = try CommentOAuthRequest(clientID: request.clientID)
        try expect(request.verifier != other.verifier && request.state != other.state, "Fresh entropy")
        try expect(request.redirect == "com.googleusercontent.apps.123-test:/oauth2redirect", "Redirect")
        try expect(
            CommentOAuthRequest.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "RFC 7636 S256 vector"
        )
        let url = try request.authorizationURL()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        try expect(query.first { $0.name == "scope" }?.value == CommentOAuthRequest.scope, "Write scope")
        try expect(query.first { $0.name == "code_challenge_method" }?.value == "S256", "PKCE required")
        let valid = "\(request.redirect)?state=\(request.state)&code=a%2Bb%26c"
        let fields = try request.exchangeFields(callback: URL(string: valid)!)
        try expect(fields["code"] == "a+b&c" && fields["code_verifier"] == request.verifier, "Code exchange")
        let bad = [
            valid.replacingOccurrences(of: request.state, with: "wrong"),
            valid.replacingOccurrences(of: request.scheme, with: "wrong"),
            valid.replacingOccurrences(of: "/oauth2redirect", with: "/wrong"),
            valid + "&state=\(request.state)", valid + "&code=duplicate", valid + "#fragment",
            "\(request.scheme)://attacker/oauth2redirect?state=\(request.state)&code=one"
        ]
        for value in bad {
            try rejects("callback") { _ = try request.exchangeFields(callback: URL(string: value)!) }
        }
        try rejects("cancelled") {
            _ = try request.exchangeFields(callback: URL(string: "\(request.redirect)?state=\(request.state)&error=access_denied")!)
        }
        try rejects("setup") { _ = try CommentOAuthRequest(clientID: "https://attacker.invalid") }
        let encoded = String(data: CommentOAuthRequest.formBody(["code": "a+b&c= ü"]), encoding: .utf8)
        try expect(encoded == "code=a%2Bb%26c%3D%20%C3%BC", "Form encoding must preserve code bytes")
    }

    static func comments() throws {
        let top = CommentPostTarget(videoID: "video")
        let body = try top.body(text: "Native comment", channelID: "video-owner")
        let snippet = body["snippet"] as! [String: Any]
        try expect(top.endpoint == "commentThreads", "Top-level endpoint")
        try expect(snippet["channelId"] as? String == "video-owner", "Use video's channel, not author")
        try expect(snippet["videoId"] as? String == "video", "Bind post to selected video")
        let resource = snippet["topLevelComment"] as! [String: Any]
        try expect((resource["snippet"] as! [String: String])["textOriginal"] == "Native comment", "Text body")
        let reply = CommentPostTarget(videoID: "video", parentID: "parent-comment")
        let replyBody = try reply.body(text: "Reply", channelID: nil)["snippet"] as! [String: String]
        try expect(reply.endpoint == "comments" && replyBody["parentId"] == "parent-comment", "Reply parent")
        try expect(replyBody["videoId"] == nil && replyBody["textOriginal"] == "Reply", "Reply shape")
        try rejects("commentTextRequired") { _ = try top.body(text: " \n ", channelID: "owner") }
        try rejects("videoNotFound") { _ = try top.body(text: "text", channelID: nil) }
        let returned: [String: Any] = ["id": "confirmed", "snippet": ["textOriginal": "Hello", "authorDisplayName": "Channel"]]
        let created = try CommentAPIModel.createdComment(["snippet": ["topLevelComment": returned]], isReply: false)
        try expect(created.id == "confirmed" && created.content == "Hello", "Server-confirmed top-level comment")
        try expect(try CommentAPIModel.createdComment(returned, isReply: true).id == "confirmed", "Reply response")
        try rejects("uncertain") { _ = try CommentAPIModel.createdComment(["id": "missing-text"], isReply: true) }
        try rejects("response") { _ = try CommentAPIModel.json(data: Data("not JSON".utf8), status: 200) }
        try rejects("uncertain") {
            _ = try CommentAPIModel.json(data: Data("not JSON".utf8), status: 200, isCommentWrite: true)
        }
        try rejects("uncertain") {
            _ = try CommentAPIModel.json(data: Data(), status: 503, isCommentWrite: true)
        }
        try rejects("signedOut") { _ = try CommentAPIModel.json(data: Data(), status: 401) }
        let failure = Data(#"{"error":{"errors":[{"reason":"commentsDisabled"}]}}"#.utf8)
        try rejects("commentsDisabled") { _ = try CommentAPIModel.json(data: failure, status: 403) }
    }

    static func tokens() throws {
        let valid: [String: Any] = ["scope": CommentOAuthRequest.scope, "access_token": "access", "refresh_token": "refresh", "expires_in": 3600.0]
        let token = try CommentAPIModel.tokens(valid, clientID: "client")
        try expect(token.refreshToken == "refresh" && token.expires > Date(), "Initial credentials")
        var denied = valid
        denied["scope"] = "https://www.googleapis.com/auth/youtube.readonly"
        try rejects("scope") { _ = try CommentAPIModel.tokens(denied, clientID: "client") }
        var missing = valid
        missing.removeValue(forKey: "refresh_token")
        try rejects("response") { _ = try CommentAPIModel.tokens(missing, clientID: "client") }
        let renewed = try CommentAPIModel.tokens(["access_token": "new", "expires_in": 3600.0], clientID: "client", previous: token)
        try expect(renewed.accessToken == "new" && renewed.refreshToken == "refresh", "Refresh retains credential")
        try rejects("scope") { _ = try CommentAPIModel.tokens(denied, clientID: "client", previous: token) }
    }

    static func playback() throws {
        for background in [false, true] {
            for airPlay in [false, true] {
                for pip in [false, true] {
                    let result = BackgroundPlaybackPolicy.shouldContinue(backgroundEnabled: background, airPlayActive: airPlay, pipActive: pip)
                    try expect(result == (background || airPlay || pip), "Background playback policy")
                }
            }
        }
        try expect(!BackgroundPlaybackPolicy.shouldPauseAfterPiP(restoring: false, airPlayActive: true), "Closing PiP must not pause AirPlay")
        try expect(!BackgroundPlaybackPolicy.shouldPauseAfterPiP(restoring: true, airPlayActive: false), "Restoring PiP must not pause")
        try expect(BackgroundPlaybackPolicy.shouldPauseAfterPiP(restoring: false, airPlayActive: false), "Ordinary PiP close still pauses")
    }
}


extension NativeCommentsChecks {
    static func nestedReplyRecipients() throws {
        func comment(_ id: String, _ author: String) -> Comment {
            Comment(id: id, authorName: author, authorChannelId: nil, authorAvatarURL: nil,
                    content: "Hello", publishedTime: nil, likeCount: nil, replyCount: nil,
                    isPinned: false, replyContinuation: nil)
        }
        let root = comment("root", "@original")
        let alice = CommentPostTarget.reply(videoID: "video", parent: root, recipient: comment("alice", "@Alice"))
        let bob = CommentPostTarget.reply(videoID: "video", parent: root, recipient: comment("bob", "@Bob"))
        try expect(alice.parentID == "root" && bob.parentID == "root", "Nested replies post to the actual root")
        try expect(alice.parentAuthor == "@Alice" && bob.mentionPrefix == "@Bob ", "Address the tapped person")
        try expect(alice.draftKey != bob.draftKey, "Different recipients do not inherit the original mention")
        let store = CommentDraftStore()
        store.update("@Alice First draft", for: alice)
        store.update("@Bob Second draft", for: bob)
        let sent = store.begin(alice)!
        store.finish(sent, succeeded: true)
        try expect(store.text(for: bob) == "@Bob Second draft", "Sending to one recipient preserves the other draft")
        let body = try bob.body(text: "@Bob hello", channelID: nil)
        let snippet = body["snippet"] as? [String: String]
        try expect(snippet?["parentId"] == "root" && snippet?["textOriginal"] == "@Bob hello", "Write keeps parent and recipient separate")
    }

    static func drafts() throws {
        let store = CommentDraftStore()
        let video = CommentPostTarget(videoID: "video-a")
        let reply = CommentPostTarget(videoID: "video-a", parentID: "reply-a")
        let other = CommentPostTarget(videoID: "video-b")
        try expect(store.begin(video) == nil, "Empty draft cannot send")
        store.update("First comment", for: video)
        store.update("Reply draft", for: reply)
        store.update("Other video", for: other)
        let submitted = store.begin(video)!
        try expect(store.begin(video) == nil, "Duplicate tap cannot send twice")
        store.update("Accidental replacement", for: video)
        try expect(submitted.text == "First comment", "Send captures immutable text")
        try expect(store.text(for: video) == "First comment", "In-flight draft is locked")
        store.finish(submitted, succeeded: false)
        try expect(store.text(for: video) == "First comment", "Failure retains draft")
        let retry = store.begin(video)!
        store.finish(retry, succeeded: true)
        try expect(store.text(for: video).isEmpty, "Confirmed post clears captured draft")
        try expect(store.text(for: reply) == "Reply draft", "Reply survives parent completion")
        try expect(store.text(for: other) == "Other video", "Changing videos cannot clear wrong draft")
    }

    static func websiteSession() throws {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: "SAPISID", .value: "example", .domain: ".youtube.com", .path: "/", .secure: "TRUE"
        ]
        let cookie = HTTPCookie(properties: properties)!
        try expect(YouTubeCommentSession.isYouTubeCookie(cookie), "Accept connected YouTube cookie")
        for domain in [".google.com", "youtube.com.attacker.invalid", ".notyoutube.com"] {
            var bad = properties
            bad[.domain] = domain
            try expect(!YouTubeCommentSession.isYouTubeCookie(HTTPCookie(properties: bad)!), "Reject unrelated cookie domain")
        }
        var insecure = properties
        insecure.removeValue(forKey: .secure)
        try expect(!YouTubeCommentSession.isYouTubeCookie(HTTPCookie(properties: insecure)!), "Reject nonsecure cookie")
        let context = try JSONSerialization.data(withJSONObject: ["client": ["clientName": "WEB", "clientVersion": "test"]])
        var session = YouTubeCommentSession(cookies: [YouTubeCommentCookie(cookie)], contextData: context, accountIndex: "2", pageID: "chosen-channel", channel: nil)
        let headers = try session.headers(now: Date(timeIntervalSince1970: 1000))
        try expect(headers["Authorization"] == "SAPISIDHASH 1000_6516e6a3428b53b9ebaca799e16d4e2295791541", "YouTube website authorization hash vector")
        try expect(headers["X-Goog-AuthUser"] == "2" && headers["X-Goog-PageId"] == "chosen-channel", "Preserve selected identity")
        let user = try session.context()["user"] as! [String: String]
        try expect(user["onBehalfOfUser"] == "chosen-channel", "Preserve selected brand channel")
        var expired = properties
        expired[.expires] = Date(timeIntervalSince1970: 500)
        session.cookies = [YouTubeCommentCookie(HTTPCookie(properties: expired)!)]
        try rejects("signedOut") { _ = try session.headers(now: Date(timeIntervalSince1970: 1000)) }
    }

    static func websiteComments() throws {
        let top = CommentPostTarget(videoID: "video")
        let header: [String: Any] = ["commentsHeaderRenderer": ["createRenderer": ["commentSimpleboxRenderer": ["submitButton": ["buttonRenderer": ["serviceEndpoint": ["createCommentEndpoint": ["createCommentParams": "server-provided"]]]]]]]]
        let body = try YouTubeCommentModel.writeBody(in: header, target: top)
        try expect(body["createCommentParams"] as? String == "server-provided", "Use server offered posting capability")
        try rejects("commentsDisabled") { _ = try YouTubeCommentModel.writeBody(in: [:], target: top) }
        try rejects("operationNotSupported") {
            _ = try YouTubeCommentModel.writeBody(in: ["commentsHeaderRenderer": ["createRenderer": ["signInEndpoint": [:]]]], target: top)
        }
        try rejects("parentCommentNotFound") {
            _ = try YouTubeCommentModel.writeBody(in: header, target: CommentPostTarget(videoID: "video", parentID: "missing"))
        }
        let created: [String: Any] = ["actionResult": "ACTION_RESULT_SUCCESS", "actions": [["createCommentAction": ["commentRenderer": ["commentId": "confirmed-id", "contentText": ["runs": [["text": "Hello"]]], "authorText": ["simpleText": "Channel"]]]]]]
        let comment = try YouTubeCommentModel.createdComment(created)
        try expect(comment.id == "confirmed-id" && comment.content == "Hello", "Website confirmed resource")
        try rejects("uncertain") { _ = try YouTubeCommentModel.createdComment(["actionResult": "ACTION_RESULT_SUCCESS"]) }
        var failed = created
        failed["actionResult"] = "ACTION_RESULT_FAILED"
        try rejects("uncertain") { _ = try YouTubeCommentModel.createdComment(failed) }
        var denied = created
        denied["error"] = ["code": 403]
        try rejects("uncertain") { _ = try YouTubeCommentModel.createdComment(denied) }
        let account = try YouTubeCommentModel.account(["activeAccountHeaderRenderer": ["channelHandle": ["simpleText": "@selected"]]])
        try expect(account.title == "@selected", "Verify selected website account before saving")
        try rejects("signedOut") { _ = try YouTubeCommentModel.account([:]) }
    }

    static func interruptions() throws {
        var state = PlaybackInterruptionState()
        state.begin(wasPlaying: true, lastUserPause: 2)
        try expect(state.end(shouldResume: true, lastUserPause: 2), "Resume permitted interruption")
        try expect(!state.end(shouldResume: true, lastUserPause: 2), "Ignore duplicate interruption end")
        state.begin(wasPlaying: false, lastUserPause: 3)
        try expect(!state.canResume(lastUserPause: 3), "Foreground fallback never resumes a pre-paused video")
        try expect(!state.end(shouldResume: true, lastUserPause: 3), "Never resume an already paused video")
        state.begin(wasPlaying: true, lastUserPause: 3)
        try expect(!state.end(shouldResume: false, lastUserPause: 3), "Respect another app retaining audio")
        state.begin(wasPlaying: true, lastUserPause: 3)
        try expect(state.canResume(lastUserPause: 3), "Missing-ended recovery preserves original play intent")
        state.begin(wasPlaying: false, lastUserPause: 4)
        try expect(state.canResume(lastUserPause: 3), "Duplicate begin preserves the original interruption")
        try expect(!state.canResume(lastUserPause: 4), "A later user pause cancels foreground fallback")
        try expect(!state.end(shouldResume: true, lastUserPause: 4), "Respect remote pause or route disconnect during interruption")
        state.begin(wasPlaying: true, lastUserPause: 4)
        state = PlaybackInterruptionState()
        try expect(!state.active && !state.canResume(lastUserPause: 4), "Successful playback or replacement retires stale recovery")
        try expect(!state.end(shouldResume: true, lastUserPause: 4), "A late ended notification cannot restart retired playback")
    }
}
