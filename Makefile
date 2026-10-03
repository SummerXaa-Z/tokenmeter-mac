SHELL := /bin/bash

SWIFT_DIR := swift
XCODE_PROJECT := TokenMeter.xcodeproj
SCHEME := TokenMeter
CONFIGURATION ?= Debug
DERIVED_DATA ?= build
UI_RENDER_DIR ?= .ui-review/render
UI_OVERVIEW_DIR ?= .ui-review/overview
# Make's abspath splits paths on spaces. Prefix relative paths without splitting.
absolute-path = $(if $(filter /%,$(firstword $(1))),$(1),$(CURDIR)/$(1))
DERIVED_DATA_PATH := $(if $(filter /%,$(firstword $(DERIVED_DATA))),$(DERIVED_DATA),$(CURDIR)/$(SWIFT_DIR)/$(DERIVED_DATA))
DEBUG_APP := $(DERIVED_DATA_PATH)/Build/Products/Debug/TokenMeter.app
RELEASE_APP := $(DERIVED_DATA_PATH)/Build/Products/Release/TokenMeter.app

.DEFAULT_GOAL := help
.PHONY: help project build debug-build test ui-smoke ui-render ui-render-overview release-check package price-check clean

help:
	@printf '%s\n' \
		'build               Build the app (CONFIGURATION=Debug by default)' \
		'test                Generate the project and run XCTest' \
		'release-check       Run XCTest, build Release and verify metadata' \
		'ui-smoke            Open an isolated Debug window with example data' \
		'ui-render           Render isolated light/dark fixtures to .ui-review/render' \
		'ui-render-overview  Render example overview pages to .ui-review/overview' \
		'project             Regenerate the checked-in Xcode project' \
		'price-check         Compare the price catalog with a public remote API' \
		'package             Build/sign a DMG; see docs/release.md' \
		'clean               Use defaults to remove swift/build; absolute/spaced DERIVED_DATA unsupported'

project:
	cd $(SWIFT_DIR) && xcodegen generate

build: project
	cd $(SWIFT_DIR) && xcodebuild \
		-project $(XCODE_PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath "$(DERIVED_DATA)" \
		build

test: project
	cd $(SWIFT_DIR) && xcodebuild test \
		-project $(XCODE_PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath "$(DERIVED_DATA)"

# Preview flags are Debug-only. Never substitute CONFIGURATION here.
debug-build: project
	cd $(SWIFT_DIR) && xcodebuild \
		-project $(XCODE_PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		build

ui-smoke: debug-build
	open -n "$(DEBUG_APP)" \
		--args --ui-smoke-window

ui-render: debug-build
	"$(DEBUG_APP)/Contents/MacOS/TokenMeter" --ui-render="$(call absolute-path,$(UI_RENDER_DIR))"

ui-render-overview: debug-build
	"$(DEBUG_APP)/Contents/MacOS/TokenMeter" --ui-render="$(call absolute-path,$(UI_OVERVIEW_DIR))" \
		--ui-render-overview-only

release-check: test
	cd $(SWIFT_DIR) && xcodebuild \
		-project $(XCODE_PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath "$(DERIVED_DATA)" \
		build
	cd $(SWIFT_DIR) && ./scripts/verify-release-metadata.sh "$(RELEASE_APP)"

package: release-check
	cd $(SWIFT_DIR) && ./scripts/package.sh

# 价格目录保鲜：比对内置价格快照与 OpenRouter 实时目录（需联网，只读公开接口）
price-check:
	cd $(SWIFT_DIR) && ./scripts/price-check.sh

clean:
	rm -rf $(SWIFT_DIR)/$(DERIVED_DATA)
