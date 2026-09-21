#!/bin/zsh
# Package build/export/Ration.app (from `make release`: Developer ID signed,
# notarized, stapled) as a drag-to-Applications disk image, then sign,
# notarize and staple the image itself so Gatekeeper accepts it offline.
#
#   make dmg                # or: scripts/dmg.sh
#
# Environment:
#   NOTARY_PROFILE  notarytool keychain profile (default: Ration)
#   SKIP_NOTARIZE=1 sign the image only — not shippable
#
# Output: build/Ration-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="VHZR49D9QB"
IDENTITY="Developer ID Application: IZZY Agency ($TEAM_ID)"
NOTARY_PROFILE="${NOTARY_PROFILE:-Ration}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/export/Ration.app"
VOLNAME="Ration"

fail() { print -r -- "dmg FAILED: $*" >&2; exit 1; }
step() { print -r -- "==> $*"; }

# --- preflight ----------------------------------------------------------------
[[ -d "$APP" ]] || fail "no $APP — run \`make release\` first"
step "gate on the app going into the image"
scripts/signing-gate.sh "$APP"

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
DMG="$BUILD_DIR/Ration-$version.dmg"

if (( ! SKIP_NOTARIZE )); then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
    || fail "notarytool keychain profile \"$NOTARY_PROFILE\" is missing or rejected"
fi

# --- stage + create ---------------------------------------------------------------
step "staging Ration $version ($build)"
STAGE="$(mktemp -d -t ration-dmg)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Ration.app"
ln -s /Applications "$STAGE/Applications"

step "creating $DMG"
rm -f "$DMG"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG" \
  || fail "hdiutil create failed"

# --- sign + notarize + staple ---------------------------------------------------------
step "signing the image"
codesign --force --sign "$IDENTITY" --timestamp "$DMG" || fail "codesign failed"

if (( SKIP_NOTARIZE )); then
  step "SKIP_NOTARIZE=1 — not notarizing the image"
else
  step "notarize (profile $NOTARY_PROFILE)"
  result="$BUILD_DIR/dmg-notarization.json"
  submit_rc=0
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$result" || submit_rc=$?
  submission_id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  notary_status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  print -r -- "    submission ${submission_id:-?}: ${notary_status:-no status (exit $submit_rc)}"
  if [[ "$notary_status" != "Accepted" ]]; then
    [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "notarization not accepted (status: ${notary_status:-unknown}, exit $submit_rc)"
  fi
  step "staple"
  xcrun stapler staple "$DMG" || fail "stapler staple failed"
fi

# --- verify ----------------------------------------------------------------------
step "verify"
hdiutil verify -quiet "$DMG" || fail "hdiutil verify failed"
codesign --verify --verbose=2 "$DMG" 2>&1 || fail "codesign --verify rejected the image"
if (( ! SKIP_NOTARIZE )); then
  assessment="$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1)" \
    || fail "Gatekeeper rejected the image:"$'\n'"$assessment"
  grep -qxF 'source=Notarized Developer ID' <<< "$assessment" \
    || fail "image accepted, but not as Notarized Developer ID:"$'\n'"$assessment"
  print -r -- "  ok  spctl: Notarized Developer ID"
  xcrun stapler validate "$DMG" > /dev/null 2>&1 || fail "no stapled ticket on the image"
  print -r -- "  ok  stapler validate"
fi

# The app inside must be byte-identical to the gated export.
MOUNT="$(mktemp -d -t ration-dmg-mount)"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" || fail "could not mount the image"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null; rm -rf "$STAGE" "$MOUNT"' EXIT
diff -rq "$APP" "$MOUNT/Ration.app" > /dev/null || fail "app inside the image differs from $APP"
[[ -L "$MOUNT/Applications" ]] || fail "no Applications symlink in the image"
print -r -- "  ok  image contents match the export"
hdiutil detach -quiet "$MOUNT"

size="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
shasum -a 256 "$DMG" | cut -d' ' -f1 > "$DMG.sha256"
step "release image: $DMG ($size), sha256 in $DMG.sha256"
