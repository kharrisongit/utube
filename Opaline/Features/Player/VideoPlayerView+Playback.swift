import AVFoundation
import AVKit
import UIKit
/// State for the stall-recovery clock resync (issue #14).
final class ClockResyncState {
    var isStalled = false
    var workItem: DispatchWorkItem?
    var lastResync: CFTimeInterval = 0
}

// MARK: - Playback API

extension VideoPlayerView {
    func attach(player newPlayer: AVPlayer) {
        hideBufferingIndicator()
        resetInterruptionTracking()
        BackgroundPlaybackService.activate()
        player = newPlayer
        playerLayer.isHidden = false
        playerLayer.player = newPlayer
        addPeriodicObserver()
        addPlayerObservers()
        updatePlayPauseIcon()
        setupPiP()
        if playbackSpeed != 1.0 {
            newPlayer.rate = playbackSpeed
        }
    }

    /// Rebinds observers after the host replaced the item on the SAME
    /// player (background video-to-video transition): the duration KVO
    /// watches `currentItem`, so it must re-attach to the new one. The
    /// layer is deliberately untouched — it stays detached while
    /// backgrounded and comes back on activation.
    func rebind(player newPlayer: AVPlayer) {
        hideBufferingIndicator()
        resetInterruptionTracking()
        player = newPlayer
        removePlayerObservers()
        addPlayerObservers()
        duration = 0
    }

    func detach() {
        hideBufferingIndicator()
        resetInterruptionTracking()
        removePeriodicObserver()
        removePlayerObservers()
        clockResync.isStalled = false
        clockResync.workItem?.cancel()
        clockResync.workItem = nil
        playerLayer.isHidden = false
        playerLayer.player = nil
        player = nil
        hideSkipButton()
        sponsorSegments = []
        seekBar.setSegments([])
        seekBar.cancelScrubbing()
        speedOverlay.isHidden = true
        hudWorkItem?.cancel()
        hudLabel.alpha = 0
        seekBurst.direction = 0
        seekBurst.tapCount = 0
        seekBurst.accumulated = 0
        seekBurst.target = .invalid
    }

    func setSponsorSegments(
        _ segments: [SponsorBlockSegment]
    ) {
        sponsorSegments = segments
        refreshSponsorSeekBar()
    }

    func showSkipButton(categoryName: String) {
        skipButton.setTitle(
            "sponsorblock.skip".localized(with: categoryName),
            for: .normal
        )
        skipButton.isHidden = false
    }

    func hideSkipButton() {
        skipButton.isHidden = true
    }

    func refreshSponsorSeekBar() {
        guard duration > 0 else {
            return
        }
        let normalized = sponsorSegments
            .filter {
                SponsorBlockService.skipBehavior(
                    for: $0.category
                ) != .disabled
            }
            .map {
                SeekBarSegment(
                    start: $0.startTime / duration,
                    end: $0.endTime / duration,
                    color: $0.category.seekBarColor
                )
            }
        seekBar.setSegments(normalized)
    }
    // MARK: - Periodic Observer

    func addPeriodicObserver() {
        guard let player else {
            return
        }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            self?.updateProgress(time: time)
        }
    }

    func removePeriodicObserver() {
        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
    }
    // MARK: - Progress

    func updateProgress(time: CMTime) {
        if (player?.rate ?? 0) > 0 {
            interruption.lastPlayingAt = CACurrentMediaTime()
        }
        guard duration > 0 else {
            return
        }
        let secs = CMTimeGetSeconds(time)
        // Hidden controls need no redraw; seeking owns the thumb during scrubbing.
        if controlsVisible, !seekBar.isScrubbing {
            // This string changes once a second; assigning it every tick
            // invalidates the label's intrinsic size and relays out the
            // whole bottom bar.
            let stamp = formatTime(secs)
            if currentTimeLabel.text != stamp {
                currentTimeLabel.text = stamp
            }
            seekBar.setProgress(secs / duration)
            updateBuffer(at: time)
        }
        onTimeUpdate?(secs)
    }

    private func updateBuffer(at time: CMTime) {
        guard let item = player?.currentItem else {
            return
        }
        let buffered = item.loadedTimeRanges
            .compactMap { $0 as? CMTimeRange }
            .filter {
                CMTimeRangeContainsTime($0, time: time)
            }
            .map {
                CMTimeGetSeconds($0.start)
                    + CMTimeGetSeconds($0.duration)
            }
            .max() ?? 0
        seekBar.setBuffer(buffered / duration)
    }
}
