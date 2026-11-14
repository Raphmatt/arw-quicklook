APP     := ARWQuickLook
PROJECT := $(APP).xcodeproj
DERIVED := build
INSTALLED := /Applications/$(APP).app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.DEFAULT_GOAL := help
.PHONY: help generate build install uninstall reset clean

help: ## List the targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

generate: ## Generate the Xcode project from project.yml
	@command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	xcodegen generate

build: generate ## Compile a Debug build (no signing, nothing installed)
	xcodebuild -project $(PROJECT) -scheme $(APP) -configuration Debug \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO -quiet build
	@# Keep the build product out of Launch Services, or System Settings lists
	@# the extensions twice (same fix as in build.sh).
	-@"$(LSREGISTER)" -u "$(CURDIR)/$(DERIVED)/Build/Products/Debug/$(APP).app" 2>/dev/null

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
