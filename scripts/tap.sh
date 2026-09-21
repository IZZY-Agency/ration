#!/bin/zsh
# Point the Homebrew cask at a release that `make dmg` has produced: rewrite
# version and sha256 in the tap checkout, style-check, commit and push.
#
#   scripts/tap.sh [<tap-checkout>]     default: ../homebrew-tap
#
# Run after the GitHub Release for this version exists with the .dmg attached,
# otherwise `brew fetch` against the new cask fails.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAP="${1:-$ROOT/../homebrew-tap}"
CASK="$TAP/Casks/ration.rb"

fail() { print -r -- "tap FAILED: $*" >&2; exit 1; }
step() { print -r -- "==> $*"; }

version="$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)"$/\1/p' project.yml)"
[[ -n "$version" ]] || fail "could not read MARKETING_VERSION from project.yml"
sum_file="build/Ration-$version.dmg.sha256"
[[ -s "$sum_file" ]] || fail "no $sum_file — run \`make dmg\` first"
sha="$(tr -d '[:space:]' < "$sum_file")"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "$sum_file does not hold a sha256"

[[ -d "$TAP/.git" && -f "$CASK" ]] || fail "$TAP is not the tap checkout"
[[ -z "$(git -C "$TAP" status --porcelain)" ]] || fail "the tap checkout is not clean"

asset="https://github.com/IZZY-Agency/ration/releases/download/v$version/Ration-$version.dmg"
# The cask must pin what users will actually download. A local rebuild after
# the release was uploaded has a different checksum, and Homebrew would then
# refuse the install — so hash the PUBLISHED asset and require it to agree.
step "downloading the published asset to verify its checksum: $asset"
published="$(mktemp -t ration-published-dmg)"
trap 'rm -f "$published"' EXIT
curl -fsSL -o "$published" "$asset" || fail "could not download $asset — publish the GitHub Release first"
published_sha="$(shasum -a 256 "$published" | cut -d' ' -f1)"
[[ "$published_sha" == "$sha" ]] \
  || fail "the published .dmg hashes to $published_sha but $sum_file says $sha — the release asset and the local build differ; re-upload the asset or rebuild nothing, then retry"
sha="$published_sha"

step "cask → $version / $sha"
perl -pi -e 's/^(\s*version ")[^"]+(")$/${1}'"$version"'${2}/; s/^(\s*sha256 ")[0-9a-f]{64}(")$/${1}'"$sha"'${2}/' "$CASK"
grep -q "version \"$version\"" "$CASK" || fail "version line not rewritten"
grep -q "sha256 \"$sha\"" "$CASK" || fail "sha256 line not rewritten"

if command -v brew > /dev/null; then
  step "brew style"
  HOMEBREW_NO_AUTO_UPDATE=1 brew style "$CASK" > /dev/null || fail "brew style rejected the cask"
fi

if [[ -z "$(git -C "$TAP" status --porcelain)" ]]; then
  step "cask already at $version — nothing to commit"
  exit 0
fi
git -C "$TAP" add Casks/ration.rb
git -C "$TAP" commit -q -m "ration $version"
git -C "$TAP" push -q
step "tap updated: $(git -C "$TAP" rev-parse --short HEAD) — brew upgrade now offers $version"
