import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    enum Phase: String {
        case signedOut
        case signedIn
        case pickerOpen
        case waitingForPicks
        case downloading
        case imagesReady
        case exporting
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var statusMessage = ""
    @Published var errorMessage: String?
    @Published var oauthConfigError: String?
    @Published var exportSettings = ExportSettings.default
    @Published var audioURL: URL?
    @Published private(set) var imageURLs: [URL] = []
    @Published private(set) var downloadProgress: (done: Int, total: Int)?
    @Published private(set) var exportProgress: Double?
    @Published private(set) var tokens: KeychainTokenStore.StoredTokens?

    private var oauthConfig: GoogleOAuthConfig?
    private var activeSessionId: String?
    private var pollTask: Task<Void, Never>?

    init() {
        do {
            oauthConfig = try GoogleOAuthConfig.loadFromBundle()
            oauthConfigError = nil
        } catch {
            oauthConfig = nil
            oauthConfigError = error.localizedDescription
        }
        if let stored = try? KeychainTokenStore.load() {
            tokens = stored
            phase = .signedIn
            statusMessage = "Signed in. Start a picker session or import a folder."
        }
    }

    func signIn() {
        guard let config = oauthConfig else {
            errorMessage = oauthConfigError ?? "Configure Google OAuth first."
            return
        }
        errorMessage = nil
        statusMessage = "Opening Google sign-in…"
        Task { @MainActor in
            do {
                let oauth = GoogleOAuthService(config: config)
                let window = NSApplication.shared.keyWindow
                let newTokens = try await oauth.signIn(presentingWindow: window)
                try KeychainTokenStore.save(newTokens)
                tokens = newTokens
                phase = .signedIn
                statusMessage = "Signed in successfully."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
        }
    }

    func signOut() {
        pollTask?.cancel()
        pollTask = nil
        KeychainTokenStore.clear()
        tokens = nil
        imageURLs = []
        activeSessionId = nil
        phase = .signedOut
        statusMessage = "Signed out."
    }

    /// Opens Google Photos Picker; user selects photos (open an album and multi-select). Requires sign-in.
    func startGooglePhotosPicker() {
        guard let config = oauthConfig, tokens != nil else {
            errorMessage = "Sign in with Google first."
            return
        }
        errorMessage = nil
        statusMessage = "Creating picker session…"
        phase = .pickerOpen
        Task { @MainActor in await runPickerFlow(config: config) }
    }

    private func runPickerFlow(config: GoogleOAuthConfig) async {
        do {
            let fresh = try await refreshedTokens(config: config)
            let session = try await GooglePhotosPickerClient.createSession(accessToken: fresh.accessToken)
            guard let sid = session.id, let picker = session.pickerUri, let pickURL = URL(string: picker) else {
                throw NSError(domain: "AlbumToVideo", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "Picker session response was missing id or URL."
                ])
            }
            activeSessionId = sid
            tokens = fresh
            try KeychainTokenStore.save(fresh)

            NSWorkspace.shared.open(pickURL)
            phase = .waitingForPicks
            statusMessage = "Select photos in your browser, then click Done. This window will update automatically."

            pollTask?.cancel()
            pollTask = Task { await self.pollUntilPicked(sessionId: sid, config: config) }
        } catch {
            errorMessage = error.localizedDescription
            phase = tokens == nil ? .signedOut : .signedIn
            statusMessage = ""
        }
    }

    private func pollUntilPicked(sessionId: String, config: GoogleOAuthConfig) async {
        var interval: TimeInterval = 2
        do {
            while !Task.isCancelled {
                let tok = try await refreshedTokens(config: config)
                tokens = tok
                try KeychainTokenStore.save(tok)
                let s = try await GooglePhotosPickerClient.getSession(id: sessionId, accessToken: tok.accessToken)
                if let cfg = s.pollingConfig {
                    interval = GooglePhotosPickerClient.parsePollIntervalSeconds(cfg.pollInterval)
                }
                if s.mediaItemsSet == true {
                    await MainActor.run {
                        self.statusMessage = "Fetching your selection…"
                    }
                    await downloadPicked(sessionId: sessionId, accessToken: tok.accessToken)
                    _ = try? await GooglePhotosPickerClient.deleteSession(id: sessionId, accessToken: tok.accessToken)
                    await MainActor.run {
                        self.activeSessionId = nil
                    }
                    return
                }
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.phase = self.tokens == nil ? .signedOut : .signedIn
            }
        }
    }

    private func downloadPicked(sessionId: String, accessToken: String) async {
        await MainActor.run {
            phase = .downloading
            downloadProgress = (0, 0)
        }
        do {
            var all: [PickedMediaItemDTO] = []
            var pageToken: String?
            repeat {
                let page = try await GooglePhotosPickerClient.listPickedMedia(
                    sessionId: sessionId,
                    pageToken: pageToken,
                    accessToken: accessToken
                )
                if let items = page.mediaItems { all.append(contentsOf: items) }
                pageToken = page.nextPageToken
            } while pageToken != nil

            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("AlbumToVideo-picks-\(UUID().uuidString)", isDirectory: true)
            let saved = try await PickedMediaDownloader.downloadAll(
                items: all,
                into: folder,
                accessToken: accessToken,
                progress: { done, total in
                    Task { @MainActor in
                        self.downloadProgress = (done, total)
                    }
                }
            )
            await MainActor.run {
                imageURLs = saved
                downloadProgress = nil
                phase = .imagesReady
                statusMessage = "Downloaded \(saved.count) photos. Add optional audio and export."
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                phase = .signedIn
                downloadProgress = nil
            }
        }
    }

    func importLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of images"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let urls = try LocalFolderImageScanner.sortedImageURLs(in: url)
            guard !urls.isEmpty else {
                errorMessage = "No images found in that folder."
                return
            }
            imageURLs = urls
            phase = .imagesReady
            errorMessage = nil
            statusMessage = "Loaded \(urls.count) images from disk (no Google download)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .aiff, .wav]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        audioURL = url
    }

    func clearAudio() {
        audioURL = nil
    }

    func exportVideo() {
        guard !imageURLs.isEmpty else {
            errorMessage = "No images to export."
            return
        }
        let save = NSSavePanel()
        save.allowedContentTypes = [.mpeg4Movie]
        save.nameFieldStringValue = "Slideshow-\(Int(Date().timeIntervalSince1970)).mp4"
        guard save.runModal() == .OK, let out = save.url else { return }

        errorMessage = nil
        phase = .exporting
        exportProgress = 0
        statusMessage = "Rendering video…"

        Task { @MainActor in
            do {
                try await SlideshowExporter.export(
                    imageURLs: imageURLs,
                    audioURL: audioURL,
                    settings: exportSettings,
                    outputURL: out
                ) { p in
                    Task { @MainActor in
                        self.exportProgress = p
                    }
                }
                exportProgress = 1
                phase = .imagesReady
                statusMessage = "Saved to \(out.path)."
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch {
                errorMessage = error.localizedDescription
                phase = .imagesReady
                exportProgress = nil
            }
        }
    }

    private func refreshedTokens(config: GoogleOAuthConfig) async throws -> KeychainTokenStore.StoredTokens {
        guard let t = tokens else {
            throw NSError(domain: "AlbumToVideo", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Not signed in."
            ])
        }
        let oauth = GoogleOAuthService(config: config)
        let refreshed = try await oauth.refreshIfNeeded(t)
        return refreshed
    }
}
