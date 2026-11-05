import Foundation

/// Fetches SABR media one segment at a time.
///
/// This mirrors how googlevideo's own player adapter works, and it is the
/// whole design: a player's request for a segment becomes one
/// `VideoPlaybackAbrRequest`, the response is read until the segment it asked
/// for is complete, and the rest of the response is dropped. There is no
/// rolling buffer, no prefetch and no notion of the stream being "at" a
/// position — the player's own buffering does that job, and every request
/// states afresh where it wants bytes from.
///
/// What persists between requests is only what the server needs to keep the
/// session coherent: the last segment seen per format, the playback cookie and
/// the backoff it asked for.
final class SABRFetcher {
    /// What one request needs from the shared state, taken under a single
    /// lock: its number, what is held of this format, and the cookie.
    private struct RequestState {
        let number: Int
        let url: URL
        let held: SABRBufferedRange?
        let cookie: Data?
    }

    private struct Attempt {
        let request: SABRSegmentRequest
        var redirects: Set<URL> = []
    }

    private let transport: HTTPTransport
    let ustreamerConfig: Data
    let identity: SABRIdentity

    /// Guards everything below; requests run concurrently, one per segment,
    /// and audio and video are routinely in flight together.
    private let lock = NSLock()
    private var url: URL
    private var lastSegment: [Int: SABRBufferedRange] = [:]
    private var lastRequestedMs: [Int: Int] = [:]
    private var playbackCookie: Data?
    private var backoffUntil = Date.distantPast
    private var requestNumber = 0
    private var stopped = false
    /// A fetcher serves one fixed pair of tracks. AirPlay can make several
    /// overlapping probes for the first media segment of either track.
    private var openingRequests: [Int: [(Result<Data, Error>) -> Void]] = [:]

    init(
        transport: HTTPTransport,
        url: URL,
        ustreamerConfig: Data,
        identity: SABRIdentity
    ) {
        self.transport = transport
        self.url = url
        self.ustreamerConfig = ustreamerConfig
        self.identity = identity
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// The bytes of one segment, or an error. Runs one POST; the response is
    /// abandoned as soon as the segment is complete. Redirects retry the same request.
    func fetch(
        _ request: SABRSegmentRequest,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let attempt = Attempt(request: request)
        guard !request.isInit, request.sequence == 1 else {
            fetch(attempt, completion: completion)
            return
        }
        let itag = request.format.itag
        lock.lock()
        let alreadyFetching = openingRequests[itag] != nil
        openingRequests[itag, default: []].append(completion)
        lock.unlock()
        guard !alreadyFetching else {
            return
        }
        fetch(attempt) { result in
            self.lock.lock()
            let waiting = self.openingRequests.removeValue(forKey: itag) ?? []
            self.lock.unlock()
            waiting.forEach { $0(result) }
        }
    }

    private func fetch(
        _ attempt: Attempt,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        lock.lock()
        let stopped = self.stopped
        let wait = backoffUntil.timeIntervalSinceNow
        lock.unlock()
        guard !stopped else {
            completion(.failure(SABRError.stalled))
            return
        }
        guard wait <= 0 else {
            // The server asked for a pause; honouring it is cheaper than being
            // told again.
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + wait) {
                    self.fetch(attempt, completion: completion)
                }
            return
        }
        send(attempt, completion: completion)
    }

    private func send(
        _ attempt: Attempt,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let collector = SABRSegmentCollector(request: attempt.request)
        let state = stateFor(attempt.request)
        let started = Date()
        let request = httpRequest(for: attempt.request, state: state)
        transport.stream(request, cancellationToken: nil) { chunk in
            collector.append(chunk)
            // Stop the moment the segment is whole: the rest of the response is
            // the stream running on past what this request was about.
            return !collector.isDone
        } completion: { result in
            self.apply(collector.policy)
            if case .success(let response) = result, response.status == 200,
               let target = collector.redirectURL {
                self.followRedirect(target, attempt: attempt, sent: state, completion: completion)
                return
            }
            self.finish(result, collector: collector, started: started, completion: completion)
        }
    }

