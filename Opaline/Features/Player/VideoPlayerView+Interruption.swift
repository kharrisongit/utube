import AVFoundation
import UIKit

final class PlayerInterruptionTracker {
    var state = PlaybackInterruptionState()
    var lastPlayingAt: CFTimeInterval = 0
    weak var player: AVPlayer?
    weak var item: AVPlayerItem?
    var interruptedAirPlayInBackground = false
    var generation = 0
    var foregroundRecoveryScheduled = false

    func matches(_ player: AVPlayer) -> Bool {
        self.player === player && item != nil && item === player.currentItem
    }

    func cancelPendingRecovery() {
        generation += 1
        foregroundRecoveryScheduled = false
    }

    func clear() {
        state = PlaybackInterruptionState()
        player = nil
        item = nil
        interruptedAirPlayInBackground = false
        cancelPendingRecovery()
    }
}

extension VideoPlayerView {
    func observeAudioInterruptions() {
        observeAudioDiagnostics()
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
        logAudioInterruption(note)
        logPlaybackState("audio interruption \(type.rawValue)")
        switch type {
        case .began:
            beginAudioInterruption(player: player)
        case .ended:
            resumeAfterInterruption(note, player: player)
        @unknown default:
            break
        }
    }

    private func beginAudioInterruption(player: AVPlayer) {
        guard !interruption.state.active || !interruption.matches(player) else {
            return
        }
        let recentlyPlaying = CACurrentMediaTime() - interruption.lastPlayingAt < 1
            && interruption.lastPlayingAt > multitaskPause.lastUserPause
        interruption.clear()
        multitaskPause.airPlayRecoveryGeneration += 1
        interruption.state.begin(
            wasPlaying: player.rate > 0 || recentlyPlaying,
            lastUserPause: multitaskPause.lastUserPause
        )
        interruption.player = player
        interruption.item = player.currentItem
        trackInterruptedAirPlay(player: player)
        multitaskPause.systemPaused = false
        player.pause()
    }

    private func trackInterruptedAirPlay(player: AVPlayer) {
        // The route can still read AirPlay when iOS interrupts a
        // background session; external playback may vanish seconds later
        // without an .ended notification (observed in the field).
        let backgroundAirPlay = isAirPlayActive
            && UIApplication.shared.applicationState == .background
        let routeMovedOffAirPlay = player.isExternalPlaybackActive
            && !AVAudioSession.sharedInstance().currentRoute.outputs.contains {
                $0.portType == .airPlay
            }
        guard backgroundAirPlay || routeMovedOffAirPlay,
              interruption.state.canResume(lastUserPause: multitaskPause.lastUserPause) else {
            return
        }
        interruption.interruptedAirPlayInBackground = true
        AppLog.player(
            "AirPlay interruption tracked: background=\(backgroundAirPlay)"
                + " routeMoved=\(routeMovedOffAirPlay)"
        )
    }

    private func resumeAfterInterruption(_ note: Notification, player: AVPlayer) {
        let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let allowed = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
        let samePlayback = interruption.matches(player)
        AppLog.player("audio interruption ended: shouldResume=\(allowed)"
            + " samePlayback=\(samePlayback)")
        let resume = interruption.state.end(
            shouldResume: allowed && samePlayback,
            lastUserPause: multitaskPause.lastUserPause
        )
        interruption.clear()
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
        logPlaybackState("requested resume after audio interruption")
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
                + " \(audioPlaybackMetrics)"
        )
    }
}
