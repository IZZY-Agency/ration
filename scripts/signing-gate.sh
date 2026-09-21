#!/bin/zsh
# Release gate: refuse a Ration.app that is not signed the way we ship it.
#
#   scripts/signing-gate.sh <path/to/Ration.app> [--unnotarized]
#
# Every check is fatal. `--unnotarized` skips only the two checks that need the
# notary ticket (spctl + stapler) — for diagnosing signing problems, never for
# deploying.
#
# Used by release.sh on the exported bundle and by deploy.sh on the installed
# copy, so the same rules apply at both ends.
set -euo pipefail

TEAM_ID="VHZR49D9QB"
IDENTITY="Developer ID Application: IZZY Agency ($TEAM_ID)"
# The sandbox container is keyed by this. A same-team bundle with any other
# identifier would open an empty container and look like it lost every account.
BUNDLE_ID="agency.izzy.ration"
ARCHS=(arm64 x86_64)

APP="${1:?usage: signing-gate.sh <Ration.app> [--unnotarized]}"
NOTARIZED=1
[[ "${2:-}" == "--unnotarized" ]] && NOTARIZED=0

fail() { print -r -- "signing gate FAILED: $*" >&2; exit 1; }
ok()   { print -r -- "  ok  $*"; }

[[ -d "$APP" ]] || fail "not a bundle: $APP"
EXECUTABLE="$APP/Contents/MacOS/Ration"
[[ -x "$EXECUTABLE" ]] || fail "no main executable at $EXECUTABLE"

print -r -- "signing gate: $APP"

# --- identity -------------------------------------------------------------------
info_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$info_bundle_id" == "$BUNDLE_ID" ]] \
  || fail "CFBundleIdentifier is '${info_bundle_id:-missing}', expected $BUNDLE_ID"
ok "CFBundleIdentifier=$BUNDLE_ID"

# --- architecture ---------------------------------------------------------------
# Exactly the shipped set: an extra slice (x86_64h, say) would be a third
# executable the per-slice assertions below never looked at.
archs="$(lipo -archs "$EXECUTABLE")"
slices=(${=archs})
[[ ${#slices} -eq ${#ARCHS} ]] || fail "expected exactly ${ARCHS[*]}, got: $archs"
for arch in "${ARCHS[@]}"; do
  [[ " $archs " == *" $arch "* ]] || fail "not universal: missing $arch (lipo -archs: $archs)"
done
ok "universal, exactly ($archs)"

# --- signature + entitlements, per slice --------------------------------------
# `codesign -d` reports the host architecture only; each slice carries its own
# signature and entitlements, so assert both.
entitlements="$(mktemp -t ration-entitlements)"
trap 'rm -f "$entitlements"' EXIT

entitlement() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$entitlements" 2>/dev/null || true
}

# Every slice lipo reported — whole-line matches, so "…Ration.beta" or a
# longer team string cannot satisfy them.
for arch in "${slices[@]}"; do
  signing_info="$(codesign -d -vv --architecture "$arch" "$APP" 2>&1)"

  grep -qxF "Identifier=$BUNDLE_ID" <<< "$signing_info" \
    || fail "[$arch] signing identifier is not $BUNDLE_ID:"$'\n'"$signing_info"
  grep -qxF "TeamIdentifier=$TEAM_ID" <<< "$signing_info" \
    || fail "[$arch] TeamIdentifier is not $TEAM_ID:"$'\n'"$signing_info"
  grep -qxF "Authority=$IDENTITY" <<< "$signing_info" \
    || fail "[$arch] not signed by \"$IDENTITY\":"$'\n'"$signing_info"
  # CodeDirectory v=… flags=0x10000(runtime) …  — the hardened-runtime bit.
  grep -qE '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<< "$signing_info" \
    || fail "[$arch] hardened runtime flag missing:"$'\n'"$signing_info"
  grep -q '^Timestamp=' <<< "$signing_info" \
    || fail "[$arch] no secure timestamp (signed without --timestamp?):"$'\n'"$signing_info"
  ok "[$arch] Identifier=$BUNDLE_ID, TeamIdentifier=$TEAM_ID, Authority=$IDENTITY, runtime, timestamp"

  codesign -d --architecture "$arch" --entitlements :- "$APP" > "$entitlements" 2>/dev/null \
    || fail "[$arch] could not read entitlements"
  [[ "$(entitlement com.apple.security.app-sandbox)" == "true" ]] \
    || fail "[$arch] com.apple.security.app-sandbox is not true — the app would read the wrong data directory"
  [[ "$(entitlement com.apple.security.network.client)" == "true" ]] \
    || fail "[$arch] com.apple.security.network.client is not true"
  [[ -z "$(entitlement com.apple.security.get-task-allow)" ]] \
    || fail "[$arch] com.apple.security.get-task-allow is present — this is a debuggable build, not a release"
  ok "[$arch] entitlements: app-sandbox, network.client, no get-task-allow"
done

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 \
  || fail "codesign --verify --deep --strict rejected the bundle"
ok "codesign --verify --deep --strict"

# --- notarization ---------------------------------------------------------------
if (( NOTARIZED )); then
  # Exit status is the verdict; the source/origin lines are matched whole so
  # nothing in the path can satisfy them.
  assessment="$(spctl -a -vvv -t exec "$APP" 2>&1)" \
    || fail "Gatekeeper rejected the bundle:"$'\n'"$assessment"
  grep -qxF 'source=Notarized Developer ID' <<< "$assessment" \
    || fail "Gatekeeper accepted, but not as a notarized Developer ID bundle:"$'\n'"$assessment"
  grep -qxF "origin=$IDENTITY" <<< "$assessment" \
    || fail "Gatekeeper origin is not \"$IDENTITY\":"$'\n'"$assessment"
  ok "spctl: accepted, Notarized Developer ID, origin $IDENTITY"

  xcrun stapler validate "$APP" > /dev/null 2>&1 \
    || fail "no stapled notarization ticket"
  ok "stapler validate"
else
  print -r -- "  !!  --unnotarized: spctl and stapler checks SKIPPED — do not deploy this bundle"
fi

print -r -- "signing gate passed"
