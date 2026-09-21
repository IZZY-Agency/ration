#!/bin/zsh
# Export a snapshot of the public tree into a checkout of the public
# repository (github.com/IZZY-Agency/ration). Built from an allowlist of
# TRACKED files only, so nothing that is not named below can ever reach it.
#
#   scripts/publish.sh <public-checkout>
#       stage the snapshot and print the resulting tree; commit nothing
#
#   scripts/publish.sh <public-checkout> --commit
#       a RELEASE: commit "Ration <version>" (body: that version's CHANGELOG
#       entry) and tag v<version>
#
#   scripts/publish.sh <public-checkout> --update "<subject>"
#       between releases (README, docs, tooling): commit with that subject,
#       no tag. Release tags stay on the commit the shipped build came from.
#
# Pushing is deliberately manual:  git -C <public-checkout> push --follow-tags
#
# The target's tracked files are DELETED and replaced, so the target must be a
# checkout whose origin is the public repository. PUBLISH_TEST_TARGET=1 lifts
# that one check for rehearsals against a scratch clone, and in exchange
# refuses to commit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

TARGET_ARG="${1:?usage: publish.sh <public-checkout> [--commit | --update \"<subject>\"]}"
MODE="${2:-}"
SUBJECT="${3:-}"
case "$MODE" in
  ""|--commit) ;;
  --update) [[ -n "$SUBJECT" ]] || { echo "--update needs a commit subject" >&2; exit 2; } ;;
  *) echo "unknown option: $MODE" >&2; exit 2 ;;
esac

PUBLIC_REMOTE_RE='github\.com[:/]IZZY-Agency/ration(\.git)?/?$'

# Everything the public tree consists of. Paths must be tracked in git.
ALLOW=(
  Ration
  RationTests
  RationUITests
  project.yml
  Makefile
  scripts
  docs/provider-contracts
  docs/KNOWN-LIMITATIONS.md
  README.md
  LICENSE
  CHANGELOG.md
  .github
  .gitignore
)
# Inside the allowlist, but never exported.
EXCLUDE=(scripts/private)
# Paths that must never appear in the public tree, whatever the allowlist
# says: one per line in a file that is itself never exported.
FORBIDDEN_PATHS_FILE="scripts/private/forbidden-paths.txt"
# One extended regex of strings that must not appear in any exported text
# file. It lives outside the export because it spells those strings out.
FORBIDDEN_TEXT_FILE="scripts/private/forbidden-text.pattern"

fail() { print -r -- "publish FAILED: $*" >&2; exit 1; }
step() { print -r -- "==> $*"; }

# Remember, in THIS repository, which commit the public tree was last built
# from. A release tag is the wrong baseline once an untagged update has gone
# out; `last-published` is always right: `git diff last-published..main`,
# `semantic-sweep.py --since last-published`. It is a local lightweight tag,
# so it never touches the working tree.
mark_published() {
  git tag -f last-published HEAD > /dev/null
  print -r -- "    marked $(git rev-parse --short HEAD) as last-published (share it: git push -f origin last-published)"
}

# --- preflight: the source ---------------------------------------------------------
[[ -z "$(git status --porcelain)" ]] || fail "the private working tree is not clean"

[[ -s "$FORBIDDEN_TEXT_FILE" ]] || fail "missing $FORBIDDEN_TEXT_FILE"
[[ -s "$FORBIDDEN_PATHS_FILE" ]] || fail "missing $FORBIDDEN_PATHS_FILE"
FORBIDDEN_TEXT="$(head -1 "$FORBIDDEN_TEXT_FILE")"
[[ -n "$FORBIDDEN_TEXT" ]] || fail "no forbidden text pattern loaded from $FORBIDDEN_TEXT_FILE"
# A malformed pattern must stop us here, before anything is deleted: grep
# answers 0 (match) or 1 (no match) for a valid regex, 2 for a broken one.
regex_rc=0
print -r -- "probe" | grep -qE -- "$FORBIDDEN_TEXT" || regex_rc=$?
(( regex_rc <= 1 )) || fail "the forbidden text pattern is not a valid extended regex (grep exit $regex_rc)"

FORBIDDEN_PATHS=()
while IFS= read -r forbidden_path; do
  [[ -n "$forbidden_path" ]] && FORBIDDEN_PATHS+=("$forbidden_path")
