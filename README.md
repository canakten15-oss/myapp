# Slash

*Slash the size. Keep the shot.*

**Shrink the biggest videos in your iPhone library without losing your memories, and without a subscription.**

Slash re-encodes large videos to HEVC on your iPhone's own hardware encoder. It saves the smaller copy with the original's date, location, favorite flag and albums, and only deletes an original after iOS asks you to confirm.

- 100% on-device: no uploads, no account, no server
- Keeps HDR (Dolby Vision is converted to HLG HDR), orientation, GPS, date, camera info and stereo audio
- Never touches edited/trimmed, slo-mo, time-lapse or shared videos
- Free and open source. Ads appear only while videos are compressing: a small banner under the progress bar, plus an optional "play something while you wait" button. Never forced full screen, never before or after a job

> Status: **v0.9.1 prototype.** Not yet on the App Store.

## How it works
1. Lists videos above a size limit (default 100 MB), biggest first. **Nothing is selected and nothing runs until you pick videos and tap Compress**
2. You choose the level: **Max savings** or **Best quality**
3. Loads the original (downloads it from iCloud if needed)
4. Re-encodes it to a quality target (size adapts to the content) with `AVAssetReader` → `AVAssetWriter` (HEVC, 10-bit when the source is HDR)
5. Keeps the result only if it is ≥ 20% smaller, has the same length and passes a frame-by-frame quality check
6. Saves it as a new library item with the original's metadata
7. Lists the originals under "ready to delete". iOS shows its own confirmation, and deleted items stay in *Recently Deleted* for 30 days

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## Build
Requirements: a Mac with Xcode 16+, iOS 17+ device (the simulator has no hardware HEVC encoder worth testing on).

```bash
brew install xcodegen
xcodegen generate
open MyApp.xcodeproj
```
Then set your Team under *Signing & Capabilities* and run on your iPhone.

Rename the app: `./scripts/rename.sh "YourName" com.yourdomain.yourname` (before the first `xcodegen generate`).

## Mac script
`mac/` contains a command-line version for macOS (ffmpeg + osxphotos) that works on a whole iCloud Photos library from a Mac. See [mac/README.md](mac/README.md).

## Docs
- [Architecture](docs/ARCHITECTURE.md)
- [Monetization (AdMob setup)](docs/MONETIZATION.md)
- [App Store submission checklist](docs/APP_STORE.md)
- [Privacy policy](PRIVACY.md)
- [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

## Roadmap
- [ ] Background processing with `BGContinuedProcessingTask` (iOS 26), so the app doesn't need to stay open
- [ ] Before/after preview player
- [ ] Shortcuts action ("shrink videos from last month")
- [ ] Photo compression (HEIC re-encode)
- [ ] Localization: German, Turkish

## License
MIT. See [LICENSE](LICENSE).
