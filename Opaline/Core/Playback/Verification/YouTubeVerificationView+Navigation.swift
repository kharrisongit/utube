import WebKit

extension YouTubeVerificationView: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        let allowed = VerificationURLPolicy.allowsNavigation(navigationAction.request.url)
        trace(
            allowed ? "navigation allowed" : "navigation blocked",
            url: navigationAction.request.url
        )
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        trace("navigation started", url: webView.url)
        navigationGeneration += 1
        busy = false
        navigationItem.rightBarButtonItem?.isEnabled = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        trace("navigation finished", url: webView.url)
        navigationItem.rightBarButtonItem?.isEnabled = VerificationURLPolicy.isYouTube(webView.url)
        status.text = "verification.help".localized
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        trace(
            "provisional error domain=\((error as NSError).domain) code=\((error as NSError).code)",
            url: webView.url
        )
        status.text = "verification.loadFailed".localized
        navigationItem.rightBarButtonItem?.isEnabled = VerificationURLPolicy.isYouTube(webView.url)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        trace("popup requested", url: navigationAction.request.url)
        if navigationAction.targetFrame == nil,
           VerificationURLPolicy.allowsNavigation(navigationAction.request.url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        trace(
            "navigation error domain=\((error as NSError).domain) code=\((error as NSError).code)",
            url: webView.url
        )
        status.text = "verification.loadFailed".localized
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            trace("HTTP status=\(response.statusCode)", url: response.url)
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        trace("web process terminated", url: webView.url)
        status.text = "verification.loadFailed".localized
    }
}
