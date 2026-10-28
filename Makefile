# Everything ThermoTune needs, from the command line. Xcode is only needed for its toolchain.
#
# `make` on its own lists every target, which is the only documentation of this file that
# cannot go stale.

PROJECT     := ThermoTune.xcodeproj
SCHEME      := ThermoTune
DERIVED     := build
RELEASE_APP := $(DERIVED)/Build/Products/Release/ThermoTune.app
SHOTS       := $(DERIVED)/screenshots
HELPER      := /Library/PrivilegedHelperTools/com.armend.ThermoTune.Helper

# -quiet keeps the output to warnings and errors. A fixed derived-data path keeps the
# products where the targets below expect them instead of somewhere in ~/Library.
XCODEBUILD  := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -destination "generic/platform=macOS" -quiet

.DEFAULT_GOAL := help
.PHONY: help build release test run shot open version bump helper-status fans-auto clean

help: ## list every target
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  make %-14s %s\n", $$1, $$2}'

build: ## Debug build into build/
	$(XCODEBUILD) -configuration Debug build

release: ## Release build into build/
	$(XCODEBUILD) -configuration Release build

# The tests run inside the app as their host. RunMode keeps that copy read-only, so testing
# beside a ThermoTune someone is using never touches the fans.
test: ## run the unit tests (Debug)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -destination "platform=macOS" -quiet test

# run and shot use Release on purpose. The app compares the installed helper with the one it
# bundles byte for byte, and the helper you installed came from a Release build, so a Debug
# app would always report it as out of date and offer to reinstall it.
run: release ## build Release, then launch it (quits a running copy first)
	-@pkill -TERM -x ThermoTune; sleep 1
	open "$(RELEASE_APP)"

# shot starts a second copy beside any ThermoTune already running and stops only that copy:
# a pkill here once quit the app someone was using. In snapshot mode the app never touches the
# fans, so the two copies don't fight over them.
shot: release ## save the app's windows to build/screenshots (TAB=general|profiles|automation|safety|menuBar|advanced|about adds Preferences)
	@rm -rf "$(SHOTS)"
	@THERMOTUNE_SNAPSHOT_DIR="$(CURDIR)/$(SHOTS)" THERMOTUNE_SETTINGS_TAB="$(TAB)" \
		"$(RELEASE_APP)/Contents/MacOS/ThermoTune" >/dev/null 2>&1 & pid=$$!; sleep 9; kill -TERM $$pid; sleep 1
	@ls "$(SHOTS)"

open: ## open the project in Xcode
	open $(PROJECT)

version: ## print the app's version
	@sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' $(PROJECT)/project.pbxproj | head -1

# Every pull request raises the version, and CI checks that it did, so the "v0.1.3" in the window
# title says which build is installed. Patch by default; PART=minor or PART=major for the others.
bump: ## raise the version for a pull request (PART=minor|major, default patch)
	@old=$$($(MAKE) -s version); \
	new=$$(echo $$old | awk -F. -v part="$(PART)" '{ if (part == "major") { $$1++; $$2 = 0; $$3 = 0 } \
		else if (part == "minor") { $$2++; $$3 = 0 } else { $$3++ }; print $$1 "." $$2 "." $$3 }'); \
	sed -i '' "s/MARKETING_VERSION = $$old;/MARKETING_VERSION = $$new;/" $(PROJECT)/project.pbxproj; \
	echo "$$old -> $$new"

helper-status: ## what the installed helper reports for each fan
	@test -x "$(HELPER)" || { echo "helper not installed at $(HELPER)"; exit 1; }
	"$(HELPER)" status

fans-auto: ## hand every fan back to macOS thermal control
	@test -x "$(HELPER)" || { echo "helper not installed at $(HELPER)"; exit 1; }
	"$(HELPER)" auto-all
	"$(HELPER)" status

clean: ## delete build/
	rm -rf $(DERIVED)
