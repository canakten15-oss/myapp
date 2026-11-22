# Changelog

## 0.8.1 - 2026-11-22
- App name: Slash (home screen, title, texts, report). Copies now go to the album "Slash – compressed"

## 0.8.0 - 2026-11-22
From the first real iPhone test (iPhone 16 Pro, 8 videos):
- Quality check matches frames instead of timestamps: copies of videos with a hidden lead-in were compared against neighbouring frames and wrongly rejected (0.92–0.95 instead of ~0.98)
- 3-second probe from the middle of the video picks the right step before the full encode; hopeless videos are skipped in seconds
- No more "optimize for network use" rewrite: peak free space needed roughly halved (fixes "Disk Full" on a 4.8 GB video)
- Honest free-space check before each video (incl. iCloud download); smallest videos first when space is tight; temp files cleaned on launch
- List in three sections: To do / Shrunk / Can't shrink (remembered, swipe to try again)
- Level, live savings estimate and Compress button together in the bottom bar
- Timer: speed from the last 30 s, smooth countdown, no jump on a second pass; stage labels (Quick test, Compressing, Second try, Finishing, Checking, Saving)
- Result screen after a batch with "Delete N originals"
- Every copy also goes into the album "MyApp – compressed"
- Test report is its own page; logs source fps/bitrate and every attempt
- Version number shown correctly; sleeker look with one accent colour

## 0.7.0 - 2026-11-21
- Bitrate ladder replaces quality mode: smallest rung first, one retry higher, otherwise keep the original
- Quality check at full resolution (was 360 px), 10 frames, worst frame weighted in
- Best quality always spends more bits than Max savings
- Real-footage benchmark with VMAF (bench.yml)

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
