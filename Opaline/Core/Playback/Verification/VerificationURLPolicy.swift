import Foundation

enum VerificationURLPolicy {
    static func isYouTube(_ url: URL?) -> Bool {
        guard let url, isHTTPS(url) else {
            return false
        }
        return ["www.youtube.com", "m.youtube.com", "youtube.com"].contains(url.host ?? "")
    }

    static func allowsNavigation(_ url: URL?) -> Bool {
        guard let url, isHTTPS(url) else {
            return false
        }
        return isYouTube(url) || [
            "accounts.google.com", "accounts.youtube.com", "consent.youtube.com", "consent.google.com",
            "www.google.com", "google.com"
        ].contains(url.host ?? "")
    }

    static func page(videoID: String?) -> URL? {
        var url = URLComponents(string: "https://www.youtube.com/")
        if let videoID,
           videoID.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            url?.path = "/watch"
            url?.queryItems = [URLQueryItem(name: "v", value: videoID)]
        }
        return url?.url
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }
}
