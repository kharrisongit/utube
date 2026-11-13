import AVFoundation
import UIKit

// MARK: - Buffering indicator

extension VideoPlayerView {
    /// AVPlayer passes through `waitingToPlayAtSpecifiedRate` on nearly every
    /// `play()`, buffered or not — showing the spinner (and hiding the
    /// transport buttons) right then makes a resume flicker like a stall.
    /// Only a wait that outlives the grace period is a real one.
    func scheduleBufferingIndicator() {
        bufferingIndicatorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
                return
            }
            self.updateBufferingLabel()
            self.spinner.startAnimating()
            self.setCenter(hidden: true)
        }
        bufferingIndicatorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func setupBufferingLabel() {
        bufferingLabel.translatesAutoresizingMaskIntoConstraints = false
        bufferingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        bufferingLabel.textColor = .white
        bufferingLabel.textAlignment = .center
        bufferingLabel.numberOfLines = 2
        bufferingLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        bufferingLabel.layer.cornerRadius = 6
        bufferingLabel.clipsToBounds = true
        bufferingLabel.isHidden = true
        bufferingLabel.isUserInteractionEnabled = false
        addSubview(bufferingLabel)
        NSLayoutConstraint.activate([
            bufferingLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
            bufferingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bufferingLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        ])
    }

    private func updateBufferingLabel() {
        guard let player, player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            hideBufferingIndicator()
            return
        }
        let message: String
        switch player.reasonForWaitingToPlay {
        case .evaluatingBufferingRate:
            message = "Measuring download speed…"
        case .toMinimizeStalls:
            message = "Buffering video…"
        case .noItemToPlay:
            message = "Loading the stream…"
        default:
            message = "Waiting for playback to resume…"
        }
        bufferingLabel.text = "  \(message)  "
        bufferingLabel.isHidden = false
        let work = DispatchWorkItem { [weak self] in
            self?.updateBufferingLabel()
        }
        bufferingIndicatorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func hideBufferingIndicator() {
        bufferingIndicatorWork?.cancel()
        bufferingIndicatorWork = nil
        bufferingLabel.isHidden = true
        bufferingLabel.text = nil
        spinner.stopAnimating()
        setCenter(hidden: false)
    }
}
