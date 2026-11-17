import AVFoundation
import UIKit

/// Bookkeeping for the iPad multitasking pause — see `noteSystemPause`.
final class MultitaskPauseState {
    var systemPaused = false
    var lastUserPause: CFTimeInterval = 0
    var lastResume: CFTimeInterval = 0
    var resumeAttempts = 0
    var airPlayRecoveryGeneration = 0
}

extension VideoPlayerView {
    /// The pause AVPlayer performs on reaching the end looks exactly like a
    /// system pause. Resuming there plays nothing and parks the player in
    /// `waitingToPlayAtSpecifiedRate` — a spinner that never clears.
    private var hasPlayedToEnd: Bool {
        guard let item = player?.currentItem,
              item.duration.isNumeric
        else {
            return false
        }
        let remaining = CMTimeGetSeconds(item.duration)
            - CMTimeGetSeconds(item.currentTime())
        return remaining < 0.5
    }

    /// A pause we did not ask for, while the app is on screen and active: iPad
    /// multitasking takes video away from an app the moment it stops being the
    /// frontmost one (dragged into Slide Over beside another app). Nothing
    /// reports it, and playing again right after is accepted — so that is what
    /// happens here, capped at two tries per 10s so we never fight the system.
    func noteSystemPause(rate: Float) {
        if rate > 0 {
            multitaskPause.systemPaused = false
            return
        }
        let now = CACurrentMediaTime()
        guard !interruption.state.active,
              !isPiPActive,
              !isAirPlayActive,
              !hasPlayedToEnd,
              UIApplication.shared.applicationState == .active,
              now - multitaskPause.lastUserPause > 0.5
        else {
            return
        }
        if now - multitaskPause.lastResume > 10 {
            multitaskPause.resumeAttempts = 0
        }
        guard multitaskPause.resumeAttempts < 2 else {
            return
        }
        multitaskPause.systemPaused = true
        multitaskPause.resumeAttempts += 1
        multitaskPause.lastResume = now
        AppLog.player("paused while active — multitasking, resuming")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.resumeAfterSystemPause()
        }
    }

    /// A route that went away (headphone unplugged, Bluetooth disconnected)
    /// pauses playback, and it must stay paused: playing on the speaker is
    /// the one thing the pause is there to prevent. Marked as a user pause,
    /// which is what the resume above checks — and it is checked again after
    /// the delay, so the order of the two notifications does not matter.
    @objc
    func audioRouteChanged(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        let previousPorts = previous?.outputs.map { $0.portType.rawValue } ?? []
        let previouslyAirPlay = previous?.outputs.contains {
            $0.portType == .airPlay
        } ?? false
        let currentPorts = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
        AppLog.player(
            "audio route changed: reason=\(raw) previous=\(previousPorts.joined(separator: ","))"
                + " current=\(currentPorts.joined(separator: ","))"
        )
        DispatchQueue.main.async { [weak self] in
            self?.handleAudioRouteChange(raw: raw, previouslyAirPlay: previouslyAirPlay)
        }
    }

    private func handleAudioRouteChange(raw: UInt, previouslyAirPlay: Bool) {
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        refreshAirPlayRoute()
        let now = CACurrentMediaTime()
        let wasPlaying = player?.rate ?? 0 > 0
            || (now - interruption.lastPlayingAt < 2
                && interruption.lastPlayingAt > multitaskPause.lastUserPause)
        let routeLostAirPlay = previouslyAirPlay
            && !AVAudioSession.sharedInstance().currentRoute.outputs.contains {
                $0.portType == .airPlay
            }
            && !isAirPlayActive

        if reason == .oldDeviceUnavailable {
            logPlaybackState("audio output disconnected")
            // A removed headphone or Bluetooth receiver must never trigger
            // unexpected playback from the phone speaker.
            multitaskPause.lastUserPause = now
        }
        if routeLostAirPlay {
            logPlaybackState("AirPlay route lost (reason=\(raw))")
            // iOS sometimes reports a category/configuration change rather
            // than oldDeviceUnavailable when the receiver drops. Don't
            // ignore that case. This cannot force the TV to reconnect;
            // only attempt local recovery after the interruption ends.
            if wasPlaying && !isAtEnd {
                scheduleAirPlayDropRecovery()
            }
        } else if reason == .newDeviceAvailable || isAirPlayActive {
            // Prevent an old delayed fallback from playing on the phone
            // after an AirPlay route has been restored.
            multitaskPause.airPlayRecoveryGeneration += 1
            interruption.cancelPendingRecovery()
        }
    }

    private func scheduleAirPlayDropRecovery() {
        guard let player, let item = player.currentItem else {
            return
        }
        multitaskPause.airPlayRecoveryGeneration += 1
        let generation = multitaskPause.airPlayRecoveryGeneration
        let pauseAtDrop = multitaskPause.lastUserPause
        AppLog.player("unexpected AirPlay disconnect: awaiting stable local route")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2.0
        ) { [weak self, weak player, weak item] in
            guard let self, let player, let item else {
                return
            }
            finishAirPlayDropRecovery(
                player: player, item: item, generation: generation, pauseAtDrop: pauseAtDrop
            )
        }
    }

    private func finishAirPlayDropRecovery(
        player: AVPlayer, item: AVPlayerItem, generation: Int, pauseAtDrop: CFTimeInterval
    ) {
        guard generation == multitaskPause.airPlayRecoveryGeneration,
              self.player === player, player.currentItem === item,
              player.rate == 0, item.status == .readyToPlay, !interruption.state.active,
              !isPiPActive, !isAtEnd, !isAirPlayActive,
              multitaskPause.lastUserPause == pauseAtDrop,
              UIApplication.shared.applicationState == .active,
              !AVAudioSession.sharedInstance().isOtherAudioPlaying else {
            logPlaybackState("AirPlay fallback deferred or cancelled")
            return
        }
        guard BackgroundPlaybackService.activate() else {
            logPlaybackState("AirPlay fallback audio activation failed")
            return
        }
        player.playImmediately(atRate: playbackSpeed)
        logPlaybackState("AirPlay disconnected; requested local resume")
    }

    private func resumeAfterSystemPause() {
        guard multitaskPause.systemPaused, !interruption.state.active,
              let player, player.rate == 0,
              !isPiPActive, !isAirPlayActive,
              CACurrentMediaTime() - multitaskPause.lastUserPause > 0.5
        else {
            return
        }
        player.play()
    }
}
