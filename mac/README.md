# MyApp Mac script v1.0

Shrinks the videos in your iCloud Photos library from a Mac, for free.

## Setup (once)
```bash
cd ~/path/to/repo/mac
chmod +x setup.sh && ./setup.sh
```
- System Settings → Privacy & Security → **Full Disk Access** → enable Terminal.
- The first `--run` asks for permission for Terminal to control Photos. Allow it.
- The Mac has to be signed in with your Apple ID and have **iCloud Photos** turned on. "Optimize Mac Storage" is fine, because originals are downloaded one at a time.

## Use
```bash
./run.sh                      # dry run: lists the biggest videos and estimates the savings
./run.sh --run --limit 3      # test on 3 videos and check them on your iPhone
./run.sh --run                # everything (runs overnight; stop with Ctrl+C and resume later)
```
Options: `--min-mb 100`, `--crf 24` (lower = better quality and bigger file), `--preset fast`, `--encoder fast` (hardware encoder, SDR only, faster but bigger files), `--max-ratio 0.75`.

## What happens to each video
1. The original is downloaded from iCloud if it isn't on the Mac.
2. ffmpeg re-encodes it with x265. HDR/10-bit, date, GPS and camera tags are kept.
3. The result is discarded unless it's at least 25% smaller and has the same duration as the original.
4. The new video is imported into Photos with the original's date, location, title, caption, keywords, favorite flag and albums. It's tagged `myapp-compressed`.
5. The original goes into the album **"MyApp - originals to delete"**. **The script never deletes anything.**

## Freeing the space
Check a few videos in "MyApp - compressed" on your iPhone. Then open "MyApp - originals to delete", select all, press **Cmd+Delete**, and empty **Recently Deleted**. iCloud only frees the space after that last step.

## Skipped on purpose / limits
- Edited or trimmed videos, slo-mo, time-lapse and shared videos are skipped, because re-importing them would lose the edit, the slo-mo or the sharing.
- Face/person tags and Memories aren't carried over. Photos re-detects faces.
- Dolby Vision becomes HLG HDR. It still shows as HDR on the iPhone.
- The spatial audio track (iPhone 16) is dropped and the normal stereo AAC track is kept.
- Speed: x265 on a 2016 dual-core i5 is slow, roughly 1 minute of 4K takes 10–20 minutes. Let it run overnight.
- Progress is stored in `~/.myapp-mac/done.csv`. Failed videos are retried on the next run.
