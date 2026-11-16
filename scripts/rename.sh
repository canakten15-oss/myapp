#!/bin/bash
# Renames the app everywhere. Run from the repo root BEFORE `xcodegen generate`.
# Usage: ./scripts/rename.sh "AppName" com.yourdomain.appname
set -euo pipefail
NEW="${1:?usage: rename.sh AppName com.yourdomain.appname}"
BUNDLE="${2:?usage: rename.sh AppName com.yourdomain.appname}"
[[ "$NEW" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || { echo "Name must be letters/digits only, no spaces (display name can be changed later in project.yml)"; exit 1; }
cd "$(dirname "$0")/.."

PREFIX="${BUNDLE%.*}"
LOWER="$(echo "$NEW" | tr '[:upper:]' '[:lower:]')"

# file contents
grep -rlI --exclude-dir=.git --exclude-dir=scripts --exclude-dir='*.xcodeproj' -e 'MyApp' -e 'myapp' -e 'com.example' . | while read -r f; do
  sed -i '' -e "s/com\.example\.myapp/$BUNDLE/g" -e "s/bundleIdPrefix: com\.example/bundleIdPrefix: $PREFIX/g" \
            -e "s/MyApp/$NEW/g" -e "s/myapp/$LOWER/g" "$f"
done

# file and folder names (deepest first)
find . -depth -name '*MyApp*' -not -path './.git/*' | while read -r p; do
  mv "$p" "$(dirname "$p")/$(basename "$p" | sed "s/MyApp/$NEW/g")"
done

echo "Renamed to $NEW ($BUNDLE). Now run: xcodegen generate"