done < "$FORBIDDEN_PATHS_FILE"
(( ${#FORBIDDEN_PATHS} > 0 )) || fail "no forbidden paths loaded from $FORBIDDEN_PATHS_FILE"

version="$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)"$/\1/p' project.yml)"
build="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: ([0-9]+)$/\1/p' project.yml)"
[[ -n "$version" && -n "$build" ]] || fail "could not read the version from project.yml"

for p in "${ALLOW[@]}"; do
  git ls-files --error-unmatch -- "$p" > /dev/null 2>&1 || fail "allowlisted path is not tracked: $p"
done

excludes=()
for e in "${EXCLUDE[@]}"; do excludes+=(":!$e"); done

# `cp` follows symlinks, so a tracked link could carry the CONTENTS of an
# untracked or ignored file out. Nothing in the export may be a symlink.
links="$(git ls-files -s -- "${ALLOW[@]}" "${excludes[@]}" | awk '$1 == "120000" { $1=$2=$3=""; sub(/^ +/, ""); print }')"
[[ -z "$links" ]] || { print -r -- "$links" >&2; fail "symlinks are not exported; replace them with real files"; }

# --- preflight: the target -----------------------------------------------------------
[[ -d "$TARGET_ARG" ]] || fail "$TARGET_ARG is not a directory"
TARGET="$(cd "$TARGET_ARG" && pwd -P)"
target_root="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)" || fail "$TARGET is not a git checkout"
target_root="$(cd "$target_root" && pwd -P)"
[[ "$target_root" == "$TARGET" ]] || fail "$TARGET is inside a checkout ($target_root), not the checkout root"
[[ "$TARGET" != "$ROOT" && "$TARGET" != "$ROOT"/* && "$ROOT" != "$TARGET"/* ]] \
  || fail "the target overlaps the private repository ($ROOT) — this would delete its files"

if [[ "${PUBLISH_TEST_TARGET:-0}" == "1" ]]; then
  [[ -z "$MODE" ]] || fail "PUBLISH_TEST_TARGET=1 is for rehearsals: it never commits"
  step "REHEARSAL target (remote not checked): $TARGET"
else
  target_remote="$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)"
  [[ "$target_remote" =~ $PUBLIC_REMOTE_RE ]] \
    || fail "origin of $TARGET is '${target_remote:-none}', not the public repository — refusing to delete its files"
fi

# Tracked files in the target are replaced wholesale below, so leftover staged
# changes (e.g. from an earlier stage-only run) are fine. Anything else is not:
# an untracked file would be swept in by `git add -A`, and an IGNORED one would
# be too as soon as the exported .gitignore stops ignoring it.
strays="$(git -C "$TARGET" -c status.showUntrackedFiles=all status --porcelain --ignored --untracked-files=all \
  | grep -E '^(\?\?|!!) ' || true)"
[[ -z "$strays" ]] || { print -r -- "$strays" >&2; fail "the public checkout has untracked or ignored files"; }

if [[ "$MODE" == "--commit" ]]; then
  grep -q "^## $version\$" CHANGELOG.md || fail "CHANGELOG.md has no '## $version' entry"
  if git -C "$TARGET" rev-parse -q --verify "refs/tags/v$version" > /dev/null; then
    fail "v$version is already released in the public repo — bump the version, or use --update for a change between releases"
  fi
fi

step "exporting Ration $version ($build) from $(git rev-parse --short HEAD) into $TARGET"

# --- replace the public tree ------------------------------------------------------
# Its tracked files are the whole tree; remove them and the directories they
# leave behind, keep .git.
git -C "$TARGET" ls-files -z | (cd "$TARGET" && xargs -0 rm -f --)
find "$TARGET" -mindepth 1 -type d -empty -not -path "$TARGET/.git" -not -path "$TARGET/.git/*" -delete

# Copy TRACKED files only: untracked or ignored files (build output, generated
# project, editor state) can never leak.
git ls-files -z -- "${ALLOW[@]}" "${excludes[@]}" | while IFS= read -r -d '' f; do
  mkdir -p -- "$TARGET/${f:h}"
  cp -p -- "$f" "$TARGET/$f"
done

# --- gates ---------------------------------------------------------------------
for p in "${FORBIDDEN_PATHS[@]}"; do
  [[ ! -e "$TARGET/$p" && ! -L "$TARGET/$p" ]] || fail "forbidden path exported: $p"
done

# grep: 0 = forbidden text found, 1 = clean, anything else = the scan itself
# failed, which must never read as "clean".
scan_rc=0
hits="$(grep -rnEI --exclude-dir=.git -- "$FORBIDDEN_TEXT" "$TARGET")" || scan_rc=$?
case "$scan_rc" in
  0) print -r -- "$hits" >&2; fail "forbidden text in the public tree" ;;
  1) ;;
  *) fail "the forbidden-text scan itself failed (grep exit $scan_rc)" ;;
esac

# --- show the result ---------------------------------------------------------------
git -C "$TARGET" add -A
count="$(git -C "$TARGET" ls-files | wc -l | tr -d ' ')"
step "public tree: $count files"
git -C "$TARGET" ls-files | sed 's/^/    /'
step "changes against the previous snapshot"
changes="$(git -C "$TARGET" status --short)"
if [[ -z "$changes" ]]; then
  print -r -- "    (none — the public tree already matches)"
else
  print -r -- "$changes" | sed 's/^/    /'
fi

# --- commit ----------------------------------------------------------------------
if [[ -z "$MODE" ]]; then
  step "staged only. Review the tree above, then re-run with --commit or --update \"<subject>\"."
  exit 0
fi
[[ -n "$changes" ]] || fail "nothing to commit"

if [[ "$MODE" == "--update" ]]; then
  git -C "$TARGET" commit -q -F - <<EOF
$SUBJECT

Snapshot between releases; the app is unchanged from v$version unless the
changelog says otherwise.
EOF
  step "committed $(git -C "$TARGET" rev-parse --short HEAD) (no tag)"
  mark_published
  print -r -- "    push with: git -C $TARGET push"
  exit 0
fi

# A release: the commit body is this version's CHANGELOG entry.
body="$(awk -v v="$version" '
  $0 == "## " v { on = 1; next }
  on && /^## /   { exit }
  on             { print }
' CHANGELOG.md | sed -e '/./,$!d')"

git -C "$TARGET" commit -q -F - <<EOF
Ration $version

$body
EOF
git -C "$TARGET" tag -a "v$version" -m "Ration $version ($build)"
step "committed $(git -C "$TARGET" rev-parse --short HEAD) and tagged v$version"
mark_published
print -r -- "    push with: git -C $TARGET push --follow-tags"
print -r -- "    then tag the private tree too: git tag -a v$version -m 'Ration $version ($build)' && git push --tags"
print -r -- "    then: make dmg → gh release create v$version build/Ration-$version.dmg build/Ration-$version.dmg.sha256 → scripts/tap.sh"
