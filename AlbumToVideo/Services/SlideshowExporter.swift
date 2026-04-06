import AppKit
import AVFoundation
import CoreVideo
import Foundation

enum SlideshowExportError: LocalizedError {
    case noImages
    case writerFailed(String)
    case exportFailed(String?)

    var errorDescription: String? {
        switch self {
        case .noImages:
            return "Add at least one image to export a video."
        case let .writerFailed(msg):
            return "Video encoding failed: \(msg)"
        case let .exportFailed(msg):
            return "Could not finish export: \(msg ?? "unknown error")"
        }
    }
}

enum SlideshowExporter {
    /// Renders a slideshow to `outputURL` (`.mp4`). Muxes `audioURL` when provided (trimmed to video length).
    static func export(
        imageURLs: [URL],
        audioURL: URL?,
        settings: ExportSettings,
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard !imageURLs.isEmpty else { throw SlideshowExportError.noImages }

        let fm = FileManager.default
        let tempVideo = fm.temporaryDirectory.appendingPathComponent("AlbumToVideo-video-\(UUID().uuidString).mov")
        if fm.fileExists(atPath: tempVideo.path) {
            try fm.removeItem(at: tempVideo)
        }
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        try await renderVideoOnly(
            imageURLs: imageURLs,
            settings: settings,
            outputURL: tempVideo,
            progress: progress
        )

        if let audioURL {
            try await muxVideoWithAudio(videoURL: tempVideo, audioURL: audioURL, outputURL: outputURL, volume: settings.audioVolume)
        } else {
            try fm.copyItem(at: tempVideo, to: outputURL)
        }

        try? fm.removeItem(at: tempVideo)
    }

    private static func renderVideoOnly(
        imageURLs: [URL],
        settings: ExportSettings,
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let w = settings.outputWidth
        let h = settings.outputHeight
        let fps = max(1, settings.frameRate)
        let slideDuration = max(0.25, settings.secondsPerSlide)
        let crossfade = max(0, min(settings.crossfadeSeconds, slideDuration * 0.45))

        let images = try imageURLs.map { url -> NSImage in
            guard let img = NSImage(contentsOf: url) else {
                throw NSError(domain: "AlbumToVideo", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "Could not open image: \(url.lastPathComponent)"
                ])
            }
            return img
        }