    private func followRedirect(
        _ target: URL,
        attempt: Attempt,
        sent: RequestState,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard attempt.redirects.count < SABRRedirect.maximumHops,
              !attempt.redirects.contains(target), target != sent.url else {
            completion(.failure(SABRError.server("streaming redirect limit or loop")))
            return
        }
        lock.lock()
        // Another track may already have moved this session forward. A late
        // response from the old endpoint must not overwrite its newer URL.
        if url == sent.url {
            url = target
        }
        lock.unlock()
        var next = attempt
        next.redirects.insert(target)
        AppLog.hls("sabr redirect \(next.redirects.count)/\(SABRRedirect.maximumHops)")
        fetch(next, completion: completion)
    }

    /// A refusal never reaches the SABR protocol: googlevideo rejected the URL
    /// itself. Not logged with the URL — that carries the po token — but its
    /// answer names what it disliked and is worth having.
    private func refusal(_ response: HTTPResponse, label: String) -> Error {
        let reason = String(data: response.data.prefix(200), encoding: .utf8) ?? ""
        AppLog.hls(
            "sabr \(label): HTTP \(response.status)"
                + (reason.isEmpty ? "" : " — \(reason)")
        )
        if response.status == 403 {
            return PlaybackFailure.tokenRejected
        }
        if response.status == 429 {
            return PlaybackFailure.rateLimited
        }
        return SABRError.server("HTTP \(response.status)")
    }

    private func finish(
        _ result: Result<HTTPResponse, Error>,
        collector: SABRSegmentCollector,
        started: Date,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        if let error = failure(in: result, collector: collector) {
            completion(.failure(error))
            return
        }
        guard let data = collector.segment else {
            AppLog.hls("sabr \(collector.noMediaLine)")
            completion(.failure(SABRError.stalled))
            return
        }
        if let range = collector.deliveredRange {
            lock.lock()
            lastSegment[collector.request.format.itag] = range
            lock.unlock()
        }
        let ms = Int(Date().timeIntervalSince(started) * 1_000)
        AppLog.hls(
            "sabr \(collector.label) -> \(data.count)B of \(collector.received)B in \(ms)ms"
        )
        completion(.success(data))
    }

    private func failure(
        in result: Result<HTTPResponse, Error>, collector: SABRSegmentCollector
    ) -> Error? {
        lock.lock()
        let stopped = self.stopped
        lock.unlock()
        if stopped {
            return SABRError.stalled
        }
        if case .failure(let error) = result, !collector.isDone {
            return error
        }
        if case .success(let response) = result, response.status != 200 {
            return refusal(response, label: collector.label)
        }
        return collector.failure
    }

    private func apply(_ policy: SABRPolicy?) {
        guard let policy else {
            return
        }
        lock.lock()
        if let cookie = policy.playbackCookie {
            playbackCookie = cookie
        }
        if policy.backoffMs > 0 {
            backoffUntil = Date().addingTimeInterval(Double(policy.backoffMs) / 1_000)
            AppLog.hls("sabr backoff \(policy.backoffMs)ms")
        }
        lock.unlock()
    }
}

extension SABRFetcher {
    private func stateFor(_ request: SABRSegmentRequest) -> RequestState {
        lock.lock()
        defer { lock.unlock() }
        requestNumber += 1
        let itag = request.format.itag
        // A request behind the last one is the player having moved back, and
        // what was last received no longer describes where it is. googlevideo's
        // adapter drops the same state on the same condition.
        if request.timeMs < lastRequestedMs[itag] ?? 0 {
            lastSegment[itag] = nil
        }
        lastRequestedMs[itag] = request.timeMs
        return RequestState(
            number: requestNumber,
            url: url,
            held: lastSegment[itag]?.acknowledged(for: request),
            cookie: playbackCookie
        )
    }

    private func httpRequest(for request: SABRSegmentRequest, state: RequestState) -> HTTPRequest {
        var headers = [HTTPHeader.contentType: "application/x-protobuf"]
        headers[HTTPHeader.userAgent] = identity.client.userAgent
        return HTTPRequest(
            method: .post,
            url: SABRRedirect.numberedURL(state.url, number: state.number),
            headers: headers,
            body: SABRRequest.segment(
                ustreamerConfig: ustreamerConfig,
                state: SABRRequest.Fetch(
                    format: request.format,
                    other: request.other,
                    held: state.held,
                    isInit: request.isInit,
                    playerMs: request.timeMs,
                    playbackCookie: state.cookie
                ),
                identity: identity
            ),
            // One segment is seconds of media; a request still running after
            // this is one the player gave up on long ago.
            timeout: 20,
            // Anonymous: cookies were tried on device and changed nothing.
            sendsCookies: false,
            isPlayback: true
        )
    }
}
