EXEC     := Fluence
## Release by default: `make install` is what runs every day, and the audio paths (VAD,
## resampling, echo cancellation) are far slower unoptimised. `make CONFIG=debug run` to debug.
CONFIG   ?= release

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
##
## Keyed by checkout path, so two git worktrees building at once never share (and corrupt)
## one scratch directory.
CHECKOUT := $(shell pwd | shasum | cut -c1-10)
SCRATCH  := $(HOME)/Library/Caches/FluenceBuild/$(CHECKOUT)/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/FluenceBuild/$(CHECKOUT)
APPNAME  := Fluence.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC keys the Accessibility grant to the code signature, so an ad-hoc signature — which
## changes on every build — makes the user re-grant after every `make`. Signing with a
## stable identity keeps it constant and the grant sticky: a Developer ID if there is one,
## otherwise the free "Apple Development" certificate Xcode creates for any Apple ID
## (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +). Falls back to ad-hoc ("-").
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)".*/\1/')
endif
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif
## A secure timestamp needs Apple's server: day-to-day builds skip it, `make release` asks for
## it (notarization will require it).
TIMESTAMP ?= --timestamp=none

## Version (FLU-26). Resources/Info.plist is the one place it is written; the build number is
## derived from it — major × 10000 + minor × 100 + patch, as FluenceCore.ReleaseVersion does
## and a test checks. APP_VERSION=x.y.z stamps another version into the bundle without
## touching the repo (the update test builds).
PLIST_VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP_VERSION   ?= $(PLIST_VERSION)
APP_BUILD     := $(shell echo "$(APP_VERSION)" | awk -F. 'NF == 3 { print $$1 * 10000 + $$2 * 100 + $$3 }')

## PUBLIC=1 builds the app for other people (FLU-69): the Wispr Flow interop — which reads that
## app's database and presses its hotkey, fine on Clement's own Mac — is compiled out
## (-DFLUENCE_WITHOUT_WISPR). `make release` always sets it; `make install` keeps the interop.
PUBLIC ?=
SWIFT_FLAGS := $(if $(PUBLIC),-Xswiftc -DFLUENCE_WITHOUT_WISPR,)

## STRIP=1 drops the binary's local symbols (strip -x, FLU-31): `make release` sets it; day-to-day
## builds keep them for debugging.
STRIP ?=

## Another bundle ID makes a copy with its own data folder, settings, Keychain item and
## permissions (AppPaths.isolatedBundleID) — never Clement's. For update tests and screenshots.
BUNDLE_ID ?=

## Updates (FLU-26, docs/RELEASING.md). FEED_URL is the appcast Sparkle reads, baked into the
## bundle (empty, the default: no updater in this build). `make release` writes the new version
## and its appcast into RELEASE_FEED, to be uploaded where FEED_URL and DOWNLOAD_URL_PREFIX
## point. Sparkle only reads http(s): a file:// feed is refused (tested on 2026-10-08).
## One folder per version: generate_appcast gives every archive in the folder the same
## DOWNLOAD_URL_PREFIX, and a GitHub release has one download path per tag.
RELEASE_FEED        ?= $(HOME)/Library/Fluence Releases/$(APP_VERSION)
FEED_URL            ?=
DOWNLOAD_URL_PREFIX ?=

## Sparkle's framework and tools, fetched by SwiftPM with the package.
SPARKLE_ARTIFACT := $(SCRATCH)/artifacts/sparkle/Sparkle
SPARKLE_SRC      := $(SPARKLE_ARTIFACT)/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
SPARKLE_DST      := $(CONTENTS)/Frameworks/Sparkle.framework
SPARKLE_BIN      := $(SPARKLE_ARTIFACT)/bin

## SwiftUI's macros only ship with Xcode. When the active developer directory is the
## Command Line Tools but Xcode is installed, use Xcode for this build without asking for
## `sudo xcode-select`.
ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif
endif

.PHONY: all build app run install clean icon release notices

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)" $(SWIFT_FLAGS)

## Re-packs AppIcon.icns from Resources/AppIcon.iconset. Not a dependency of `app` — the
## icon rarely changes. For new artwork: `Tools/generate_fluence_icons.sh artwork.png`.
icon:
	@Tools/generate_fluence_icons.sh

