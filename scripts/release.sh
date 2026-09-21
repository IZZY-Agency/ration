#!/bin/zsh
# Build the shippable Ration.app: Developer ID signed, hardened runtime,
# notarized, stapled, and checked by scripts/signing-gate.sh.
#
#   make release            # or: scripts/release.sh
#
# Environment:
#   DEVELOPER_DIR   Xcode to use (default: scripts/developer-dir.sh)
#   NOTARY_PROFILE  notarytool keychain profile (default: Ration)
#   SKIP_NOTARIZE=1 sign only — for diagnosing signing problems; the result
#                   is NOT deployable and the gate says so
#
# One-time setup (owner only):
#   1. Xcode → Settings → Accounts → IZZY Agency → Manage Certificates → + →
#      Developer ID Application
#   2. xcrun notarytool store-credentials Ration \
#        --apple-id <apple id> --team-id VHZR49D9QB
#      (password = an app-specific password from account.apple.com)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="VHZR49D9QB"
IDENTITY="Developer ID Application: IZZY Agency ($TEAM_ID)"
NOTARY_PROFILE="${NOTARY_PROFILE:-Ration}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/Ration.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Ration.app"
ZIP="$BUILD_DIR/Ration.zip"
NOTARY_RESULT="$BUILD_DIR/notarization.json"

# A plain assignment carries the resolver's exit status (an `export VAR=$(…)`
# would swallow it), so a missing Xcode stops us here, before anything is
# removed or built.
DEVELOPER_DIR="${DEVELOPER_DIR:-$(scripts/developer-dir.sh)}"
[[ -n "$DEVELOPER_DIR" && -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] \
  || { print -r -- "release FAILED: no usable Xcode at '${DEVELOPER_DIR:-unset}'" >&2; exit 1; }
export DEVELOPER_DIR

fail() { print -r -- "release FAILED: $*" >&2; exit 1; }
step() { print -r -- "==> $*"; }

# --- preflight ----------------------------------------------------------------
step "preflight (DEVELOPER_DIR=$DEVELOPER_DIR)"

security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" \
  || fail "signing identity \"$IDENTITY\" is not in the keychain.
Create it in Xcode → Settings → Accounts → IZZY Agency → Manage Certificates → + → Developer ID Application."

if (( ! SKIP_NOTARIZE )); then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
    || fail "notarytool keychain profile \"$NOTARY_PROFILE\" is missing or rejected.
Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id $TEAM_ID"
fi

xcodegen generate

marketing_version="$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)"$/\1/p' project.yml)"
build_number="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: ([0-9]+)$/\1/p' project.yml)"
[[ -n "$marketing_version" && -n "$build_number" ]] \
  || fail "could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"
step "building Ration $marketing_version ($build_number)"

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$ZIP" "$NOTARY_RESULT"

# --- archive + export ----------------------------------------------------------
# `archive` is the only build action that omits get-task-allow by construction.
# `-sdk macosx` with no `-destination` sidesteps xcodebuild's simulator
# enumeration, which wedges on this machine (see the build notes).
step "archive"
xcodebuild archive -quiet \
  -project Ration.xcodeproj -scheme Ration -configuration Release \
  -sdk macosx -archivePath "$ARCHIVE" \
  || fail "xcodebuild archive failed"

step "export (Developer ID)"
xcodebuild -exportArchive -quiet \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/exportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  || fail "xcodebuild -exportArchive failed"
[[ -d "$APP" ]] || fail "export produced no $APP"

# --- version -------------------------------------------------------------------
info_plist="$APP/Contents/Info.plist"
exported_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist")"
exported_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info_plist")"
[[ "$exported_version" == "$marketing_version" && "$exported_build" == "$build_number" ]] \
  || fail "exported app reports $exported_version ($exported_build) but project.yml says $marketing_version ($build_number) — did xcodegen generate run?"

# --- notarize + staple ----------------------------------------------------------
if (( SKIP_NOTARIZE )); then
  step "SKIP_NOTARIZE=1 — not notarizing"
else
  step "notarize (profile $NOTARY_PROFILE)"
  ditto -c -k --keepParent "$APP" "$ZIP"

  # `--wait` returns non-zero for a rejected submission, but we want the log
  # either way, so capture the JSON first and judge the status ourselves.
  submit_rc=0
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$NOTARY_RESULT" || submit_rc=$?

  submission_id="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
  notary_status="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
  print -r -- "    submission ${submission_id:-?}: ${notary_status:-no status (exit $submit_rc)}"

  if [[ "$notary_status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
      print -r -- "--- notarytool log $submission_id ---" >&2
      xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    fail "notarization not accepted (status: ${notary_status:-unknown}, exit $submit_rc)"
  fi

  step "staple"
  xcrun stapler staple "$APP" || fail "stapler staple failed"
fi

# --- gate ----------------------------------------------------------------------
if (( SKIP_NOTARIZE )); then
  scripts/signing-gate.sh "$APP" --unnotarized
else
  scripts/signing-gate.sh "$APP"
fi

step "release artifact: $APP"
