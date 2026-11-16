#!/usr/bin/env python3
"""
MyApp Mac script v1.0 - shrink big videos in Apple Photos from a Mac.

Finds big videos in Apple Photos, re-encodes them to HEVC (H.265) with ffmpeg,
imports the smaller copy back into Photos with date, location, title,
description, keywords, favorite flag and albums carried over, and puts the
ORIGINAL into the album "MyApp - originals to delete" so you decide what
gets deleted. Nothing is ever deleted by this script.

Run via:  ./run.sh            (dry run: shows what it would do)
          ./run.sh --run --limit 3   (test on 3 videos)
"""
import argparse
import csv
import datetime as dt
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

VERSION = "1.0"
TAG = "myapp-compressed"
DELETE_ALBUM = "MyApp - originals to delete"
NEW_ALBUM = "MyApp - compressed"
STATE_DIR = Path.home() / ".myapp-mac"
STATE_FILE = STATE_DIR / "done.csv"
STATE_FIELDS = ["uuid", "filename", "orig_bytes", "new_bytes", "status", "new_uuid", "when"]

# Audio codecs ffmpeg can safely stream-copy into .mov. Anything else
# (e.g. Apple's spatial-audio APAC track on iPhone 16) is dropped.
COPYABLE_AUDIO = {"aac", "alac", "mp3", "ac3", "eac3", "opus", "pcm_s16le", "pcm_s24le", "pcm_f32le"}
HDR_TRANSFERS = {"arib-std-b67", "smpte2084"}


# ---------------------------------------------------------------- helpers
def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.1f} {unit}"
        n /= 1024


def ffprobe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-show_format", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout
    data = json.loads(out)
    video = next((s for s in data["streams"] if s.get("codec_type") == "video"
                  and s.get("disposition", {}).get("attached_pic", 0) == 0), None)
    if video is None:
        raise RuntimeError("no video stream")
    audio = [s for s in data["streams"] if s.get("codec_type") == "audio"]
    fmt = data.get("format", {})
    bitrate = int(video.get("bit_rate") or fmt.get("bit_rate") or 0)
    return {
        "codec": video.get("codec_name"),
        "pix_fmt": video.get("pix_fmt", ""),
        "width": int(video.get("width", 0)),
        "height": int(video.get("height", 0)),
        "trc": video.get("color_transfer"),
        "prim": video.get("color_primaries"),
        "space": video.get("color_space"),
        "bitrate": bitrate,
        "duration": float(fmt.get("duration") or video.get("duration") or 0),
        "audio": audio,
    }


def target_bitrate(info):
    """Rough 'already efficient' threshold / hardware-encoder target in bit/s."""
    px = info["width"] * info["height"]
    if px >= 3840 * 2160 * 0.9:
        return 12_000_000
    if px >= 1920 * 1080 * 0.9:
        return 5_000_000
    return 2_500_000


def build_cmd(src, dst, info, encoder="x265", crf=24, preset="fast"):
    """Return (ffmpeg argv, note). Pure function, testable without Photos."""
    ten_bit = "10" in info["pix_fmt"]
    hdr = info["trc"] in HDR_TRANSFERS
    note = ""
    if encoder == "fast" and (ten_bit or hdr):
        # 2016-era Intel Macs cannot hardware-encode 10-bit HEVC; keep HDR intact.
        encoder, note = "x265", "10-bit/HDR source -> using x265 instead of hardware encoder"

    cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-stats",
           "-i", str(src), "-map", "0:v:0"]

    kept_audio = 0
    for s in info["audio"]:
        if s.get("codec_name") in COPYABLE_AUDIO:
            cmd += ["-map", f"0:{s['index']}"]
            kept_audio += 1
    dropped = len(info["audio"]) - kept_audio
    if dropped:
        note += (" | " if note else "") + f"dropped {dropped} audio track(s) ffmpeg can't copy (e.g. spatial audio)"

    cmd += ["-map_metadata", "0", "-fps_mode", "passthrough"]

    color = []
    for flag, key in (("-color_primaries", "prim"), ("-color_trc", "trc"), ("-colorspace", "space")):
        if info[key] and info[key] != "unknown":
            color += [flag, info[key]]

    if encoder == "x265":
        params = ["log-level=error"]
        if info["prim"] and info["prim"] != "unknown":
            params.append(f"colorprim={info['prim']}")
        if info["trc"] and info["trc"] != "unknown":
            params.append(f"transfer={info['trc']}")
        if info["space"] and info["space"] != "unknown":
            params.append(f"colormatrix={info['space']}")
        cmd += ["-c:v", "libx265", "-preset", preset, "-crf", str(crf),
                "-pix_fmt", "yuv420p10le" if ten_bit else "yuv420p",
                "-x265-params", ":".join(params)]
    else:  # fast = Apple hardware encoder (VideoToolbox), 8-bit SDR only
        rate = min(int(info["bitrate"] * 0.45) or target_bitrate(info), target_bitrate(info))
        cmd += ["-c:v", "hevc_videotoolbox", "-b:v", str(rate), "-pix_fmt", "nv12"]

    cmd += color
    cmd += ["-c:a", "copy", "-tag:v", "hvc1",
            "-movflags", "use_metadata_tags+faststart", "-f", "mov", str(dst)]
    return cmd, note


