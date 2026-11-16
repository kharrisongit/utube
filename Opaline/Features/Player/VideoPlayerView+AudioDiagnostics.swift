import AVFoundation
import UIKit

extension VideoPlayerView {
    var audioPlaybackMetrics: String {
        guard let player, let item = player.currentItem else {
            return "item=none"
        }
        let seconds = item.currentTime().seconds
        let position = seconds.isFinite ? String(format: "%.1f", seconds) : "unknown"
        return "position=\(position)s itemStatus=\(item.status.rawValue)"
            + " wait=\(player.reasonForWaitingToPlay?.rawValue ?? "none")"
            + " interrupted=\(interruption.state.active)"
    }

    func observeAudioDiagnostics() {
        let center = NotificationCenter.default
        let names = [
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification
        ]
        for name in names {
            center.addObserver(
                self, selector: #selector(audioServicesChanged(_:)), name: name, object: nil
            )
        }
    }

    @objc
    private func audioServicesChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.logPlaybackState("audio services event \(note.name.rawValue)")
            self?.logAudioSession("audio services session")
        }
    }

    func logAudioInterruption(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).map { String($0) }
        let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { String($0) }
        let suspended = (info[AVAudioSessionInterruptionWasSuspendedKey] as? Bool)
            .map { String($0) } ?? "unreported"
        AppLog.player(
            "audio interruption details: type=\(type ?? "unreported")"
                + " reason=\(interruptionReason(info)) options=\(options ?? "unreported")"
                + " wasSuspended=\(suspended)"
        )
        logAudioSession("audio interruption session")
    }

    func logAudioSession(_ event: String) {
        let session = AVAudioSession.sharedInstance()
        AppLog.player(
            "\(event): category=\(session.category.rawValue) mode=\(session.mode.rawValue)"
                + " policy=\(session.routeSharingPolicy.rawValue)"
                + " otherAudio=\(session.isOtherAudioPlaying)"
                + " secondarySilence=\(session.secondaryAudioShouldBeSilencedHint)"
                + " \(PlaybackNetworkPath.shared.summary)"
        )
    }

    private func interruptionReason(_ info: [AnyHashable: Any]) -> String {
        guard #available(iOS 14.5, *),
              let raw = info[AVAudioSessionInterruptionReasonKey] as? UInt else {
            return "unreported"
        }
        if #available(iOS 17.0, *),
           raw == AVAudioSession.InterruptionReason.routeDisconnected.rawValue {
            return "routeDisconnected(\(raw))"
        }
        guard let reason = AVAudioSession.InterruptionReason(rawValue: raw) else {
            return "unknown(\(raw))"
        }
        switch reason {
        case .default:
            return "default(\(raw))"
        case .appWasSuspended:
            return "appWasSuspended(\(raw))"
        case .builtInMicMuted:
            return "builtInMicMuted(\(raw))"
        default:
            return "unknown(\(raw))"
        }
    }
}
