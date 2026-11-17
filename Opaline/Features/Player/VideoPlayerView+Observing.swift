import AVFoundation
import UIKit

extension VideoPlayerView {
    // MARK: - Player Observers

    func addPlayerObservers() {
        guard let player else {
            return
        }
        observeRate(on: player)
        observeTimeControl(on: player)
        observeDuration(on: player)
        observeAirPlay(on: player)
    }

    private func observeRate(on player: AVPlayer) {
        rateObservation = player.observe(
            \.rate,
            options: [.new]
        ) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self, self.player === observed else {
                    return
                }
                self.noteSystemPause(rate: observed.rate)
                if observed.rate > 0 { self.isAtEnd = false }
                self.updatePlayPauseIcon()
            }
        }
    }

    private func observeTimeControl(on player: AVPlayer) {
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] observed, _ in
            DispatchQueue.main.async {
                self?.handleTimeControlChange(on: observed)
            }
        }
    }

    private func handleTimeControlChange(on player: AVPlayer) {
        guard self.player === player else {
            return
        }
        clearFinishedInterruption(on: player)
        onPlaybackStateChange?(player)
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            logPlaybackState("waiting for playback")
            scheduleBufferingIndicator()
            if CMTimeGetSeconds(player.currentTime()) > 1 {
                clockResync.isStalled = true
            }
        case .playing:
            logPlaybackState("playback playing")
            hideBufferingIndicator()
            if clockResync.isStalled {
                clockResync.isStalled = false
                scheduleClockResync()
            }
        case .paused:
            logPlaybackState("playback paused")
            hideBufferingIndicator()
            clockResync.isStalled = false
            clockResync.workItem?.cancel()
        @unknown default:
            break
        }
    }
    // MARK: - Stall Clock Resync

    /// A frame-accurate seek to the current position snaps the
    /// player clock back to the rendered media. Only runs while
    /// subtitles are active — nothing else is precise enough to
    /// notice the drift, and the seek costs a brief hiccup.
    private func scheduleClockResync() {
        guard !subtitleCues.isEmpty else {
            return
        }
        clockResync.workItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performClockResync()
        }
        clockResync.workItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.0,
            execute: work
        )
    }

    private func performClockResync() {
        guard let player,
              player.timeControlStatus == .playing else {
            return
        }
        let now = CACurrentMediaTime()
        guard now - clockResync.lastResync > 10 else {
            return
        }
        clockResync.lastResync = now
        let time = player.currentTime()
        AppLog.player(
            "clock resync after stall at "
                + String(
                    format: "%.1fs",
                    CMTimeGetSeconds(time)
                )
        )
        player.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// `.initial`: a local file already knows its duration, so a
    /// change-only observer never fires and the bar stays at 0:00.
    private func observeDuration(on player: AVPlayer) {
        statusObservation = player.currentItem?.observe(
            \.duration, options: [.initial, .new]
        ) { [weak self] item, _ in
            DispatchQueue.main.async {
                let secs = CMTimeGetSeconds(item.duration)
                if secs.isFinite, secs > 0 {
                    self?.duration = secs
                    self?.durationLabel.text = formatTime(
                        secs
                    )
                    self?.refreshSponsorSeekBar()
                }
            }
        }
    }

    func removePlayerObservers() {
        airPlayObservation = nil
        rateObservation = nil
        statusObservation = nil
        timeControlObservation = nil
    }
}
