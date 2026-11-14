APP     := ARWQuickLook
PROJECT := $(APP).xcodeproj
DERIVED := build
INSTALLED := /Applications/$(APP).app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Version stamped into the app (CFBundleShortVersionString); CI passes the tag.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')
ZIP := $(DERIVED)/$(APP)-$(VERSION).zip
# Release-only speedups (~7 % on a clean build): no dSYM (never shipped), and
# implicit Clang modules, which build only the SDK modules the sources import
# instead of pre-building ~270 explicit PCMs. The shipped binaries don't change.
RELEASE_FAST := DEBUG_INFORMATION_FORMAT=dwarf SWIFT_ENABLE_EXPLICIT_MODULES=NO

.DEFAULT_GOAL := help
.PHONY: help generate icon build release install uninstall reset clean

help: ## List the targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

generate: ## Generate the Xcode project from project.yml
	@command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	xcodegen generate

ICONSET := Support/Assets.xcassets/AppIcon.appiconset

icon: ## Render Support/AppIcon.svg into the AppIcon asset catalog (needs rsvg-convert)
	@command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing: brew install librsvg"; exit 1; }
	for s in 16 32 128 256 512; do \
		rsvg-convert -w $$s -h $$s Support/AppIcon.svg -o $(ICONSET)/icon_$${s}x$${s}.png; \
		rsvg-convert -w $$((s*2)) -h $$((s*2)) Support/AppIcon.svg -o $(ICONSET)/icon_$${s}x$${s}@2x.png; \
	done

build: generate ## Compile a Debug build (no signing, nothing installed)
	xcodebuild -project $(PROJECT) -scheme $(APP) -configuration Debug \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO -quiet build
	@# Keep the build product out of Launch Services, or System Settings lists
	@# the extensions twice (same fix as in build.sh).
	-@"$(LSREGISTER)" -u "$(CURDIR)/$(DERIVED)/Build/Products/Debug/$(APP).app" 2>/dev/null

release: generate ## Build a Release zip (ad-hoc signed, universal) into build/ — nothing installed
	xcodebuild -project $(PROJECT) -scheme $(APP) -configuration Release \
		-derivedDataPath $(DERIVED) MARKETING_VERSION=$(VERSION) \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO $(RELEASE_FAST) -quiet build
	-@"$(LSREGISTER)" -u "$(CURDIR)/$(DERIVED)/Build/Products/Release/$(APP).app" 2>/dev/null
	codesign --verify --deep --strict "$(DERIVED)/Build/Products/Release/$(APP).app"
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(DERIVED)/Build/Products/Release/$(APP).app" "$(ZIP)"
	@echo "$(ZIP)"

install: ## Build Release, install to /Applications and register the extensions
	./build.sh

uninstall: ## Remove the app from /Applications and reset Quick Look
	-"$(LSREGISTER)" -u "$(INSTALLED)" 2>/dev/null
	rm -rf "$(INSTALLED)"
	-qlmanage -r >/dev/null 2>&1
	-qlmanage -r cache >/dev/null 2>&1

reset: ## Reset Quick Look's generators and cache
	-qlmanage -r >/dev/null 2>&1
	-qlmanage -r cache >/dev/null 2>&1
	-killall -KILL quicklookd 2>/dev/null

clean: ## Remove build output and the generated Xcode project
	rm -rf $(DERIVED) $(PROJECT)
