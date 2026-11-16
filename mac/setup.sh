#!/bin/bash
# MyApp Mac script v1.0 setup - installs osxphotos (via uv) and ffmpeg/ffprobe. Run once.
set -euo pipefail
[[ "$(uname)" == "Darwin" ]] || { echo "macOS only."; exit 1; }

BIN="$HOME/.myapp-mac/bin"
mkdir -p "$BIN"
export PATH="$BIN:$HOME/.local/bin:$PATH"

echo "== 1/3 uv (Python manager) =="
if ! command -v uv >/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "== 2/3 osxphotos =="
uv tool install --python 3.12 --upgrade osxphotos

echo "== 3/3 ffmpeg with libx265 =="
has_x265() { command -v ffmpeg >/dev/null && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265; }
if ! has_x265 || ! command -v ffprobe >/dev/null; then
  if command -v brew >/dev/null && [[ "$(uname -m)" == "arm64" ]]; then
    brew install ffmpeg
  else
    # static Intel builds (also run on Apple silicon via Rosetta)
    for t in ffmpeg ffprobe; do
      curl -L --fail -o "/tmp/$t.zip" "https://evermeet.cx/ffmpeg/getrelease/$t/zip"
      unzip -o -q "/tmp/$t.zip" -d "$BIN"
      rm "/tmp/$t.zip"
      xattr -d com.apple.quarantine "$BIN/$t" 2>/dev/null || true
      chmod +x "$BIN/$t"
    done
  fi
fi
has_x265 || { echo "ffmpeg without libx265 - install failed"; exit 1; }

chmod +x "$(dirname "$0")/run.sh"
echo
echo "Done. Before the first run:"
echo "  1. System Settings > Privacy & Security > Full Disk Access > enable Terminal"
echo "  2. Open Photos once (signed in with iCloud Photos on)"
echo "Then:  ./run.sh"
