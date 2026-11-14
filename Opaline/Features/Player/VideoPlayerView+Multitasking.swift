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
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        let previousPorts = previous?.outputs.map { $0.portType.rawValue } ?? []
        let previouslyAirPlay = previous?.outputs.contains {
            $0.portType == .airPlay
        } ?? false
        AppLog.player(
            "audio route changed: reason=\(raw) previous=\(previousPorts.joined(separator: ","))"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.refreshAirPlayRoute()
            if reason == .oldDeviceUnavailable {
                self.logPlaybackState("audio output disconnected")
                let now = CACurrentMediaTime()
                let wasPlaying = self.player?.rate ?? 0 > 0
                    || (now - self.interruption.lastPlayingAt < 2
                        && self.interruption.lastPlayingAt > self.multitaskPause.lastUserPause)
                // Never automatically play on the speaker for headphones or
                // a user-paused video. Only recover an interrupted AirPlay session.
                self.multitaskPause.lastUserPause = now
                if previouslyAirPlay && wasPlaying && !self.isAtEnd {
                    self.scheduleAirPlayDropRecovery()
                }
            } else if reason == .newDeviceAvailable {
                self.multitaskPause.airPlayRecoveryGeneration += 1
            }
        }
    }

    private func scheduleAirPlayDropRecovery() {
        multitaskPause.airPlayRecoveryGeneration += 1
        let generation = multitaskPause.airPlayRecoveryGeneration
        let playerAtDrop = player
        let pauseAtDrop = multitaskPause.lastUserPause
        AppLog.player("unexpected AirPlay disconnect: awaiting stable local route")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, generation == self.multitaskPause.airPlayRecoveryGeneration,
                  self.player === playerAtDrop, let player = self.player,
                  player.currentItem?.status == .readyToPlay,
                  !self.interruption.state.active,
                  !self.isPiPActive, !self.isAtEnd,
                  !self.isAirPlayActive,
                  self.multitaskPause.lastUserPause == pauseAtDrop,
                  UIApplication.shared.applicationState == .active else {
                self?.logPlaybackState("AirPlay fallback deferred or cancelled")
                return
            }
            // If the receiver did not reconnect, continue at the existing
            // playhead locally rather than leaving the video stranded.
            guard BackgroundPlaybackService.activate() else {
                self.logPlaybackState("AirPlay fallback audio activation failed")
                return
            }
            player.playImmediately(atRate: self.playbackSpeed)
            self.logPlaybackState("AirPlay disconnected; resumed locally")
        }
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
