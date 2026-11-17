import UIKit
import WebKit

/// A visible YouTube page: the user completes any checks themselves. Importing
/// visitor state is an experiment, not a claim that native playback is verified.
final class YouTubeVerificationView: UIViewController {
    let webView: WKWebView
    let status = UILabel()
    var busy = false
    var navigationGeneration = 0
    private var traceTimer: Timer?
    private var traceStarted = Date()
    private let traceID = String(UUID().uuidString.prefix(8))
    private var lastProgressBucket = -1
    private var progressObservation: NSKeyValueObservation?

    private let videoID: String?
    private let retry: () -> Void

    init(videoID: String?, retry: @escaping () -> Void) {
        self.videoID = videoID
        self.retry = retry
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "verification.title".localized
        webView.navigationDelegate = self
        webView.uiDelegate = self
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "common.cancel".localized, style: .plain, target: self, action: #selector(close)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "verification.retry".localized,
            style: .done,
            target: self,
            action: #selector(useSession)
        )
        navigationItem.rightBarButtonItem?.isEnabled = false
        setupLayout()
        beginTrace()
        if let url = VerificationURLPolicy.page(videoID: videoID) {
            webView.load(URLRequest(url: url))
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true || isBeingDismissed {
            trace("dismissed", url: webView.url)
            endTrace()
            webView.stopLoading()
        }
    }

    // Host only: never include URL paths, queries, cookies, codes or tokens.
    func trace(_ event: String, url: URL? = nil) {
        let host = url?.host?.lowercased() ?? "-"
        let elapsed = Int(Date().timeIntervalSince(traceStarted))
        AppLog.player("verification[\(traceID)] +\(elapsed)s \(event) host=\(host)")
    }

    private func beginTrace() {
        traceStarted = Date()
        trace("opened")
        progressObservation = webView.observe(
            \.estimatedProgress, options: [.new]
        ) { [weak self] observed, _ in
            guard let self else {
                return
            }
            let bucket = Int(observed.estimatedProgress * 10)
            guard bucket != self.lastProgressBucket else {
                return
            }
            self.lastProgressBucket = bucket
            self.trace("progress=\(bucket * 10)%", url: observed.url)
        }
        traceTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.view.window != nil else {
                return
            }
            self.trace(
                "checkpoint loading=\(self.webView.isLoading)"
                    + " progress=\(Int(self.webView.estimatedProgress * 100))%"
                    + " busy=\(self.busy)",
                url: self.webView.url
            )
        }
    }

    private func endTrace() {
        traceTimer?.invalidate()
        traceTimer = nil
        progressObservation?.invalidate()
        progressObservation = nil
    }

    private func setupLayout() {
        view.backgroundColor = ThemeManager.shared.background
        status.text = "verification.help".localized
        status.textColor = ThemeManager.shared.primaryText
        status.font = .preferredFont(forTextStyle: .caption1)
        status.numberOfLines = 0
        for item in [status, webView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            webView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ])
    }

    @objc
    private func close() {
        trace("cancel tapped", url: webView.url)
        endTrace()
        webView.stopLoading()
        dismiss(animated: true)
    }

    @objc
    private func useSession() {
        trace(
            "retry tapped loading=\(webView.isLoading) busy=\(busy)"
                + " onYouTube=\(VerificationURLPolicy.isYouTube(webView.url))",
            url: webView.url
        )
        guard !busy, !webView.isLoading, VerificationURLPolicy.isYouTube(webView.url) else {
            trace("retry rejected by state", url: webView.url)
            return
        }
        busy = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let expected = navigationGeneration
        let script = "window.ytcfg && (ytcfg.get('VISITOR_DATA') || "
            + "((ytcfg.get('INNERTUBE_CONTEXT') || {}).client || {}).visitorData)"
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, navigationGeneration == expected else {
                return
            }
            self.trace(
                "visitor available=\((value as? String)?.isEmpty == false)",
                url: self.webView.url
            )
            guard let visitor = value as? String, !visitor.isEmpty else {
                importFailed()
                return
            }
            capture(visitor: visitor, expected: expected)
        }
    }

    private func capture(visitor: String, expected: Int) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self, view.window != nil, navigationGeneration == expected,
                  !webView.isLoading, VerificationURLPolicy.isYouTube(webView.url) else {
                      return
                  }
            trace("cookie count=\(cookies.count)", url: webView.url)
            guard VisitorIdentityStore.shared.adopt(
                visitor: visitor, browserCookies: cookies
            ) else {
                importFailed()
                return
            }
            trace("visitor imported; native result pending", url: webView.url)
            endTrace()
            AppLog.player("verification: imported anonymous visitor state; native result pending")
            webView.stopLoading()
            dismiss(animated: true, completion: retry)
        }
    }

    private func importFailed() {
        trace("visitor import failed", url: webView.url)
        busy = false
        navigationItem.rightBarButtonItem?.isEnabled = true
        status.text = "verification.noSession".localized
    }

    deinit { endTrace() }
}
