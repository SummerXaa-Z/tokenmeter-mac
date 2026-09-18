SHELL := /bin/bash

SWIFT_DIR := swift
XCODE_PROJECT := TokenMeter.xcodeproj
SCHEME := TokenMeter
CONFIGURATION ?= Debug
DERIVED_DATA ?= build

.PHONY: project test ui-smoke release-check package clean

project:
	cd $(SWIFT_DIR) && xcodegen generate

test: project
	cd $(SWIFT_DIR) && xcodebuild test \
		-project $(XCODE_PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA)

ui-smoke: project
	cd $(SWIFT_DIR) && xcodebuild \
		-project $(XCODE_PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath $(DERIVED_DATA) \
		build
	open -n "$(CURDIR)/$(SWIFT_DIR)/$(DERIVED_DATA)/Build/Products/Debug/TokenMeter.app" \
		--args --ui-smoke-window

release-check: test
	cd $(SWIFT_DIR) && xcodebuild \
		-project $(XCODE_PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DERIVED_DATA) \
		build
	cd $(SWIFT_DIR) && ./scripts/verify-release-metadata.sh

package: release-check
	cd $(SWIFT_DIR) && ./scripts/package.sh

clean:
	rm -rf $(SWIFT_DIR)/$(DERIVED_DATA)
