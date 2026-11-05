import Foundation

enum PlaybackStallPolicy {
    static let waitSeconds: TimeInterval = 15

    static func isStuck(from start: Double, to end: Double) -> Bool {
        start.isFinite && end.isFinite && abs(end - start) < 0.5
    }

    static func canRestart(at position: Double, duration: Double) -> Bool {
        position.isFinite && position >= 1 && duration.isFinite && duration - position >= 1
    }
}
