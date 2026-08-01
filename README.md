# DreamD — Browser + Download Manager for iOS

DreamD is a native iOS app that combines a Chrome-style multi-tab web browser
with an IDM-style download manager, a video (HLS/m3u8) downloader, and a
built-in BitTorrent client.

## Features

### Chrome-style browser
- Multiple tabs with a snapshot tab-switcher grid (open, close, switch, "close all")
- New-tab page styled after Google Chrome for iOS (dark theme): Google wordmark,
  "Search Google or type URL" box, AI Mode / Incognito chips, top sites,
  Shortcuts card (Bookmarks, Reading list, Recent tabs, History)
- Bottom toolbar exactly like Chrome: back, forward, new tab (+), tab counter, menu (⋯)
- Omnibox with search-or-URL detection (unknown text becomes a Google search)
- Incognito tabs (non-persistent storage), desktop-site toggle,
  bookmarks, reading list, history with top-sites ranking, recently closed tabs
- `target="_blank"` links open in new tabs; magnet links and `.torrent`
  downloads are intercepted automatically

### IDM-style download manager
- Segmented, multi-connection HTTP/HTTPS downloads (up to 16 parallel
  connections per file, configurable) with a preallocated output file
- Pause / resume / retry, live speed, ETA, progress
- Filename detection from `Content-Disposition`
- Falls back to a single-stream download (with resume data) when the server
  doesn't support ranges

### Video / m3u8 downloader
- Detects media on any web page (hooks `fetch`/XHR + scans `<video>` tags);
  a floating download pill appears when playable media is found
- Downloads HLS streams: master-playlist variant selection (best quality),
  AES-128 segment decryption, fMP4 init segments, ordered concurrent
  segment fetching into a single `.ts` / `.mp4` file
- Direct `.mp4`/`.webm`/audio links download over the segmented engine

### BitTorrent client
- Full native BitTorrent wire protocol (no external libraries)
- `.torrent` files (from the file picker, the browser, or "Open in DreamD")
  and magnet links (BEP 9/10 metadata exchange over peers)
- HTTP and UDP tracker announces, compact peer lists
- Piece verification (SHA-1), multi-file torrents, resume with on-disk
  hash re-checking after relaunch, uploads blocks to peers that ask

### Universal video player (plays every format)
- Plays essentially any container/codec — **MP4, MOV, M4V, MKV, AVI, FLV,
  TS/M2TS, WMV, WebM, MPEG/VOB, OGV, 3GP, ASF, DivX**, plus audio (MP3, FLAC,
  Opus, WMA, AAC, …)
- Uses Apple's **AVPlayer** for hardware-accelerated native formats and
  **VLCKit** (software decoding) for everything else, chosen automatically
- Custom transport controls: play/pause, ±10s skip, scrub bar, time labels,
  tap-to-hide, buffering spinner
- Works from three places: the Files screen, the Downloads list (tap a
  finished video), and the **browser** — a page that navigates to a video the
  web engine can't render (e.g. `.mkv`, `.avi`) opens in the universal player,
  and any sniffed stream has a Play button

### Files
- Built-in file browser with QuickLook previews, universal-player playback,
  sharing, and deletion
- Downloads are visible in the system Files app (On My iPhone → DreamD)

## Building

1. Open `DreamD.xcodeproj` in **Xcode 16 or newer** (the project uses
   folder-synchronized groups) on macOS.
2. On first open Xcode resolves the one Swift Package dependency,
   **VLCKit** (`https://github.com/tylerjonesio/vlckit-spm`, product
   `VLCKitSPM`), which provides the all-format video playback. Let it finish
   downloading (it's a large binary framework the first time). If you prefer,
   you can swap it for `pod 'MobileVLCKit'` or the
   `MobileVLCKit-SPM` package — the player code imports whichever of
   `VLCKitSPM` / `MobileVLCKit` is present.
3. Select the DreamD target → Signing & Capabilities → pick your Team
   (a free Apple ID works for personal installs).
4. Plug in your iPhone, select it as the run destination, and press Run.
   Deployment target is iOS 16.0.

> The player is guarded with `#if canImport(...)`. If you remove the VLCKit
> package the app still builds and runs, falling back to AVPlayer for the
> formats Apple supports natively.

## Notes & limitations

- **Backgrounding:** iOS suspends apps in the background, so torrent and HLS
  downloads run while DreamD is in the foreground. Plain single-stream HTTP
  downloads survive short suspensions via URLSession.
- **Magnet links need trackers.** DHT is not implemented, so magnets must
  include `tr=` tracker parameters (most do). Torrent files always work.
- **DRM is not supported** — FairPlay/Widevine/SAMPLE-AES streams cannot be
  downloaded, by design.
- **Live HLS streams** (no `EXT-X-ENDLIST`) are not downloadable.
- `.ts` and other non-Apple formats play in-app via the built-in VLCKit
  engine; fMP4 streams are saved as `.mp4` and play through AVPlayer.
- **App Store:** Apple does not accept torrent clients on the App Store;
  this app is intended for personal sideloading (Xcode, AltStore, etc.).
- Only download content you have the rights to save.
