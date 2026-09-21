#!/bin/zsh
# Print the Developer directory the build should use.
#
# Prefers the explicitly selected Xcode (`xcode-select -p`) over the well-known
# install paths. CommandLineTools never qualifies: it has no xcodebuild.
set -euo pipefail

selected="$(xcode-select -p 2>/dev/null || true)"

for candidate in \
  "$selected" \
  /Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode-beta.app/Contents/Developer
do
  if [[ -n "$candidate" \
        && "$candidate" == */Xcode*.app/Contents/Developer \
        && -x "$candidate/usr/bin/xcodebuild" ]]; then
    print -r -- "$candidate"
    exit 0
  fi
done

echo "no Xcode.app found (xcode-select -p = ${selected:-unset})" >&2
exit 1
