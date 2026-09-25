#!/bin/sh
# Renders the env-gated layout snapshots (LocalizedLayoutSnapshotTests) in
# Xcode's accented pseudolanguage, for a leak sweep: any unaccented English in
# the PNGs is a string that skipped the catalog.
#
# `xcodebuild -testLanguage` takes ISO 639-1 codes only, and TEST_RUNNER_*
# forwards environment variables, not launch arguments. The scheme editor's
# "Accented Pseudolanguage" is the launch argument
# `-NSAccentuateLocalizedStrings YES`, so it goes into the test run's
# .xctestrun, then `test-without-building` runs from that file.
#
# Usage: scripts/l10n-pseudo.sh <output dir>   (make l10n-pseudo)
set -eu

out="${1:?usage: l10n-pseudo.sh <output dir>}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
derived="build/l10n-pseudo"
destination="platform=macOS,arch=arm64"

xcodebuild build-for-testing -quiet -project Ration.xcodeproj -scheme Ration \
  -destination "$destination" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO

xctestrun="$(ls "$derived"/Build/Products/Ration_*.xctestrun | grep -v '_pseudo\.xctestrun$' | head -n 1)"
pseudo="$derived/Build/Products/Ration_pseudo.xctestrun"
cp "$xctestrun" "$pseudo"
plutil -replace RationTests.CommandLineArguments -json \
  '["-NSAccentuateLocalizedStrings","YES","-AppleLanguages","(en)"]' "$pseudo"
plutil -replace RationTests.EnvironmentVariables.RATION_L10N_SNAPSHOT_DIR -string "$out" "$pseudo"

xcodebuild test-without-building -quiet -xctestrun "$pseudo" -destination "$destination" \
  -only-testing:RationTests/LocalizedLayoutSnapshotTests
echo "Pseudolanguage snapshots: $out"
