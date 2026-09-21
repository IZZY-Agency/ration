#!/bin/zsh
# Identity gate: the repository, the generated Xcode project and the release
# scripts all agree that the app is Ration with bundle id agency.izzy.ration.
#
#   scripts/verify-ration-identity.sh      # after `xcodegen generate`
#
# Where scripts/private/ exists (the development tree), it also checks that no
# earlier product identity survives anywhere that ships or builds. The names it
# looks for live in that directory, which is never published.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { print -r -- "identity gate FAILED: $*" >&2; exit 1; }

# expect <file> <extended regex>: the file must contain a matching line.
expect() {
  grep -qE -- "$2" "$1" || fail "$1 does not contain /$2/"
}

for candidate in \
  Ration \
  RationTests \
  RationUITests \
  Ration/App/RationApp.swift \
  Ration/Ration.entitlements \
  RationUITests/RationUITests.swift \
  Ration.xcodeproj
do
  [[ -e "$candidate" && ! -L "$candidate" ]] || fail "missing Ration path: $candidate"
done

expect project.yml '^name: Ration$'
expect project.yml '^  Ration:$'
expect project.yml 'PRODUCT_BUNDLE_IDENTIFIER: agency\.izzy\.ration$'
expect project.yml 'PRODUCT_BUNDLE_IDENTIFIER: agency\.izzy\.ration\.Tests$'
expect project.yml 'PRODUCT_BUNDLE_IDENTIFIER: agency\.izzy\.ration\.UITests$'
expect project.yml 'PRODUCT_NAME: Ration$'
expect project.yml 'PRODUCT_MODULE_NAME: Ration$'
expect project.yml 'INFOPLIST_KEY_CFBundleDisplayName: Ration$'
expect project.yml 'CODE_SIGN_ENTITLEMENTS: Ration/Ration\.entitlements$'
expect Makefile '^PROJECT := Ration\.xcodeproj$'
expect Makefile '^SCHEME := Ration$'
expect scripts/deploy.sh '^BUNDLE_ID="agency\.izzy\.ration"$'
expect scripts/signing-gate.sh '^BUNDLE_ID="agency\.izzy\.ration"$'

generated_project='Ration.xcodeproj/project.pbxproj'
generated_scheme='Ration.xcodeproj/xcshareddata/xcschemes/Ration.xcscheme'
expect "$generated_project" 'PRODUCT_BUNDLE_IDENTIFIER = agency\.izzy\.ration;'
expect "$generated_project" 'PRODUCT_BUNDLE_IDENTIFIER = agency\.izzy\.ration\.Tests;'
expect "$generated_project" 'PRODUCT_BUNDLE_IDENTIFIER = agency\.izzy\.ration\.UITests;'
expect "$generated_project" 'PRODUCT_MODULE_NAME = Ration;'
expect "$generated_project" 'PRODUCT_NAME = Ration;'
expect "$generated_project" 'TEST_HOST = "\$\(BUILT_PRODUCTS_DIR\)/Ration\.app/Contents/MacOS/Ration";'
expect "$generated_project" 'TEST_TARGET_NAME = Ration;'
expect "$generated_scheme" 'BuildableName = "Ration\.app"'

# --- earlier identities (development tree only) -------------------------------------
legacy_paths='scripts/private/legacy-paths.txt'
legacy_pattern='scripts/private/legacy-identity.pattern'
if [[ -s "$legacy_paths" && -s "$legacy_pattern" ]]; then
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || fail "legacy path remains: $candidate"
  done < "$legacy_paths"

  scan_roots=(Ration RationTests RationUITests Ration.xcodeproj project.yml Makefile .gitignore scripts
              docs/provider-contracts docs/KNOWN-LIMITATIONS.md)
  [[ -d web ]] && scan_roots+=(web)
  # grep: 0 = found, 1 = clean, anything else = the scan failed (a broken
  # pattern, an unreadable path) and must never read as "clean".
  legacy_rc=0
  legacy="$(
    grep -rnE -I \
      --exclude-dir=private \
      --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.astro --exclude-dir=.wrangler \
      --exclude='*.png' --exclude='*.ico' \
      -- "$(head -1 "$legacy_pattern")" "${scan_roots[@]}"
  )" || legacy_rc=$?
  case "$legacy_rc" in
    0) print -r -- "$legacy" >&2; fail "an earlier identity remains" ;;
    1) ;;
    *) fail "the legacy-identity scan itself failed (grep exit $legacy_rc)" ;;
  esac
  print -r -- "  ok  no earlier identity anywhere that ships or builds"
fi

print -r -- "identity gate passed: Ration / agency.izzy.ration"
