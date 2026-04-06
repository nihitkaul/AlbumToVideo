import Foundation

enum LocalFolderImageScanner {
    private static let extensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif"]

    static func sortedImageURLs(in folder: URL) throws -> [URL] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let filtered = urls.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false else { return false }
            return extensions.contains(url.pathExtension.lowercased())
        }
        return filtered.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if da != db { return da < db }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }
}
