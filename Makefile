EXEC     := MurmurYouTube
CONFIG   := debug

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/MurmurYouTubeBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/MurmurYouTubeBuild
APPNAME  := Fluence.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC keys the Accessibility grant to the code signature, so an ad-hoc signature — which
## changes on every build — makes the user re-grant after every `make`. Signing with a
## stable Developer ID keeps the identity constant and the grant sticky. Falls back to
## ad-hoc ("-") on a machine without the cert.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
REQ_FLAG := -r='designated => identifier "ai.pivotstudio.murmur-youtube"'
else
REQ_FLAG :=
endif

SDK      := $(shell if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]; then echo "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"; fi)
SDK_FLAG := $(if $(SDK),--sdk "$(SDK)",)

.PHONY: all build app run install clean icon test

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)" $(SDK_FLAG)

## Regenerates AppIcon.icns from Tools/makeicon.swift. Not a dependency of `app` — the
## icon rarely changes and rendering 10 PNGs on every build is wasted time.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@cp -R Resources/* "$(CONTENTS)/Resources/" 2>/dev/null || true
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--identifier "ai.pivotstudio.murmur-youtube" \
		$(REQ_FLAG) \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

## Only ever targets the MurmurYouTube executable — never the separate `murmur` app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Ad-hoc signatures change on every rebuild, which resets the Accessibility grant.
## Installing to /Applications keeps the path stable and makes re-granting a one-click fix.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@pkill -f "Murmur YouTube" 2>/dev/null || true
	@pkill -f "Fluence" 2>/dev/null || true
	@rm -rf "/Applications/Murmur YouTube.app"
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@touch "/Applications/$(APPNAME)"
	@killall Dock 2>/dev/null || true
	@open "/Applications/$(APPNAME)"
	@echo "installed and launched /Applications/$(APPNAME)"

TEST_MACRO := $(shell if [ -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib ]; then echo "-Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"; fi)

test:
	@mkdir -p "$(SCRATCH)/out/Products/Debug/PackageFrameworks"
	@ln -sfn /Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework "$(SCRATCH)/out/Products/Debug/PackageFrameworks/Testing.framework" 2>/dev/null || true
	@ln -sfn /Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib "$(SCRATCH)/out/Products/Debug/PackageFrameworks/lib_TestingInterop.dylib" 2>/dev/null || true
	@ln -sfn /Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib "$(SCRATCH)/out/Products/Debug/lib_TestingInterop.dylib" 2>/dev/null || true
	swift test --filter VectorTests --scratch-path "$(SCRATCH)" $(SDK_FLAG) $(TEST_MACRO)

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