def load_state():
    if not STATE_FILE.exists():
        return {}
    with STATE_FILE.open(newline="") as f:
        return {row["uuid"]: row for row in csv.DictReader(f)}


def save_state(row):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    new = not STATE_FILE.exists()
    with STATE_FILE.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=STATE_FIELDS)
        if new:
            w.writeheader()
        w.writerow({k: row.get(k, "") for k in STATE_FIELDS})


# ---------------------------------------------------------------- Photos side
def find_candidates(db, args, state):
    out, skipped = [], {"edited/trimmed": 0, "slo-mo/timelapse": 0, "shared": 0, "already done": 0}
    for p in db.photos(images=False, movies=True):
        size = p.original_filesize or 0
        if size < args.min_mb * 1024 * 1024:
            continue
        if p.uuid in state or TAG in (p.keywords or []):
            skipped["already done"] += 1
            continue
        if p.hasadjustments:          # trims/edits would be lost on re-import
            skipped["edited/trimmed"] += 1
            continue
        if getattr(p, "slow_mo", False) or getattr(p, "time_lapse", False):
            skipped["slo-mo/timelapse"] += 1
            continue
        if p.shared:
            skipped["shared"] += 1
            continue
        out.append(p)
    out.sort(key=lambda p: p.original_filesize, reverse=True)
    return out, skipped


def get_or_create_album(lib, name):
    import photoscript
    return lib.album(name, top_level=True) or lib.create_album(name)


def copy_metadata(p, new, lib):
    import photoscript
    new.date = p.date.astimezone().replace(tzinfo=None)  # Photos wants local naive time
    lat, lon = p.location
    if lat is not None and lon is not None:
        new.location = (lat, lon)
    if p.title:
        new.title = p.title
    if p.description:
        new.description = p.description
    new.keywords = list(dict.fromkeys(list(p.keywords or []) + [TAG]))
    new.favorite = bool(p.favorite)
    for a in p.album_info:
        try:
            photoscript.Album(a.uuid).add([new])
        except Exception as e:  # smart/shared albums can't be added to
            print(f"    ! could not add to album '{a.title}': {e}")


