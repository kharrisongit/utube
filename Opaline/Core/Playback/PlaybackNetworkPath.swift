import Network

final class PlaybackNetworkPath {
    private let monitor = NWPathMonitor()
    private var path: NWPath?

    /// Read on main, where the monitor delivers its first path and subsequent changes.
    var summary: String {
        guard let path else {
            return "network=unknown interface=unknown"
        }
        let types: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"),
            (.cellular, "cellular"),
            (.wiredEthernet, "wired"),
            (.loopback, "loopback"),
            (.other, "other")
        ]
        let used = types.filter { path.usesInterfaceType($0.0) }.map { $0.1 }
        return "network=\(statusLabel(path.status))"
            + " interface=\(used.isEmpty ? "none" : used.joined(separator: ","))"
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.path = path
        }
        monitor.start(queue: .main)
    }

    private func statusLabel(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied:
            return "satisfied"
        case .unsatisfied:
            return "unsatisfied"
        case .requiresConnection:
            return "requiresConnection"
        @unknown default:
            return "unknown"
        }
    }

    deinit {
        monitor.cancel()
    }
}
