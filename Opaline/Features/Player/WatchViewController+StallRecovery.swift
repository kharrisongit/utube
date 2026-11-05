import AVFoundation
import UIKit

final class PlaybackStallWatch {
    let network = PlaybackNetworkPath()
    weak var item: AVPlayerItem?
    var work: DispatchWorkItem?
    var didRetry = false
    weak var replacement: AVPlayerItem?
    var resumePosition = 0.0

    func cancel() {
        work?.cancel()
        work = nil
        item = nil
    }
}

extension WatchViewController {
    func updateStallWatch(on player: AVPlayer) {
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              let item = player.currentItem else {
            stallWatch.cancel()
            return
        }
        // Repeated waiting notifications must not postpone the deadline.
        guard stallWatch.item !== item else {
            return
        }
        stallWatch.cancel()
        stallWatch.item = item
        let start = item.currentTime().seconds
        let token = pageLoadToken
        let work = DispatchWorkItem { [weak self, weak player, weak item] in
            guard let self, let player, let item, stallWatch.item === item,
                  pageLoadToken === token, !token.isCancelled,
                  videoPlayerView?.player === player, player.currentItem === item,
                  player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
                return
            }
            checkStalledPlayback(player, item: item, from: start)
        }
        stallWatch.work = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + PlaybackStallPolicy.waitSeconds,
            execute: work
        )
    }

    private func checkStalledPlayback(_ player: AVPlayer, item: AVPlayerItem, from start: Double) {
        let position = item.currentTime()
        if position.isNumeric, !PlaybackStallPolicy.isStuck(from: start, to: position.seconds) {
            // A seek or intermittent progress starts a fresh observation window.
            stallWatch.cancel()
            updateStallWatch(on: player)
            return
        }
        let seconds = Int(PlaybackStallPolicy.waitSeconds)
        logPlaybackStall("still waiting after \(seconds)s", item: item)
        guard !stallWatch.didRetry, canRestartStalledItem(item),
              PlaybackStallPolicy.canRestart(at: position.seconds, duration: item.duration.seconds)
        else {
            return
        }
        stallWatch.didRetry = true
        // Keep the selected tracks, resource loader and the player that owns PiP or AirPlay.
        // Replacing only the item opens new media requests against the same rendition.
        pendingResumeSeek = position
        AppLog.player("stall retry: reopening current stream at \(position.seconds)s")
        let replacement = AVPlayerItem(asset: item.asset)
        stallWatch.replacement = replacement
        stallWatch.resumePosition = position.seconds
        attachToExistingPlayer(player: player, item: replacement)
    }

    func noteStallRecoveryProgress(at time: Double) {
        guard let item = stallWatch.replacement, time > stallWatch.resumePosition + 1,
              let player = videoPlayerView?.player, player.currentItem === item,
              player.timeControlStatus == .playing else {
            return
        }
        stallWatch.replacement = nil
        logPlaybackStall("playing after stall retry", item: item)
    }

    private func canRestartStalledItem(_ item: AVPlayerItem) -> Bool {
        guard let playerView = videoPlayerView, !playerView.isAtEnd,
              !playerView.interruption.state.active, !playerView.seekBar.isScrubbing,
              !playerView.holdScrub.isActive, !isRecoveringPlayback, !pendingRecoverySeek,
              pendingResumeSeek == nil, airPlayHandoffState.pending == nil,
              item.status == .readyToPlay, let asset = item.asset as? AVURLAsset,
              asset.url.scheme == HLSGenerator.scheme else {
            return false
        }
        return UIApplication.shared.applicationState != .background
            || BackgroundPlaybackPolicy.shouldContinue(
                backgroundEnabled: BackgroundPlaybackService.isEnabled,
                airPlayActive: playerView.isAirPlayActive,
                pipActive: playerView.isPiPActive
            )
    }
}
