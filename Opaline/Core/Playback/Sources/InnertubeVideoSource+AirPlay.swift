import Foundation

extension InnertubeVideoSource {
    var availableQualities: [VideoQuality] {
        guard BackgroundPlaybackService.isAirPlayActive(player: nil), let info,
              !info.allDashVideoFormats.isEmpty else {
            return resolvedQualities
        }
        return Self.qualities(from: info, forAirPlay: true)
    }

    static func quality(for format: DashFormatInfo) -> VideoQuality {
        let height = format.height ?? 0
        let fps = format.fps ?? 0
        return VideoQuality(
            id: String(format.itag),
            label: format.qualityLabel ?? (fps > 30 ? "\(height)p\(fps)" : "\(height)p"),
            height: format.height,
            fps: format.fps
        )
    }

    func airPlayQuality(afterRejection: Bool) -> VideoQuality? {
        guard currentQuality?.id != AudioOnlyMode.qualityID,
              let info,
              let current = info.allDashVideoFormats.first(where: {
                  String($0.itag) == currentQuality?.id
              }),
              let compatible = AirPlayVideoPolicy.replacement(
                  for: current,
                  in: info.allDashVideoFormats,
                  afterRejection: afterRejection
              ), compatible.itag != current.itag else {
            return nil
        }
        return Self.quality(for: compatible)
    }

    func airPlayFormat(_ requested: DashFormatInfo, info: DirectPlaybackInfo) -> DashFormatInfo {
        guard BackgroundPlaybackService.isAirPlayActive(player: nil),
              let compatible = AirPlayVideoPolicy.replacement(
                  for: requested,
                  in: info.allDashVideoFormats
              ) else {
            return requested
        }
        if compatible.itag != requested.itag {
            AppLog.player(
                "AirPlay: \(requested.codecs) itag \(requested.itag) ->"
                    + " \(compatible.codecs) itag \(compatible.itag) on \(name)"
            )
        }
        return compatible
    }
}
