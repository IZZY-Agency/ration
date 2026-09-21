#!/bin/zsh
# Install build/export/Ration.app (from `make release`) into /Applications
# on this Mac. User data is untouched: it lives in the sandbox container, keyed
# by bundle ID, not in the bundle.
#
#   make deploy             # or: scripts/deploy.sh
#
# Never deletes anything: the previous bundle goes to ~/.Trash.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="agency.izzy.ration"
APP_SRC="$ROOT/build/export/Ration.app"
APP_DST="/Applications/Ration.app"
# Where an UNSANDBOXED Ration would write. The real data lives in the
# sandbox container, which macOS (15+) shields from other processes once the
# app carries a real signature — so the container cannot be inspected from
# here, but this path can, and it must stay untouched.
UNSANDBOXED_DIR="$HOME/Library/Application Support/Ration"
STAMP="$(date +%Y%m%d-%H%M%S)"

fail() { print -r -- "deploy FAILED: $*" >&2; exit 1; }
step() { print -r -- "==> $*"; }

wait_for() {  # wait_for <running|gone> <seconds>
  local want="$1" deadline=$(( SECONDS + $2 ))
  while (( SECONDS < deadline )); do
    if [[ "$want" == running ]]; then pgrep -xq Ration && return 0
    else pgrep -xq Ration || return 0; fi
    sleep 0.5
  done
  return 1
}

# --- preflight ----------------------------------------------------------------
[[ -d "$APP_SRC" ]] || fail "no $APP_SRC — run \`make release\` first"
step "gate on the exported bundle"
scripts/signing-gate.sh "$APP_SRC"

new_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_SRC/Contents/Info.plist")"
new_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_SRC/Contents/Info.plist")"

# --- stage ---------------------------------------------------------------------
# Copy and gate BEFORE touching the running app: a staging failure then costs
# nothing, and /Applications is without an app only for the instant between
# the two renames below.
step "staging Ration $new_version ($new_build)"
STAGED="$APP_DST.new"
rm -rf "$STAGED"
trap 'rm -rf "$STAGED"' EXIT   # a leftover .new is never useful
ditto "$APP_SRC" "$STAGED"
scripts/signing-gate.sh "$STAGED" > /dev/null || fail "the staged copy failed the gate"

# --- quit ----------------------------------------------------------------------
if pgrep -xq Ration; then
  step "quitting the running app"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" > /dev/null 2>&1 || true
  if ! wait_for gone 15; then
    print -r -- "    did not quit in 15s, sending SIGTERM"
    pkill -x Ration || true
    wait_for gone 10 || fail "Ration is still running"
  fi
fi

# --- swap ----------------------------------------------------------------------
step "installing"
trashed=""
if [[ -d "$APP_DST" ]]; then
  old_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DST/Contents/Info.plist" 2>/dev/null || echo unknown)"
  old_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_DST/Contents/Info.plist" 2>/dev/null || echo 0)"
  trashed="$HOME/.Trash/Ration-$old_version-$old_build-$STAMP.app"
  mv "$APP_DST" "$trashed"
  print -r -- "    previous $old_version ($old_build) → $trashed"
fi
if ! mv "$STAGED" "$APP_DST"; then
  if [[ -n "$trashed" ]] && mv "$trashed" "$APP_DST"; then
    open -a "$APP_DST" || true
    print -r -- "    rolled the previous bundle back into place and relaunched it" >&2
  fi
  fail "could not move the new bundle into $APP_DST"
fi

# --- verify the installed copy ---------------------------------------------------
step "gate on the installed bundle"
scripts/signing-gate.sh "$APP_DST"

step "launching"
launch_marker="$(mktemp -t ration-launch)"
trap 'rm -f "$launch_marker"' EXIT
open -a "$APP_DST"
wait_for running 15 || fail "Ration did not start"
sleep 5
# One lookup, validated, reused: a second instance appearing later or the
# process vanishing must not turn into `lsof -p ""` (which selects every
# process) or a multi-line pid argument.
pid="$(pgrep -x Ration || true)"
[[ "$pid" == <-> ]] || fail "expected exactly one Ration process, pgrep says: '${pid:-none}'"

# Positive proof the process runs inside its App Sandbox: macOS starts a
# sandboxed app with the container's Data directory as its working directory.
# An unsandboxed launch has / or $HOME there. (The container itself is
# TCC-protected from this shell, but lsof reads process state, not the files.)
container_data="$HOME/Library/Containers/$BUNDLE_ID/Data"
cwd_record="$(lsof -a -p "$pid" -d cwd -Fn 2>&1)" \
  || fail "could not inspect process $pid:"$'\n'"$cwd_record"
app_cwd="$(sed -n 's/^n//p' <<< "$cwd_record" | head -1)"
[[ "$app_cwd" == "$container_data" ]] \
  || fail "the app's working directory is '${app_cwd:-unknown}', not the sandbox container $container_data — it is running UNSANDBOXED (data is safe in the container; fix the signature, redeploy)"
print -r -- "    sandbox bound: pid $pid, cwd is the container"

# And the 2026-07-20 / 2026-08-19 incident signature as supplementary evidence:
# a bundle whose sandbox entitlement was stripped writes its files here
# instead of into the container.
touched=()
if [[ -d "$UNSANDBOXED_DIR" ]]; then
  for name in accounts.json snapshots.json; do
    [[ "$UNSANDBOXED_DIR/$name" -nt "$launch_marker" ]] && touched+=("$name")
  done
fi
(( ${#touched} == 0 )) \
  || fail "the app wrote ${(j:, :)touched} to $UNSANDBOXED_DIR — it is running UNSANDBOXED (data is safe in the container; fix the signature, redeploy)"
print -r -- "    nothing written to $UNSANDBOXED_DIR"

step "deployed Ration $new_version ($new_build) to $APP_DST"