## Rewrites Resources/THIRD-PARTY-NOTICES.txt from the licences of the pinned packages (FLU-68).
## Run it after Package.resolved changes and commit the result; a test fails when they differ.
notices:
	@swift package resolve --scratch-path "$(SCRATCH)"
	@Tools/generate_third_party_notices.sh "$(SCRATCH)/checkouts"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@test -n "$(APP_BUILD)" || { echo "APP_VERSION must look like 1.2.3, not '$(APP_VERSION)'"; exit 1; }
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources" "$(CONTENTS)/Frameworks"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(APP_VERSION)" \
		-c "Set :CFBundleVersion $(APP_BUILD)" "$(CONTENTS)/Info.plist"
	@if [ -n "$(BUNDLE_ID)" ]; then /usr/libexec/PlistBuddy \
		-c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$(CONTENTS)/Info.plist"; fi
	@if [ -n "$(FEED_URL)" ]; then /usr/libexec/PlistBuddy \
		-c "Add :SUFeedURL string $(FEED_URL)" "$(CONTENTS)/Info.plist"; fi
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@# The licences of the libraries and models Fluence uses (FLU-68), opened from Settings › About.
	@cp Resources/THIRD-PARTY-NOTICES.txt "$(CONTENTS)/Resources/"
	@# The brand mark is drawn (`AquaOrbView`, FLU-12); Resources/AquaOrb.png is the artwork
	@# it was drawn from and is not shipped.
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Sparkle (FLU-26), found by the binary through this rpath. Its XPC services exist for
	@# sandboxed apps only; Fluence is not sandboxed, so they are left out.
	@ditto "$(SPARKLE_SRC)" "$(SPARKLE_DST)"
	@rm -rf "$(SPARKLE_DST)/Versions/B/XPCServices" "$(SPARKLE_DST)/XPCServices"
	@otool -l "$(CONTENTS)/MacOS/$(EXEC)" | grep -q "@executable_path/../Frameworks" \
		|| install_name_tool -add_rpath "@executable_path/../Frameworks" "$(CONTENTS)/MacOS/$(EXEC)"
	@# FLU-31: a release drops the local symbols (about 30 MB down to 20 MB); the global ones
	@# stay, so a crash report still names the functions. Before signing, which it would break.
	@if [ -n "$(STRIP)" ]; then strip -x "$(CONTENTS)/MacOS/$(EXEC)"; fi
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@# Inside out, every piece with this app's identity and the hardened runtime: library
	@# validation then accepts the framework, and Sparkle's check that an update is signed
	@# like the running app compares like with like. Never --deep.
	@codesign --force --sign "$(SIGN_ID)" --options runtime $(TIMESTAMP) "$(SPARKLE_DST)/Versions/B/Autoupdate"
	@codesign --force --sign "$(SIGN_ID)" --options runtime $(TIMESTAMP) "$(SPARKLE_DST)/Versions/B/Updater.app"
	@codesign --force --sign "$(SIGN_ID)" --options runtime $(TIMESTAMP) "$(SPARKLE_DST)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		$(TIMESTAMP) \
		"$(BUNDLE)"
	@codesign --verify --strict --deep "$(BUNDLE)"
	@echo "built $(BUNDLE)  [$(APP_VERSION) ($(APP_BUILD)), signed: $(SIGN_ID)]"

## Only ever targets the Fluence executable — never another dictation app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Ad-hoc signatures change on every rebuild, which resets the Accessibility grant.
## Installing to /Applications keeps the path stable and makes re-granting a one-click fix.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

## A release (FLU-26, docs/RELEASING.md): the signed app zipped with ditto (keeps symlinks and
## the signature intact), its SHA-256, and appcast.xml signed with the EdDSA key kept in this
## Mac's login Keychain — all written into RELEASE_FEED, to be uploaded where FEED_URL and
## DOWNLOAD_URL_PREFIX point. The notes are docs/releases/<version>.html (French, shown by the
## app) and .md (FR + EN, for the GitHub release). Nothing is uploaded or published here.
RELEASE_ZIP := Fluence-$(APP_VERSION).zip

release:
	@test "$(SIGN_ID)" != "-" || { echo "make release needs a stable signing identity: an ad-hoc signature changes every build, and macOS would drop the permissions on every update"; exit 1; }
	@case "$(FEED_URL)" in https://*|http://localhost:*|http://127.0.0.1:*) ;; \
		*) echo "make release needs FEED_URL=https://… (http://localhost only for a test; see docs/RELEASING.md)"; exit 1;; esac
	@test -n "$(DOWNLOAD_URL_PREFIX)" || { echo "make release needs DOWNLOAD_URL_PREFIX (see docs/RELEASING.md)"; exit 1; }
	@test -f "docs/releases/$(APP_VERSION).html" || { echo "missing docs/releases/$(APP_VERSION).html"; exit 1; }
	@test -f "docs/releases/$(APP_VERSION).md" || { echo "missing docs/releases/$(APP_VERSION).md"; exit 1; }
	@test -z "$$(git status --porcelain --untracked-files=no)" -o -n "$(ALLOW_DIRTY)" \
		|| { echo "uncommitted changes: commit first (ALLOW_DIRTY=1 for a test build)"; exit 1; }
	@$(MAKE) --no-print-directory app TIMESTAMP=--timestamp PUBLIC=1 STRIP=1
	@mkdir -p "$(RELEASE_FEED)"
	@rm -f "$(RELEASE_FEED)/$(RELEASE_ZIP)"
	@ditto -c -k --sequesterRsrc --keepParent "$(BUNDLE)" "$(RELEASE_FEED)/$(RELEASE_ZIP)"
	@cp "docs/releases/$(APP_VERSION).html" "$(RELEASE_FEED)/Fluence-$(APP_VERSION).html"
	@"$(SPARKLE_BIN)/generate_appcast" --download-url-prefix "$(DOWNLOAD_URL_PREFIX)" "$(RELEASE_FEED)"
	@cd "$(RELEASE_FEED)" && shasum -a 256 "$(RELEASE_ZIP)" > "$(RELEASE_ZIP).sha256"
	@echo "release $(APP_VERSION) ($(APP_BUILD)) in $(RELEASE_FEED)"
	@cat "$(RELEASE_FEED)/$(RELEASE_ZIP).sha256"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
