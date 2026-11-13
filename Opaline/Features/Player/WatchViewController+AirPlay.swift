import AVFoundation
import UIKit

final class AirPlayHandoffState {
    weak var pending: AVPlayerItem?
    weak var attempted: AVPlayerItem?
    var canRetryRejectedQuality = true
}

struct AirPlayHandoff {
    let player: AVPlayer
    let item: AVPlayerItem
    let source: VideoSource
    let token: CancellationToken
    let resumeAt: CMTime?
    let userPauseTime: CFTimeInterval
    let wasPlaying: Bool
    let afterRejection: Bool
}

extension WatchViewController {
    var airPlayPlayer: AVPlayer? {
        guard let player = videoPlayerView?.player,
              BackgroundPlaybackService.isAirPlayActive(player: player) else {
            return nil
        }
        return player
    }

    /// AVPlayer can report the same rejection through KVO and a notification.
    /// Dispatch both here so only the current item can spend the video's single retry.
    func handleAirPlayRejection(_ error: NSError?, item: AVPlayerItem) -> Bool {
        guard error?.domain == AVFoundationErrorDomain,
              error?.code == AVError.Code.externalPlaybackNotSupportedForAsset.rawValue else {
            return false
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, videoPlayerView?.player?.currentItem === item else {
                return
            }
            if !prepareAirPlayPlayback(afterRejection: true) {
                recoverPlayback(skipAirPlayHandoff: true)
            }
        }
        return true
    }

    /// Also called before ordinary error recovery: a receiver rejecting AV1
    /// must not send us through another resolver with the same incompatible pick.
    @discardableResult
    func prepareAirPlayPlayback(afterRejection: Bool = false) -> Bool {
        guard let view = videoPlayerView, view.isAirPlayActive,
              let player = view.player, let item = player.currentItem else {
            return false
        }
        if airPlayHandoffState.pending === item {
            return true
        }
        guard !pageLoadToken.isCancelled, airPlayHandoffState.attempted !== item,
              !afterRejection || airPlayHandoffState.canRetryRejectedQuality,
              let source = playbackFacade.activeVideoSource,
              let quality = source.airPlayQuality(afterRejection: afterRejection) else {
            return false
        }
        let lastPause = view.multitaskPause.lastUserPause
        let intendedToPlay = player.rate > 0 || view.interruption.lastPlayingAt > lastPause
            || (afterRejection && lastPause == 0)
        let handoff = AirPlayHandoff(
            player: player,
            item: item,
            source: source,
            token: pageLoadToken,
            resumeAt: rebuildPlayhead,
            userPauseTime: lastPause,
            wasPlaying: !view.isAtEnd && intendedToPlay,
            afterRejection: afterRejection
        )
        beginAirPlayHandoff(handoff, quality: quality)
        return true
    }

    private func beginAirPlayHandoff(_ handoff: AirPlayHandoff, quality: VideoQuality) {
        airPlayHandoffState.pending = handoff.item
        airPlayHandoffState.attempted = handoff.item
        if handoff.afterRejection {
            airPlayHandoffState.canRetryRejectedQuality = false
            let rejected = handoff.source.currentQuality?.label ?? "?"
            AppLog.player("AirPlay: receiver rejected \(rejected), retrying \(quality.label)")
        } else {
            AppLog.player("AirPlay: preparing \(quality.label) on \(handoff.source.name)")
        }
        handoff.source.selectQuality(
            quality, resumeAt: handoff.resumeAt.map(CMTimeGetSeconds)
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.finishAirPlayHandoff(handoff, result: result)
            }
        }
    }

    private func finishAirPlayHandoff(
        _ handoff: AirPlayHandoff, result: Result<PreparedPlayback, Error>
    ) {
        guard airPlayHandoffState.pending === handoff.item else {
            return
        }
        airPlayHandoffState.pending = nil
        guard pageLoadToken === handoff.token, !handoff.token.isCancelled,
              videoPlayerView?.player === handoff.player,
              handoff.player.currentItem === handoff.item,
              playbackFacade.activeVideoSource === handoff.source else {
            return
        }
        switch result {
        case .success(let prepared):
            attachAirPlayPlayback(prepared, handoff: handoff)
        case .failure(let error):
            AppLog.player("AirPlay: compatible stream failed: \(error.localizedDescription)")
            if handoff.afterRejection {
                recoverPlayback(skipAirPlayHandoff: true)
            } else if handoff.item.status == .failed {
                recoverPlayback(skipAirPlayHandoff: true)
            }
        }
    }

    private func attachAirPlayPlayback(_ prepared: PreparedPlayback, handoff: AirPlayHandoff) {
        let resumeAt = rebuildPlayhead ?? handoff.resumeAt
        // Keep the AVPlayer that owns the receiver connection, even if the
        // route briefly stops reporting active while the old item is rejected.
        savedPlayerForBackground = handoff.player
        attachPrepared(prepared, resumeAt: resumeAt)
        if !handoff.wasPlaying
            || (videoPlayerView?.multitaskPause.lastUserPause ?? 0) > handoff.userPauseTime {
            handoff.player.pause()
        }
        AppLog.player("AirPlay: compatible item attached to the existing player")
    }
}
