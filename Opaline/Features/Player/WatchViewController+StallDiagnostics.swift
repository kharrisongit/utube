import AVFoundation
import UIKit

extension WatchViewController {
    @objc
    func playerItemDidStall(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem else {
            return
        }
        logPlaybackStall("playback stalled", item: item)
    }

    func logPlaybackStall(_ event: String, item: AVPlayerItem) {
        // AVFoundation may deliver item notifications off the main thread.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.logPlaybackStall(event, item: item)
            }
            return
        }
        guard let player = videoPlayerView?.player, player.currentItem === item else {
            return
        }
        let source = playbackFacade.activeVideoSource
        let position = item.currentTime()
        let route = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
        AppLog.player(
            "\(event): video=\(initialVideo.id) source=\(source?.name ?? "?")"
                + " quality=\(source?.currentQuality?.label ?? "?")"
                + " position=\(stallMetric(position.seconds))s"
                + " bufferedAhead=\(stallMetric(bufferedAhead(item, at: position)))s"
                + " empty=\(item.isPlaybackBufferEmpty) keepUp=\(item.isPlaybackLikelyToKeepUp)"
                + " wait=\(player.reasonForWaitingToPlay?.rawValue ?? "none")"
                + " route=\(route.joined(separator: ","))"
                + " external=\(player.isExternalPlaybackActive)"
                + " \(stallWatch.network.summary)"
                + " \(stallTransfer(item.accessLog()?.events.last))"
        )
    }

    func bufferedAhead(_ item: AVPlayerItem, at time: CMTime) -> Double {
        guard time.seconds.isFinite else {
            return .nan
        }
        let range = item.loadedTimeRanges.lazy.map(\.timeRangeValue)
            .first { $0.start <= time && time < $0.end }
        return range.map { $0.end.seconds - time.seconds } ?? 0
    }

    private func stallTransfer(_ access: AVPlayerItemAccessLogEvent?) -> String {
        guard let access else {
            return "accessLog=unavailable"
        }
        return "bytes=\(access.numberOfBytesTransferred)"
            + " transfer=\(stallMetric(access.transferDuration))s"
            + " observedKbps=\(stallMetric(access.observedBitrate / 1_000))"
            + " indicatedKbps=\(stallMetric(access.indicatedBitrate / 1_000))"
            + " stalls=\(access.numberOfStalls) \(mediaEndpoint(access.uri))"
    }

    private func stallMetric(_ value: Double) -> String {
        value.isFinite && value >= 0 ? String(format: "%.1f", value) : "?"
    }

    /// Google media URLs include signed tokens and the device's public IP address.
    func mediaEndpoint(_ uri: String?) -> String {
        guard let uri, let parts = URLComponents(string: uri), let host = parts.host else {
            return "host=?"
        }
        let itag = parts.queryItems?.first { $0.name == "itag" }?.value.flatMap(Int.init)
        return "host=\(host)" + (itag.map { " itag=\($0)" } ?? "")
    }

    func playbackErrorText(_ message: String?) -> String {
        (message ?? "unknown").replacingOccurrences(
            of: #"(?i)https?://\S+"#,
            with: "[media URL]",
            options: .regularExpression
        )
    }
}
