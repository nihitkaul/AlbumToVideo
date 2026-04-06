import Foundation

enum PickedMediaDownloader {
    /// Downloads picked items to `folder`. Skips non-photos unless `includeVideosAsThumbnails` — then uses image-sized thumbnail for videos.
    static func downloadAll(
        items: [PickedMediaItemDTO],
        into folder: URL,
        accessToken: String,
        maxImageDimension: Int = 4096,
        includeVideosAsThumbnails: Bool = false,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photos = items.filter { item in
            let t = item.type?.uppercased() ?? ""
            if t == "PHOTO" || t.isEmpty { return true }
            if includeVideosAsThumbnails, t == "VIDEO" { return true }
            return false
        }
        var saved: [URL] = []
        let total = photos.count
        for (idx, item) in photos.enumerated() {
            guard let file = item.mediaFile else { continue }
            let suffix: String
            if file.mimeType.lowercased().contains("png") {
                suffix = "png"
            } else if file.mimeType.lowercased().contains("webp") {
                suffix = "webp"
            } else {
                suffix = "jpg"
            }
            let name = sanitizedFilename(item.mediaFile?.filename ?? item.id, fallbackExt: suffix)
            let dest = folder.appendingPathComponent(name)
            let urlString: String
            let isVideo = item.type?.uppercased() == "VIDEO"
            if isVideo {
                urlString = "\(file.baseUrl)=w\(maxImageDimension)-h\(maxImageDimension)-no"
            } else {
                urlString = "\(file.baseUrl)=d"
            }
            guard let url = URL(string: urlString) else { continue }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "AlbumToVideo", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Download failed for \(name): \(text)"
                ])
            }
            try data.write(to: dest, options: .atomic)
            saved.append(dest)
            progress?(idx + 1, total)
        }
        return saved
    }

    private static func sanitizedFilename(_ name: String, fallbackExt: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if trimmed.isEmpty {
            base = "image-\(UUID().uuidString.prefix(8))"
        } else {
            let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            base = trimmed.components(separatedBy: forbidden).joined(separator: "_")
        }
        if (base as NSString).pathExtension.isEmpty {
            return "\(base).\(fallbackExt)"
        }
        return base
    }
}
