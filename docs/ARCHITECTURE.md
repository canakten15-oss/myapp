# Architecture

## Screens
| Screen | Purpose |
|---|---|
| Access | Explains what the app does and asks for full library access |
| Library (main) | Summary card (selected size, estimated savings, total saved), "originals ready to delete" card, list of biggest videos with thumbnail, size, date, duration, status, selection toggle (**nothing pre-selected**). Bottom: compression level (*Max savings* / *Best quality*) with a one-line explanation, then *Compress N videos* / *Stop* |
| Settings | Minimum size for the list, links to source and privacy policy |
| System dialogs | Photo access, iOS delete confirmation, (with ads) consent form + tracking prompt |

## Flow
```
scan (read-only list) ─▶ user selects + picks level ─▶ user taps Compress ─▶ for each video:
                   load original (iCloud download if needed)
                   ─▶ compress (HEVC, hardware)
                   ─▶ verify (duration ±1 s, size ≤ 80 %)
                   ─▶ save new asset + copy metadata + albums
                   ─▶ add original to "pending delete"
        (while the batch runs: working screen with progress panel, optional "play while you wait" button, one 300x250 ad slot)
        ─▶ batch finished ─▶ back to the list, ad slot gone
        ─▶ user taps "Delete originals" ─▶ iOS confirmation ─▶ Recently Deleted
```

## Code
```
MyApp/
  MyAppApp.swift                 app entry
  Models/VideoItem.swift         item, status, quality, formatting, errors
  Services/PhotoLibraryService   PhotoKit: scan, load, save, delete, thumbnails
  Services/VideoCompressor       AVAssetReader/Writer HEVC pipeline
  Services/AdService             AdMob consent + 300x250 banner for the working screen, compiled only if the SDK is added
  ViewModels/LibraryViewModel    state, batch runner, persistence
  Views/ContentView, SettingsView
```

## Key decisions
- **Original, not edited version.** `PHVideoRequestOptions.version = .original`. Edited videos are skipped, because the edit lives as adjustment data on the original and re-importing would lose it.
- **Rate control: bitrate ladder (v0.7).** Target = share of the source bitrate. Best quality tries 55%, then 70%; Max savings 35%, then 50%. Each rung is checked; if the quality check fails, the next rung is tried; if all fail, the original is kept. Sources below 0.05 bits/pixel/frame (messenger videos) are skipped as already efficient. The v0.5 quality mode (`AVVideoQualityKey`) was removed: on real footage it made hard clips bigger than the original and mixed up the two levels.
- **Quality check (v0.7).** SSIM on luma at **full resolution**, 10 frames from 5–95% of the clip, vectorised with Accelerate. Score = 75% average + 25% worst frame, so a short smeared moment isn't averaged away. Thresholds: Best 0.97, Max 0.95 (benchmark: full-res SSIM 0.975 ≈ VMAF 92, 0.946 ≈ VMAF 84, 0.902 ≈ VMAF 67). v0.5 checked at 360 px and let VMAF-47 copies through.
- **Benchmark.** `bench.yml` (manual): real Xiph.org camera clips → iPhone-like HEVC → the app's compressor in the simulator → VMAF/SSIM/PSNR + 100% crops on the `bench-output` branch. Run it after any change to rate control or thresholds.
- **HDR.** Detected via `AVMediaCharacteristic.containsHDRVideo`. The pipeline switches to 10-bit buffers, HEVC Main10 and BT.2020 color with HLG (or PQ) transfer. Dolby Vision RPU metadata is not carried over, so DV becomes plain HLG HDR.
- **Audio.** AAC/ALAC/PCM tracks are passed through untouched. Spatial audio (APAC) tracks are dropped, which is reported in the status.
- **Metadata.** Container metadata (GPS, creation date, make/model) is copied via `AVAssetWriter.metadata`. The library record gets `creationDate`, `location`, `isFavorite` and album membership from the original asset.
- **Deleting is always separate and confirmed.** Originals are collected in `pendingDeleteIDs` (persisted) and deleted in one batch through `PHAssetChangeRequest.deleteAssets`, which shows the iOS confirmation dialog.
- **No re-processing.** Output asset IDs and skipped IDs are stored, so they never show up as candidates again.

## Known limits (v0.1)
- The app must stay open while working (screen sleep is disabled during a batch). Background work comes with `BGContinuedProcessingTask` in iOS 26.
- Faces/people, captions and Memories are not copied. PhotoKit has no API for writing them.
- Videos in shared albums are skipped.
- The file size comes from `PHAssetResource`'s `fileSize` key (widely used, undocumented). If Apple removes it, sizes show as 0 and the scan finds nothing.

## Calibration (first device test)
Run 10–20 real clips (talking, walking, sports, low light, HDR) in a debug build and read the `[compress]` log lines:
- If good-looking clips get rejected → lower `minSSIM`.
- If files are barely smaller → lower `encoderQuality`; if motion looks soft → raise it.

## Testing checklist
- [ ] SDR 1080p clip → smaller, plays, date/place correct in Photos
- [ ] HDR 4K iPhone clip → still shows "HDR" badge in Photos
- [ ] Portrait video → orientation correct
- [ ] Video in 2 albums → copy is in both albums
- [ ] Favorite → copy is favorite
- [ ] iCloud-only video ("Optimize iPhone Storage") → downloads, then compresses
- [ ] Cancel mid-batch → no half-saved files, item back to pending
- [ ] Deny delete dialog → nothing deleted, list kept
