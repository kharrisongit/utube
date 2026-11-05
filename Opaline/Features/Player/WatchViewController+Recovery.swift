import AVFoundation
import UIKit

// MARK: - Stream URL Expiration Recovery

extension WatchViewController {
    func resetPlaybackRecovery() {
        stallWatch.cancel()
        stallWatch.didRetry = false
        stallWatch.replacement = nil
        airPlayHandoffState = AirPlayHandoffState()
        isRecoveringPlayback = false
        pendingRecoverySeek = false
        pendingResumeSeek = nil
        lastPlaybackPosition = 0
        hasSeenPlaybackError = false
        didSeekToSavedPosition = false
        preparedDuration = nil
        itemStartsAt = nil
    }

    func recoverPlayback(tokenRejected: Bool = false) {
        if prepareAirPlayPlayback() {
            return
        }
        guard !isRecoveringPlayback,
              videoPlayerView?.player != nil
        else {
            return
        }
        AppLog.player(
            "recoverPlayback: resumeAt=\(lastPlaybackPosition)s"
        )
        let token = CancellationToken()
        pageLoadToken.cancel()
        pageLoadToken = token
        isRecoveringPlayback = true
        hasSeenPlaybackError = false
        pendingRecoverySeek = true
        guard playbackFacade.recover(cancellationToken: token, tokenRejected: tokenRejected) else {
            isRecoveringPlayback = false
            pendingRecoverySeek = false
            showPlaybackError("player.error.playback".localized)
            return
        }
    }

    func applyRecoverySeekIfNeeded(
        _ item: AVPlayerItem
    ) -> Bool {
        guard pendingRecoverySeek else {
            return false
        }
        isRecoveringPlayback = false
        let target = lastPlaybackPosition
        // A rebuilt stream that already opens at the playhead is where it
        // needs to be. Seeking there anyway leaves the player working the head
        // of the stream as well, which on SABR restarts it on every swap.
        if let startsAt = itemStartsAt, abs(startsAt - target) <= 1 {
            AppLog.player("recoverPlayback: ready at \(target)s, stream opened there")
            pendingRecoverySeek = false
            videoPlayerView?.player?.play()
            return true
        }
        AppLog.player(
            "recoverPlayback: ready"
                + " duration=\(CMTimeGetSeconds(item.duration))s"
                + " seekTo=\(target)s"
        )
        seekAfterRecovery(item, target: target)
        return true
    }

    private func seekAfterRecovery(_ item: AVPlayerItem, target: Double) {
        guard let player = videoPlayerView?.player, player.currentItem === item else {
            return
        }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 1_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] finished in
            DispatchQueue.main.async {
                guard let self, let player, player.currentItem === item,
                      self.videoPlayerView?.player === player else {
                    return
                }
                if finished {
                    self.pendingRecoverySeek = false
                }
                player.play()
            }
        }
    }
}
