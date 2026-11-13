import AVFoundation
import UIKit

final class PlayerInterruptionTracker {
    var state = PlaybackInterruptionState()
    var lastPlayingAt: CFTimeInterval = 0
    weak var player: AVPlayer?
    var interruptedAirPlayInBackground = false
    var airPlayDropUserPause: CFTimeInterval = 0
}

extension VideoPlayerView {
    func observeAudioInterruptions() {
        // Pulling out a headphone pauses us through the audio session, with
        // the app still frontmost — exactly what the multitasking heuristic
        // reads as a stolen route, so it played on the speaker (#104).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc
    func audioInterrupted(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAudioInterruption(note)
        }
    }

    private func handleAudioInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              let player else {
            return
        }
        logPlaybackState("audio interruption \(type.rawValue)")
        switch type {
        case .began:
            if player.isExternalPlaybackActive && !AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .airPlay }) {
                interruption.interruptedAirPlayInBackground = true
                interruption.airPlayDropUserPause = multitaskPause.lastUserPause
                AppLog.player("AirPlay interrupted after audio route moved to local output")
            }
            multitaskPause.systemPaused = false
            // AVPlayer may already have changed rate to zero before this notification arrives.
            let recentlyPlaying = CACurrentMediaTime() - interruption.lastPlayingAt < 1
                && interruption.lastPlayingAt > multitaskPause.lastUserPause
            interruption.state.begin(
                wasPlaying: player.rate > 0 || recentlyPlaying,
                lastUserPause: multitaskPause.lastUserPause
            )
            interruption.player = player
            player.pause()
        case .ended:
            resumeAfterInterruption(note, player: player)
        @unknown default:
            break
        }
    }

    private func resumeAfterInterruption(_ note: Notification, player: AVPlayer) {
        let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let allowed = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
        let samePlayer = interruption.player === player
        let resume = interruption.state.end(
            shouldResume: allowed && samePlayer,
            lastUserPause: multitaskPause.lastUserPause
        )
        interruption.player = nil
        if interruption.interruptedAirPlayInBackground {
            interruption.interruptedAirPlayInBackground = false
            if resume && !isAirPlayActive {
                AppLog.player("AirPlay interruption ended; local playback available")
            }
        }
        guard resume, player.currentItem?.status == .readyToPlay else {
            return
        }
        let canPlay = UIApplication.shared.applicationState != .background
            || BackgroundPlaybackPolicy.shouldContinue(
                backgroundEnabled: BackgroundPlaybackService.isEnabled,
                airPlayActive: isAirPlayActive,
                pipActive: isPiPActive
            )
        guard canPlay, BackgroundPlaybackService.activate() else {
            return
        }
        player.playImmediately(atRate: playbackSpeed)
        logPlaybackState("resumed after audio interruption")
    }

    func logPlaybackState(_ event: String) {
        guard let player else {
            return
        }
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
        AppLog.player(
            "\(event): rate=\(player.rate) state=\(player.timeControlStatus.rawValue)"
                + " external=\(player.isExternalPlaybackActive)"
                + " route=\(ports.joined(separator: ","))"
                + " app=\(UIApplication.shared.applicationState.rawValue)"
                + " empty=\(player.currentItem?.isPlaybackBufferEmpty == true)"
        )
    }
}
