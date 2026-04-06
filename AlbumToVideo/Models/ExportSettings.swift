import CoreGraphics
import Foundation

struct ExportSettings: Sendable, Equatable {
    var secondsPerSlide: Double
    var frameRate: Int
    var outputWidth: Int
    var outputHeight: Int
    var kenBurnsEnabled: Bool
    var kenBurnsZoomEnd: CGFloat
    var crossfadeSeconds: Double
    var audioVolume: Float

    static let `default` = ExportSettings(
        secondsPerSlide: 4,
        frameRate: 30,
        outputWidth: 1920,
        outputHeight: 1080,
        kenBurnsEnabled: true,
        kenBurnsZoomEnd: 1.08,
        crossfadeSeconds: 0.35,
        audioVolume: 1
    )

    var pixelAspect: CGSize {
        CGSize(width: outputWidth, height: outputHeight)
    }
}
