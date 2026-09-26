DEVELOPER_DIR ?= $(shell scripts/developer-dir.sh 2>/dev/null)
# Only the targets that run xcodebuild need an Xcode; generate/deploy do not.
XCODE_TARGETS := build unit-test l10n-test l10n-pseudo test clean release
ifneq ($(filter $(XCODE_TARGETS),$(MAKECMDGOALS)),)
ifeq ($(strip $(DEVELOPER_DIR)),)
$(error no Xcode found — install Xcode.app or pass DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer)
endif
endif
PROJECT := Ration.xcodeproj
SCHEME := Ration
DESTINATION := platform=macOS,arch=arm64

.PHONY: generate build unit-test l10n-test l10n-pseudo test clean release dmg deploy

# The test run's UI language. `unit-test` and `test` are the English regression
# runs and are pinned (so is the scheme's test action, in project.yml, for
# Xcode's Cmd-U), so the developer's own macOS language order cannot change
# their outcome.
# `l10n-test L10N_LANG=fr|uk` runs the localization tests in a French or Ukrainian
# process, where Bundle.main.preferredLocalizations — and so AppLanguage.current
# and every catalog lookup without an explicit locale — agree on that language.
# (Not `LANG`: that is the shell's locale variable, and a command-line
# override would be exported into every recipe as an invalid locale.)
L10N_LANGS := fr uk
L10N_TESTS := -only-testing:RationTests/LocalizationProofTests -only-testing:RationTests/CatalogCompletenessTests -only-testing:RationTests/CatalogChecksTests -only-testing:RationTests/AppLanguageTests -only-testing:RationTests/ThemeFontTests -only-testing:RationTests/FormattersLocalizationTests -only-testing:RationTests/SwitchAdviceCopyLocalizationTests -only-testing:RationTests/AlertMessageLocalizationTests -only-testing:RationTests/BannerCopyLocalizationTests -only-testing:RationTests/ResetCopyLocalizationTests -only-testing:RationTests/FocusAndDropCopyLocalizationTests -only-testing:RationTests/LocalizedCopyTests -only-testing:RationTests/SettingsAndErrorCopyLocalizationTests -only-testing:RationTests/PersistedStateLocalizationTests -only-testing:RationTests/PopoverCopyLocalizationTests -only-testing:RationTests/SettingsViewCopyLocalizationTests -only-testing:RationTests/LanguagePickerModelTests -only-testing:RationTests/OnboardingAndAccountsCopyLocalizationTests -only-testing:RationTests/HistoryCopyLocalizationTests -only-testing:RationTests/LayoutFitCopyLocalizationTests -only-testing:RationTests/DueStateCopyLocalizationTests -only-testing:RationTests/LocalizedLayoutSnapshotTests -only-testing:RationTests/AttentionCopyLocalizationTests

generate:
	xcodegen generate

build: generate
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild build -quiet -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' CODE_SIGNING_ALLOWED=NO

unit-test: generate
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild test -quiet -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' -only-testing:RationTests -testLanguage en CODE_SIGNING_ALLOWED=NO

l10n-test: generate
	@case " $(L10N_LANGS) " in *" $(L10N_LANG) "*) ;; *) echo "usage: make l10n-test L10N_LANG=<$(L10N_LANGS)>" >&2; exit 2;; esac
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild test -quiet -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' $(L10N_TESTS) -testLanguage $(L10N_LANG) CODE_SIGNING_ALLOWED=NO

# The layout snapshots in Xcode's accented pseudolanguage (leak sweep): every
# drawn catalog string comes out accented, so plain English in a PNG is a
# string that bypassed the catalog. `-testLanguage` cannot select a
# pseudolanguage; scripts/l10n-pseudo.sh adds `-NSAccentuateLocalizedStrings
# YES` to the test run's .xctestrun instead. PNGs land in L10N_PSEUDO_DIR.
L10N_PSEUDO_DIR ?= build/l10n-pseudo/shots

l10n-pseudo: generate
	DEVELOPER_DIR="$(DEVELOPER_DIR)" scripts/l10n-pseudo.sh "$(L10N_PSEUDO_DIR)"

test: generate
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild test -quiet -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' -testLanguage en

clean: generate
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild clean -quiet -project $(PROJECT) -scheme $(SCHEME)

# Developer ID signed + hardened runtime + notarized + stapled → build/export/Ration.app
release:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" scripts/release.sh

# Drag-to-Applications disk image of the exported app, signed, notarized and
# stapled itself → build/Ration-<version>.dmg (the GitHub Release asset)
dmg:
	scripts/dmg.sh

# Install build/export/Ration.app into /Applications on this Mac
deploy:
	scripts/deploy.sh
