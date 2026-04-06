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

Use an OAuth client type **Desktop app** and a **loopback** redirect. Do **not** use application type **Web application** with `com.albumtovideo.oauth:…` for Google Photos: sensitive scopes require **https** redirects on Web clients, so that combination is rejected in the console.

1. Open [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → **Library** → enable **Photos Picker API**.  
2. **APIs & Services** → **OAuth consent screen** → add scope `…/auth/photospicker.mediaitems.readonly` (and your test user if the app is in Testing).  
3. **APIs & Services** → **Credentials** → **Create credentials** → **OAuth client ID** → application type **Desktop app**.  
4. **You do not add redirect URIs for a Desktop client.** Google’s console is built that way: for desktop apps it does *not* ask for authorized redirect URIs; [Google’s own help](https://support.google.com/cloud/answer/15549257) says *“The console does not require any additional information to create OAuth 2.0 credentials for desktop applications.”* Loopback URLs like `http://127.0.0.1:PORT/...` are part of the [native / desktop OAuth flow](https://developers.google.com/identity/protocols/oauth2/native-app) and work with your **Desktop** client ID without registering them anywhere.  
5. Copy the **Client ID** into the app plist (below). You do **not** put the client secret in the app.

If you see **`redirect_uri_mismatch`**, double-check that **CLIENT_ID** is from a **Desktop** client (not Web), and that you didn’t typo **REDIRECT_URI** in `GoogleOAuthConfig.plist`. If port **8742** is in use, change **REDIRECT_URI** to another port (e.g. `http://127.0.0.1:8743/oauth2callback`) in the plist only — still no URI field in Cloud Console for Desktop.

## Configure the app

1. Edit `AlbumToVideo/GoogleOAuthConfig.plist` (see `GoogleOAuthConfig.example.plist`).  
2. Set **CLIENT_ID** to your Desktop client’s ID.  
3. Default **REDIRECT_URI** is `http://127.0.0.1:8742/oauth2callback` — keep it stable; the same value is sent on the authorize and token steps (Desktop clients do not use a Cloud Console redirect list).  
4. Leave **CALLBACK_URL_SCHEME** empty for loopback. (Only set a custom URL scheme if you use a non-loopback redirect and register it in `Info.plist`.)

## Run

1. Open `AlbumToVideo.xcodeproj` in Xcode.  
2. Select your **Team** in **Signing & Capabilities** if you want a signed debug build (recommended).  
3. **Run** (⌘R).

## Usage

1. **Sign in with Google** — the app briefly listens on **127.0.0.1:8742**, opens the system browser for Google sign-in, then receives the OAuth redirect locally (PKCE; tokens in **Keychain**).  
2. **Pick photos in Google Photos…** — creates a picker session and opens Google’s site. Choose photos (e.g. open an album, select all you want), then finish. The app polls until your selection is ready, then downloads originals (photos only; videos are skipped for the slideshow pipeline).  
3. **Or import folder of images…** — bypasses Google entirely for local testing or exported albums.  
4. Optionally **Choose audio file…** (MP3, M4A, WAV, AIFF, etc.).  
5. Adjust **seconds per slide**, **resolution**, **fps**, **Ken Burns**, **crossfade**, **volume**.  
6. **Export MP4…** — choose output path; Finder reveals the file when done.

## Project layout

- `Services/GoogleOAuthService.swift` — OAuth 2.0 + PKCE, refresh tokens.  
- `Services/OAuthLoopbackReceiver.swift` — loopback redirect for Desktop OAuth + sensitive scopes.  
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
