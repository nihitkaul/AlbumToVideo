# Album to Video

macOS app that connects to **Google Photos** (via Google’s supported **Photos Picker API**), downloads the images you choose, and turns them into an **H.264/AAC MP4** slideshow—with optional **Ken Burns** motion, **crossfades**, and a **soundtrack**.

Built for personal use: native **SwiftUI**, **App Sandbox**, **PKCE OAuth**, and **AVFoundation** export.

## Why not “pick an album by API”?

Google removed broad library access for new integrations after **31 March 2025**. The **Library API** is now limited to content **created by your app**; selecting arbitrary albums requires the **Picker API**, where the user chooses photos inside Google’s UI (you can open an album and multi-select). This app follows that policy. See [Google’s Photos API updates](https://developers.google.com/photos/support/updates).

## Requirements

- macOS **14** or later  
- **Xcode 16** (or newer) with the full Xcode app selected (`xcode-select -s /Applications/Xcode.app/...`)  
- A **Google Cloud** project with **Photos Picker API** enabled  

## Google Cloud setup

1. Open [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → **Enable APIs** → enable **Photos Picker API**.  
2. **Credentials** → **Create credentials** → **OAuth client ID** → type **Desktop app** (or a type that allows custom redirect URIs).  
3. Under **Authorized redirect URIs**, add exactly:  
   `com.albumtovideo.oauth:/oauth2callback`  
4. Copy the **Client ID** string.

## Configure the app

1. Edit `AlbumToVideo/GoogleOAuthConfig.plist` (or copy from `GoogleOAuthConfig.example.plist`).  
2. Set **CLIENT_ID** to your OAuth client ID.  
3. Keep **REDIRECT_URI** and **CALLBACK_URL_SCHEME** aligned with what you registered (defaults match `Info.plist` URL scheme `com.albumtovideo.oauth`).

## Run

1. Open `AlbumToVideo.xcodeproj` in Xcode.  
2. Select your **Team** in **Signing & Capabilities** if you want a signed debug build (recommended).  
3. **Run** (⌘R).

## Usage

1. **Sign in with Google** — browser sheet, PKCE, tokens stored in the **Keychain**.  
2. **Pick photos in Google Photos…** — creates a picker session and opens Google’s site. Choose photos (e.g. open an album, select all you want), then finish. The app polls until your selection is ready, then downloads originals (photos only; videos are skipped for the slideshow pipeline).  
3. **Or import folder of images…** — bypasses Google entirely for local testing or exported albums.  
4. Optionally **Choose audio file…** (MP3, M4A, WAV, AIFF, etc.).  
5. Adjust **seconds per slide**, **resolution**, **fps**, **Ken Burns**, **crossfade**, **volume**.  
6. **Export MP4…** — choose output path; Finder reveals the file when done.

## Project layout

- `Services/GoogleOAuthService.swift` — OAuth 2.0 + PKCE, refresh tokens.  
- `Services/GooglePhotosPickerClient.swift` — Picker sessions + listing picked items.  
- `Services/PickedMediaDownloader.swift` — Authorized downloads from `baseUrl`.  
- `Services/SlideshowExporter.swift` — `AVAssetWriter` slideshow + optional audio mux.  
- `AppViewModel.swift` / `ContentView.swift` — UI and orchestration.

## Known limitations / follow-ups

- **Picker UX** is “select in browser,” not a native album grid—this is imposed by Google’s current APIs.  
- **Large libraries / many huge images** — export time and memory use grow with resolution; lower output size for faster runs.  
- **Unverified OAuth app** — you may see Google’s warning screen until the app is verified (fine for personal testing with your own account).  
- **Sandbox** — only **user-selected** save locations and network; downloads go to a temp folder inside the sandbox.

## License

Private / personal use unless you add a license. All rights reserved unless otherwise stated.
