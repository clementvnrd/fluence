EXEC     := Fluence
## Release by default: `make install` is what runs every day, and the audio paths (VAD,
## resampling, echo cancellation) are far slower unoptimised. `make CONFIG=debug run` to debug.
CONFIG   ?= release

## SwiftPM's build products stay out of the repository folder too, for the reason that keeps
## the staged app out of it (see below). The checkout lives in an iCloud-synced folder, and the
## sync engine rewrites files under the build directory while the compiler is reading them: the
## "input file was modified during the build" error on whichever object files it hit, and once
## in a while a compiler front-end that sits there at zero CPU. ~/Library/Caches is never synced,
## so a scratch path there takes the race away.
##
## Keyed by checkout path, so two git worktrees building at once never share (and corrupt)
## one scratch directory.
CHECKOUT := $(shell pwd | shasum | cut -c1-10)
SCRATCH  := $(HOME)/Library/Caches/FluenceBuild/$(CHECKOUT)/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)
## The .app is put together and signed outside the repo, on purpose. The repo sits in the iCloud
## (file-provider) synced folder, whose sync engine tags the files inside a bundle with the
## com.apple.FinderInfo extended attribute quicker than anything can take it off again, and
## codesign will not sign a bundle holding such attributes at all (it complains about Finder
## information and "detritus"). Clearing the attributes recursively right before signing is not
## enough: the sync engine writes them back in between. Staging under ~/Library/Caches avoids it
## altogether.
STAGE    := $(HOME)/Library/Caches/FluenceBuild/$(CHECKOUT)
APPNAME  := Fluence.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents
## Signing identity. TCC binds the Accessibility grant to the app's code signature, and an
## ad-hoc signature comes out different on every build: with one, the permission has to be
## granted again after each `make`. Signing with a
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
## An ad-hoc signature has no Team ID, so the hardened runtime's library validation refuses the
## embedded Sparkle ("mapping process and mapped file have different Team IDs") and the app
## aborts before main — every ad-hoc build since FLU-26, found by the launch check (FLU-35). An
## ad-hoc build (CI, a Mac without a certificate) therefore gets one more entitlement, which
## turns library validation off; a build signed with an identity never does, and `make release`
## refuses ad-hoc anyway.
ENTITLEMENTS := Resources/$(EXEC).entitlements
ifeq ($(strip $(SIGN_ID)),-)
ENTITLEMENTS := $(STAGE)/adhoc.entitlements
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

.PHONY: all build app check-app run install clean icon release notices

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

## Assembles a real .app bundle: TCC (microphone, Accessibility) recognises an app by its bundle
## identity and its code signature, so the bare executable SwiftPM produces will not do.
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
	@# Belt and braces: the staging folder is not synced, but the executable copied in above may
	@# still carry extended attributes from the build directory, which once lived in the synced tree.
	@xattr -cr "$(BUNDLE)"
	@# Inside out, every piece with this app's identity and the hardened runtime: library
	@# validation then accepts the framework, and Sparkle's check that an update is signed
	@# like the running app compares like with like. Never --deep.
	@codesign --force --sign "$(SIGN_ID)" --options runtime $(TIMESTAMP) "$(SPARKLE_DST)/Versions/B/Autoupdate"
	@codesign --force --sign "$(SIGN_ID)" --options runtime $(TIMESTAMP) "$(SPARKLE_DST)/Versions/B/Updater.app"
	@codesign --force --sign "$(SIGN_ID)" --options runtime $(TIMESTAMP) "$(SPARKLE_DST)"
	@if [ "$(ENTITLEMENTS)" != "Resources/$(EXEC).entitlements" ]; then \
		cp Resources/$(EXEC).entitlements "$(ENTITLEMENTS)" && /usr/libexec/PlistBuddy \
		-c "Add :com.apple.security.cs.disable-library-validation bool true" "$(ENTITLEMENTS)" >/dev/null; fi
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements "$(ENTITLEMENTS)" \
		--options runtime \
		$(TIMESTAMP) \
		"$(BUNDLE)"
	@codesign --verify --strict --deep "$(BUNDLE)"
	@echo "built $(BUNDLE)  [$(APP_VERSION) ($(APP_BUILD)), signed: $(SIGN_ID)]"

## What CI checks on every push and every night (FLU-35): the bundle as built — signature,
## version, Sparkle and its rpath — then a launch with --selftest, which opens the settings and
## the stores in a scratch folder of its own and exits. `make check-app PUBLIC=1` checks a
## build for other people. Opens no window and touches neither /Applications nor your data.
check-app: app
	@Tools/check_app_bundle.sh "$(BUNDLE)" $(if $(PUBLIC),--public,)

## Only ever targets the Fluence executable — never another dictation app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## An ad-hoc signature is new after every build, which costs the Accessibility grant; a fixed
## path in /Applications at least turns granting it again into a single click.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# BUNDLE is an absolute path in the staging folder, so the destination in /Applications is
	@# built from the app name alone, never from BUNDLE.
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
