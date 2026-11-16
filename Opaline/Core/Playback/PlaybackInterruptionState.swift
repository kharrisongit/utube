import Foundation

struct PlaybackInterruptionState {
    private(set) var active = false
    private var wasPlaying = false
    private var pauseAtStart: TimeInterval = 0

    mutating func begin(wasPlaying: Bool, lastUserPause: TimeInterval) {
        guard !active else {
            return
        }
        active = true
        self.wasPlaying = wasPlaying
        pauseAtStart = lastUserPause
    }

    mutating func end(shouldResume: Bool, lastUserPause: TimeInterval) -> Bool {
        let resume = shouldResume && canResume(lastUserPause: lastUserPause)
        self = PlaybackInterruptionState()
        return resume
    }

    func canResume(lastUserPause: TimeInterval) -> Bool {
        active && wasPlaying && lastUserPause == pauseAtStart
    }
}
