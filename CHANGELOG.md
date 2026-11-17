# Changelog

## 0.6.0 - 2026-11-17
- Test report in Settings: size, savings, mode, quality score and time per video; shareable
- UI test that taps through the whole app incl. the iOS permission and delete dialogs
- CI builds an unsigned .ipa for sideloading

## 0.5.0 - 2026-11-16
- Quality-target encoding: file size adapts to each video's content; automatic fallback to fixed bitrate on unsupported devices
- Automatic quality check (SSIM on 6 sample frames); a copy that is visibly worse is discarded and the original kept
- "Checking quality..." status; debug log of mode, similarity and size for calibration

## 0.4.0 - 2026-11-16
- Opt-in "Play something while you wait" button on the working screen: full-screen ad only on tap, video off, compression continues behind it
- Ads are loaded only while a batch runs and dropped as soon as it ends

## 0.3.0 - 2026-11-15
- New working screen during a batch: overall progress, current video, space saved, time left
- Ads: one 300x250 banner (image or muted video) ONLY on the working screen while compressing
- Removed the full-screen ad completely; no ads before or after a job

## 0.2.0 - 2026-11-15
- Nothing is pre-selected; users choose every video themselves
- Two compression levels on the main screen: Max savings / Best quality, with live savings estimate
- Quality option removed from Settings

## 0.1.0 - 2026-11-15
- First prototype: scan, HEVC compression (SDR + HDR), metadata/album copy, confirmed batch delete
- Optional AdMob interstitial after batch (off by default)
- Mac command-line script (ffmpeg + osxphotos)
