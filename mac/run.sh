#!/bin/bash
# MyApp Mac script v1.0 launcher
export PATH="$HOME/.myapp-mac/bin:$HOME/.local/bin:$PATH"
exec osxphotos run "$(cd "$(dirname "$0")" && pwd)/shrink_library.py" "$@"