        let slideFrames = Int((slideDuration * Double(fps)).rounded())
        let totalFrames = max(1, slideFrames * images.count)
        let perSlideSeconds = slideDuration

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: w * h * 4,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)

        guard writer.canAdd(input) else {
            throw SlideshowExportError.writerFailed("Cannot add video input.")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw SlideshowExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(at: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let size = CGSize(width: w, height: h)

        for frameIndex in 0 ..< totalFrames {
            let t = Double(frameIndex) / Double(fps)
            let slideIndex = min(images.count - 1, Int(t / perSlideSeconds))
            let tInSlide = t - Double(slideIndex) * perSlideSeconds
            let nextIndex = min(slideIndex + 1, images.count - 1)

            let blend: CGFloat
            if crossfade > 0.01, slideIndex < images.count - 1, tInSlide >= perSlideSeconds - crossfade {
                let u = (tInSlide - (perSlideSeconds - crossfade)) / crossfade
                blend = CGFloat(min(1, max(0, u)))
            } else {
                blend = 0
            }

            let slideProgress = CGFloat(min(1, max(0, tInSlide / perSlideSeconds)))
            let scaleStart: CGFloat = 1
            let scaleEnd = settings.kenBurnsEnabled ? settings.kenBurnsZoomEnd : 1
            let kenScale: CGFloat = settings.kenBurnsEnabled
                ? scaleStart + (scaleEnd - scaleStart) * slideProgress
                : 1

            guard let buffer = makePixelBuffer(width: w, height: h) else {
                throw SlideshowExportError.writerFailed("Pixel buffer allocation failed.")
            }

            if blend <= 0.001 {
                draw(
                    image: images[slideIndex],
                    into: buffer,
                    targetSize: size,
                    kenBurnsScale: kenScale
                )
            } else {
                composite(
                    from: images[slideIndex],
                    to: images[nextIndex],
                    blend: blend,
                    into: buffer,
                    targetSize: size,
                    primaryScale: kenScale,
                    settings: settings
                )
            }

            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_500_000)
            }
            if !adaptor.append(buffer, withPresentationTime: pts) {
                throw SlideshowExportError.writerFailed(writer.error?.localizedDescription ?? "append failed")
            }

            progress?(Double(frameIndex + 1) / Double(totalFrames))
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw SlideshowExportError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
        }
    }

    private static func composite(
        from primary: NSImage,
        to secondary: NSImage,
        blend: CGFloat,
        into buffer: CVPixelBuffer,
        targetSize: CGSize,
        primaryScale: CGFloat,
        settings: ExportSettings
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        ctx.interpolationQuality = .high
        ctx.clear(CGRect(origin: .zero, size: targetSize))
        ctx.setAlpha(1)
        draw(image: primary, in: ctx, size: targetSize, kenBurnsScale: primaryScale)
        let secScale: CGFloat = settings.kenBurnsEnabled
            ? 1 + (settings.kenBurnsZoomEnd - 1) * blend * 0.35
            : 1
        ctx.setAlpha(blend)
        draw(image: secondary, in: ctx, size: targetSize, kenBurnsScale: secScale)
    }

    private static func draw(image: NSImage, into buffer: CVPixelBuffer, targetSize: CGSize, kenBurnsScale: CGFloat) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(image: image, in: ctx, size: targetSize, kenBurnsScale: kenBurnsScale)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func draw(image: NSImage, in ctx: CGContext, size: CGSize, kenBurnsScale: CGFloat) {
        ctx.clear(CGRect(origin: .zero, size: size))
        let proposed = CGRect(origin: .zero, size: size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }
        let iw = CGFloat(cg.width)
        let ih = CGFloat(cg.height)
        let scale = max(size.width / iw, size.height / ih) * kenBurnsScale
        let rw = iw * scale
        let rh = ih * scale
        let rect = CGRect(x: (size.width - rw) / 2, y: (size.height - rh) / 2, width: rw, height: rh)
        ctx.draw(cg, in: rect)
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    private static func muxVideoWithAudio(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        volume: Float
    ) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()

        let vDur = try await videoAsset.load(.duration)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let vTrack = videoTracks.first else {
            throw SlideshowExportError.exportFailed("No video track.")
        }
        guard let compV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SlideshowExportError.exportFailed("Could not add video track.")
        }
        try compV.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vTrack, at: .zero)

        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        if let aTrack = audioTracks.first {
            let aDur = try await audioAsset.load(.duration)
            let useDur = CMTimeMinimum(vDur, aDur)
            if useDur.seconds > 0,
               let compA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            {
                try compA.insertTimeRange(CMTimeRange(start: .zero, duration: useDur), of: aTrack, at: .zero)
                if abs(volume - 1) > 0.001 {
                    let mix = AVMutableAudioMix()
                    mix.inputParameters = [volumeMix(track: compA, volume: volume, duration: useDur)]
                    try await exportComposition(composition, audioMix: mix, outputURL: outputURL)
                    return
                }
            }
        }

        try await exportComposition(composition, audioMix: nil, outputURL: outputURL)
    }

    private static func volumeMix(track: AVAssetTrack, volume: Float, duration: CMTime) -> AVMutableAudioMixInputParameters {
        let p = AVMutableAudioMixInputParameters(track: track)
        p.setVolume(volume, at: .zero)
        p.setVolume(volume, at: duration)
        return p
    }

    private static func exportComposition(
        _ composition: AVComposition,
        audioMix: AVAudioMix?,
        outputURL: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw SlideshowExportError.exportFailed("No export session.")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.audioMix = audioMix
        await session.export()
        if session.status != .completed {
            throw SlideshowExportError.exportFailed(session.error?.localizedDescription)
        }
    }
}
