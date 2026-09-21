DEVELOPER_DIR ?= $(shell scripts/developer-dir.sh 2>/dev/null)
# Only the targets that run xcodebuild need an Xcode; generate/deploy do not.
XCODE_TARGETS := build unit-test test clean release
ifneq ($(filter $(XCODE_TARGETS),$(MAKECMDGOALS)),)
ifeq ($(strip $(DEVELOPER_DIR)),)
$(error no Xcode found — install Xcode.app or pass DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer)
endif
endif
PROJECT := Ration.xcodeproj
SCHEME := Ration
DESTINATION := platform=macOS,arch=arm64

.PHONY: generate build unit-test test clean release dmg deploy

generate:
	xcodegen generate

build: generate
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild build -quiet -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' CODE_SIGNING_ALLOWED=NO

unit-test: generate
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild test -quiet -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' -only-testing:RationTests CODE_SIGNING_ALLOWED=NO

test: generate
	DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild test -quiet -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)'

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
