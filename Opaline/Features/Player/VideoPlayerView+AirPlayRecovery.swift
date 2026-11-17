import AVFoundation
import UIKit

extension VideoPlayerView {
    func resetInterruptionTracking() {
        interruption.clear()
        interruption.lastPlayingAt = 0
        multitaskPause.systemPaused = false
        multitaskPause.airPlayRecoveryGeneration += 1
    }

    func clearFinishedInterruption(on player: AVPlayer) {
        guard player.timeControlStatus == .playing,
              interruption.state.active, interruption.matches(player) else {
            return
        }
        // A reconnect or explicit Play can succeed without an interruption-ended
        // notification. Retaining active=true would disable later stall recovery.
        interruption.clear()
        interruption.lastPlayingAt = CACurrentMediaTime()
        AppLog.player("audio interruption cleared after playback resumed")
    }

    // AirPlay can disappear without an ending interruption. This only restores
    // the interrupted item in the foreground; it never selects a receiver.
    func recoverBackgroundAirPlayIfNeeded(player: AVPlayer) {
        guard canRecoverBackgroundAirPlay(player),
              !interruption.foregroundRecoveryScheduled,
              let item = player.currentItem else {
            return
        }
        interruption.foregroundRecoveryScheduled = true
        let generation = interruption.generation
        AppLog.player("AirPlay session lost in background; checking foreground fallback")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.0
        ) { [weak self, weak player, weak item] in
            guard let self, let player, let item else {
                return
            }
            finishAirPlayRecovery(player: player, item: item, generation: generation)
        }
    }

    private func canRecoverBackgroundAirPlay(_ player: AVPlayer) -> Bool {
        self.player === player && interruption.matches(player)
            && interruption.interruptedAirPlayInBackground
            && interruption.state.canResume(lastUserPause: multitaskPause.lastUserPause)
            && UIApplication.shared.applicationState == .active
            && player.rate == 0 && player.currentItem?.status == .readyToPlay
            && !isAirPlayActive && !isPiPActive && !isAtEnd
    }

    private func finishAirPlayRecovery(
        player: AVPlayer, item: AVPlayerItem, generation: Int
    ) {
        guard generation == interruption.generation else {
            return
        }
        interruption.foregroundRecoveryScheduled = false
        guard player.currentItem === item, canRecoverBackgroundAirPlay(player) else {
            return
        }
        guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else {
            logPlaybackState("AirPlay foreground fallback deferred for other audio")
            return
        }
        guard BackgroundPlaybackService.activate() else {
            logPlaybackState("AirPlay foreground fallback activation failed")
            return
        }
        interruption.clear()
        player.playImmediately(atRate: playbackSpeed)
        logPlaybackState("AirPlay foreground fallback requested local resume")
    }
}