def process(p, args, lib, work):
    import photoscript
    size = p.original_filesize
    tmp = work / p.uuid
    tmp.mkdir(parents=True, exist_ok=True)
    row = {"uuid": p.uuid, "filename": p.original_filename, "orig_bytes": size,
           "when": dt.datetime.now().isoformat(timespec="seconds")}
    try:
        if shutil.disk_usage(work).free < size * 2.5:
            raise SystemExit(f"Not enough free disk space in {work} for {p.original_filename}. Stopping.")

        # 1. get the original file (downloads from iCloud if only in the cloud)
        if p.path and not p.ismissing and Path(p.path).exists():
            src = Path(p.path)
        else:
            print("    downloading original from iCloud (Photos must be open)...")
            files = p.export(str(tmp), use_photos_export=True, timeout=1800)
            files = [f for f in files if Path(f).suffix.lower() in (".mov", ".mp4", ".m4v")]
            if not files:
                raise RuntimeError("download/export failed")
            src = Path(files[0])

        info = ffprobe(src)
        if info["codec"] == "hevc" and 0 < info["bitrate"] <= target_bitrate(info):
            row["status"] = "skipped: already efficient"
            return row

        # 2. encode
        dst = tmp / (Path(p.original_filename).stem + "_small.mov")
        cmd, note = build_cmd(src, dst, info, args.encoder, args.crf, args.preset)
        if note:
            print(f"    note: {note}")
        t0 = time.time()
        subprocess.run(cmd, check=True)
        print(f"\n    encoded in {(time.time() - t0) / 60:.1f} min")

        # 3. verify
        out = ffprobe(dst)
        new_size = dst.stat().st_size
        row["new_bytes"] = new_size
        if abs(out["duration"] - info["duration"]) > 1.0:
            row["status"] = f"failed: duration mismatch {out['duration']:.1f}s vs {info['duration']:.1f}s"
            return row
        if new_size > size * args.max_ratio:
            row["status"] = f"skipped: only {100 - new_size * 100 // size}% smaller"
            return row

        # 4. import + carry metadata over + mark original
        new = lib.import_photos([dst], skip_duplicate_check=True)[0]
        copy_metadata(p, new, lib)
        get_or_create_album(lib, NEW_ALBUM).add([new])
        get_or_create_album(lib, DELETE_ALBUM).add([photoscript.Photo(p.uuid)])
        row["new_uuid"] = new.uuid
        row["status"] = "done"
        return row
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=f"MyApp v{VERSION}")
    ap.add_argument("--run", action="store_true", help="actually process (default is a dry run)")
    ap.add_argument("--limit", type=int, default=0, help="max number of videos this run (0 = all)")
    ap.add_argument("--min-mb", type=int, default=100, help="only videos at least this big (MB), default 100")
    ap.add_argument("--encoder", choices=["x265", "fast"], default="x265",
                    help="x265 = best quality/size, slow (default). fast = hardware, SDR only, bigger files")
    ap.add_argument("--crf", type=int, default=24, help="x265 quality, lower = better/bigger. 22-26 sensible, default 24")
    ap.add_argument("--preset", default="fast", help="x265 preset: faster|fast|medium|slow, default fast")
    ap.add_argument("--max-ratio", type=float, default=0.75,
                    help="keep result only if new size <= this x original, default 0.75")
    ap.add_argument("--workdir", default=str(Path.home() / "MyApp-work"))
    args = ap.parse_args()

    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found. Run ./setup.sh first.")

    import osxphotos
    import photoscript

    print(f"MyApp v{VERSION} - reading Photos library...")
    db = osxphotos.PhotosDB()
    state = load_state()
    cands, skipped = find_candidates(db, args, state)
    if args.limit:
        cands = cands[: args.limit]
    total = sum(p.original_filesize for p in cands)

    print(f"\n{len(cands)} video(s) >= {args.min_mb} MB, total {human(total)}")
    print("not touched: " + (", ".join(f"{k} {v}" for k, v in skipped.items() if v) or "-"))
    for p in cands[:25]:
        cloud = " (iCloud only)" if p.ismissing else ""
        print(f"  {human(p.original_filesize):>9}  {p.date:%Y-%m-%d}  {p.original_filename}{cloud}")
    if len(cands) > 25:
        print(f"  ... and {len(cands) - 25} more")
    print(f"\nRough estimate: saves ~{human(total * 0.5)} (typically 40-70% per iPhone video).")

    if not args.run:
        print("\nDry run only. Add --run to start, e.g.  ./run.sh --run --limit 3")
        return

    work = Path(args.workdir).expanduser()
    work.mkdir(parents=True, exist_ok=True)
    lib = photoscript.PhotosLibrary()
    lib.activate()

    saved = 0
    for i, p in enumerate(cands, 1):
        print(f"\n[{i}/{len(cands)}] {p.original_filename}  {human(p.original_filesize)}")
        try:
            row = process(p, args, lib, work)
        except KeyboardInterrupt:
            print("\nStopped. Already finished videos are kept; run again to continue.")
            break
        except subprocess.CalledProcessError as e:
            row = {"uuid": p.uuid, "filename": p.original_filename, "orig_bytes": p.original_filesize,
                   "status": f"failed: ffmpeg exit {e.returncode}", "when": dt.datetime.now().isoformat(timespec="seconds")}
        except Exception as e:
            row = {"uuid": p.uuid, "filename": p.original_filename, "orig_bytes": p.original_filesize,
                   "status": f"failed: {e}", "when": dt.datetime.now().isoformat(timespec="seconds")}
        print(f"    -> {row['status']}"
              + (f"  ({human(row['orig_bytes'])} -> {human(row['new_bytes'])})" if row.get("new_bytes") else ""))
        # failures are not recorded so they are retried next time
        if not row["status"].startswith("failed"):
            save_state(row)
        if row["status"] == "done":
            saved += int(row["orig_bytes"]) - int(row["new_bytes"])

    print(f"\nFinished. Space you can free: {human(saved)}")
    print(f"Next: open the album '{DELETE_ALBUM}' in Photos, check a few videos in '{NEW_ALBUM}',")
    print("then select all originals and press Cmd+Delete, then empty 'Recently Deleted'.")


if __name__ == "__main__":
    main()
