import AVFoundation

final class SponsorBlockController {
    var segments: [SponsorBlockSegment] = []
    private var activeSegmentUUID: String?
    /// A seek may report stale positions while AirPlay settles. Never auto-seek
    /// the same segment twice during a single video, even after time jumps.
    private var attemptedSkipUUIDs = Set<String>()
    private var pendingSkipUUID: String?
    private var generation = 0
    private weak var playerView: VideoPlayerView?

    func attach(to playerView: VideoPlayerView) {
        self.playerView = playerView
    }

    func reset() {
        generation += 1
        segments = []
        activeSegmentUUID = nil
        attemptedSkipUUIDs.removeAll()
        pendingSkipUUID = nil
        playerView?.hideSkipButton()
    }

    func checkTime(_ time: Double) {
        guard SponsorBlockService.enabled, !segments.isEmpty,
              playerView?.player?.currentItem?.status == .readyToPlay
        else { return }

        guard time.isFinite else {
            return
        }
        let active = findActiveSegment(at: time)

        if let seg = active {
            if seg.uuid == activeSegmentUUID {
                return
            }
            activeSegmentUUID = seg.uuid
            handleSegment(seg)
        } else {
            if activeSegmentUUID != nil {
                activeSegmentUUID = nil
                playerView?.hideSkipButton()
            }
        }
    }

    private func findActiveSegment(at time: Double) -> SponsorBlockSegment? {
        segments.first { seg in
            guard seg.actionType == "skip" || seg.actionType == "poi"
            else { return false }
            let behavior = SponsorBlockService.skipBehavior(for: seg.category)
            guard behavior != .disabled
            else { return false }
            return time >= seg.startTime && time < seg.endTime
        }
    }

    private func handleSegment(_ seg: SponsorBlockSegment) {
        let behavior = SponsorBlockService.skipBehavior(for: seg.category)
        switch behavior {
        case .autoSkip:
            requestSkip(seg, initiatedByUser: false)
        case .showButton:
            playerView?.showSkipButton(
                categoryName: seg.category.displayName
            )
        case .disabled:
            break
        }
    }

    func skipCurrentSegment() {
        guard let uuid = activeSegmentUUID,
              let seg = segments.first(where: { $0.uuid == uuid })
        else { return }
        requestSkip(seg, initiatedByUser: true)
    }

    private func requestSkip(
        _ seg: SponsorBlockSegment,
        initiatedByUser: Bool
    ) {
        guard let player = playerView?.player,
              pendingSkipUUID == nil,
              !attemptedSkipUUIDs.contains(seg.uuid)
        else { return }

        // Mark before seeking to prevent duplicate AirPlay skips.
        attemptedSkipUUIDs.insert(seg.uuid)
        pendingSkipUUID = seg.uuid
        playerView?.hideSkipButton()
        let requestGeneration = generation
        let origin = initiatedByUser ? "user" : "auto"
        logSkipRequest(seg, player: player, origin: origin)
        let target = CMTime(seconds: seg.endTime, preferredTimescale: 600)
        player.seek(
            to: target, toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self, weak player] finished in
            DispatchQueue.main.async {
                guard let self, let player,
                      self.generation == requestGeneration
                else { return }
                self.finishSkip(
                    seg, player: player, origin: origin, finished: finished
                )
            }
        }
    }

    private func logSkipRequest(
        _ seg: SponsorBlockSegment, player: AVPlayer, origin: String
    ) {
        let position = CMTimeGetSeconds(player.currentTime())
        AppLog.sponsorBlock(
            "\(origin) skip requested \(seg.category.displayName) "
                + "[\(seg.startTime)–\(seg.endTime)] "
                + "from=\(position)s target=\(seg.endTime)s"
        )
    }

    private func finishSkip(
        _ seg: SponsorBlockSegment,
        player: AVPlayer,
        origin: String,
        finished: Bool
    ) {
        guard playerView?.player === player
        else { return }
        if pendingSkipUUID == seg.uuid {
            pendingSkipUUID = nil
        }
        let actual = CMTimeGetSeconds(player.currentTime())
        AppLog.sponsorBlock(
            "\(origin) skip completed \(seg.category.displayName) "
                + "finished=\(finished) position=\(actual)s "
                + "target=\(seg.endTime)s"
        )
        // An incomplete remote seek must not retry indefinitely.
    }
}
