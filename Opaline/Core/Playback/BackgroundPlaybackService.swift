import AVFoundation

enum BackgroundPlaybackService {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.Player.backgroundPlayback) }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: UserDefaultsKeys.Player.backgroundPlayback
            )
        }
    }

    static func isAirPlayActive(player: AVPlayer?) -> Bool {
        let airPlayRoute = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .airPlay
        }
        return player?.isExternalPlaybackActive == true || airPlayRoute
    }

    /// Call on app launch and whenever the setting changes.
    static func apply() {
        // Default to enabled — user can disable in Settings.
        UserDefaults.standard.register(defaults: [
            UserDefaultsKeys.Player.backgroundPlayback: true
        ])
        let session = AVAudioSession.sharedInstance()
        do {
            // Always use .playback so Now Playing / remote controls work.
            // Background pause (when isEnabled=false) is handled in appDidEnterBackground.
            if #available(iOS 13.0, *) {
                try session.setCategory(
                    .playback, mode: .moviePlayback, policy: .longFormVideo, options: []
                )
            } else {
                try session.setCategory(.playback, mode: .moviePlayback)
            }
            try session.setActive(true)
        } catch {
            AppLog.player("AVAudioSession error: \(error)")
        }
    }

    @discardableResult
    static func activate() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            let failure = error as NSError
            AppLog.player("audio session activation failed: domain=\(failure.domain)"
                + " code=\(failure.code) message=\(failure.localizedDescription)")
            return false
        }
    }
}
