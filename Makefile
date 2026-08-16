# Copyright © 2025 Florent Benoit. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

BUILD_CONFIGURATION ?= debug
APP_RELEASE_VERSION ?= 1.3.0
APP_BUILD_NUMBER ?= 1
TEST_PARALLELISM ?= $(shell sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu)
TEST_SWIFT_FLAGS ?= --disable-index-store

SWIFT := swift
ROOT_DIR := $(shell git rev-parse --show-toplevel)
ACTIONLINT_VERSION ?= v1.7.12

MACOS_VERSION := $(shell sw_vers -productVersion)
MACOS_MAJOR := $(shell echo $(MACOS_VERSION) | cut -d. -f1)
# Release metadata comes from an explicit value or an exact v-prefixed tag.
BUILD_VERSION ?= $(or $(shell git describe --tags --exact-match HEAD 2>/dev/null | sed 's/^v//'),0.0.0-dev)
BUILD_GIT_COMMIT ?= $(shell git rev-parse HEAD 2>/dev/null || echo "unknown")
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || echo 0)
BUILD_TIME ?= $(shell scripts/release/build-time.sh "$(SOURCE_DATE_EPOCH)" 2>/dev/null || echo development)
export BUILD_VERSION BUILD_GIT_COMMIT BUILD_TIME SOURCE_DATE_EPOCH
# Build information - docker engine API versions
export DOCKER_ENGINE_API_MIN_VERSION := v1.32
export DOCKER_ENGINE_API_MAX_VERSION := v1.51

SUDO ?= sudo
.DEFAULT_GOAL := all

.PHONY: all
all: glassdock

.PHONY: build
build:
	@echo Building Glass Dock binary...
	@$(SWIFT) build -c $(BUILD_CONFIGURATION)

.PHONY: glassdock
glassdock: build

.PHONY: release
release: BUILD_CONFIGURATION = release
release:
	@scripts/release/validate-version.sh "$(BUILD_VERSION)"
	@echo Building arm64 Glass Dock $(BUILD_VERSION)...
	@$(SWIFT) build -c release --arch arm64 --disable-index-store --product glassdock
	@file .build/release/glassdock | grep -q arm64

.PHONY: version
version:
	@echo "Version: $(BUILD_VERSION)"
	@echo "Commit: $(BUILD_GIT_COMMIT)"
	@echo "Build Time: $(BUILD_TIME)"
	@echo "Docker Engine API Min version: $(DOCKER_ENGINE_API_MIN_VERSION)"
	@echo "Docker Engine API Max version: $(DOCKER_ENGINE_API_MAX_VERSION)"

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  all              - Build Glass Dock (default)"
	@echo "  build            - Build in debug mode"
	@echo "  release          - Build the arm64 release daemon"
	@echo "  control          - Build glassdockctl"
	@echo "  menu-app         - Build a local Glass Dock.app bundle"
	@echo "  menu-popover-test - Verify the built menu-bar popover is visible"
	@echo "  menu-release     - Prepare a Developer ID-signed app archive without submission"
	@echo "  publishing-validate - Validate local Apple and Raycast publishing inputs"
	@echo "  raycast-install  - Install Raycast extension dependencies"
	@echo "  raycast-build    - Build and lint the Raycast extension"
	@echo "  release-artifacts - Build signed and notarized distribution artifacts"
	@echo "  release-artifacts-local - Build and verify unsigned local artifacts"
	@echo "  test             - Run tests"
	@echo "  integration      - Run live Docker lifecycle integration tests"
	@echo "  benchmark-preflight - Validate runtime benchmark configuration"
	@echo "  benchmark-tools-test - Test benchmark tool install/uninstall plans"
	@echo "  benchmark        - Run the configured runtime benchmark matrix"
	@echo "  fmt              - Format source code"
	@echo "  clean            - Clean build artifacts"
	@echo "  version          - Show version information"
	@echo "  installer        - Build unsigned macOS .pkg installer"
	@echo "  installer-signed - Build signed macOS .pkg installer"
	@echo "  installer-notarized - Build signed and notarized .pkg installer"
	@echo "  installer-test   - Build and inspect a fixture installer"
	@echo "  release-tools-test - Test release metadata scripts"
	@echo "  actionlint       - Validate GitHub Actions workflows"
	@echo "  installer-help   - Show detailed installer help"
	@echo "  help             - Show this help message"

.PHONY: test
test: lint-pipes
	@$(SWIFT) test -c $(BUILD_CONFIGURATION) $(TEST_SWIFT_FLAGS) \
		--experimental-maximum-parallelization-width $(TEST_PARALLELISM)

.PHONY: control
control:
	@$(SWIFT) build -c $(BUILD_CONFIGURATION) --product glassdockctl

.PHONY: menu-app
menu-app:
	@bash scripts/build-menu-app.sh $(BUILD_CONFIGURATION) $(BUILD_VERSION)

.PHONY: menu-popover-test
menu-popover-test: menu-app
	@bash scripts/test-menu-popover.sh .build/$(BUILD_CONFIGURATION)/GlassDock.app/Contents/MacOS/GlassDockMenu

.PHONY: menu-release
menu-release:
	@bash scripts/prepare-menu-release.sh \
		--version "$(APP_RELEASE_VERSION)" \
		--build "$(APP_BUILD_NUMBER)"

.PHONY: publishing-validate
publishing-validate:
	@plutil -lint \
		Apps/GlassDockMenu/Info.plist \
		Apps/GlassDockMenu/GlassDockMenu.entitlements \
		Apps/GlassDockMenu/PrivacyInfo.xcprivacy >/dev/null
	@jq -e . Apps/GlassDockMenu/Distribution.json raycast/package.json >/dev/null
	@codesign --verify --deep --strict .build/release/GlassDock.app
	@unzip -tq ".build/release-distribution/GlassDock-$(APP_RELEASE_VERSION)-macOS-arm64.zip" >/dev/null
	@npm --prefix raycast run lint
	@npm --prefix raycast run build

.PHONY: integration
integration:
	@bash scripts/integration-runtime.sh

.PHONY: benchmark-preflight
benchmark-preflight:
	@bash scripts/benchmark-runtime.sh --preflight

.PHONY: benchmark-test
benchmark-test:
	@bash scripts/tests/benchmark-runtime-parser-test.sh

.PHONY: benchmark-tools-test
benchmark-tools-test:
	@sh scripts/tests/benchmark-tools-test.sh

.PHONY: benchmark-discover
benchmark-discover:
	@bash scripts/benchmark-runtime.sh --discover

.PHONY: raycast-install
raycast-install:
	@npm --prefix raycast install

.PHONY: raycast-build
raycast-build:
	@npm --prefix raycast run lint
	@npm --prefix raycast run build

.PHONY: benchmark
benchmark:
	@bash scripts/benchmark-runtime.sh

# Prevent Foundation's Pipe() from being used when passing fds to Apple Container
# APIs (createProcess/bootstrap). Apple closes those fds immediately after duping
# them into the container, causing Pipe.deinit to double-close a reused fd and
# corrupt NIO's fd table (writev/kevent EBADF crash). Use StdioPipes instead.
.PHONY: lint-pipes
lint-pipes:
	@bash scripts/lint-pipes.sh

.PHONY: fmt
fmt:	swift-fmt

.PHONY: swift-fmt
SWIFT_SRC = $(shell find . -type f -name '*.swift' -not -path "*/.*" -not -path "*.pb.swift" -not -path "*.grpc.swift" -not -path "*/checkouts/*")
swift-fmt:
	@echo Applying the standard code formatting...
	@$(SWIFT) format --recursive --configuration .swift-format -i $(SWIFT_SRC)

# Installer targets - delegated to pkginstaller subdirectory
.PHONY: guest-image
guest-image:
	@$(MAKE) -C Guest VERSION="$(BUILD_VERSION)" image

.PHONY: vmm
vmm:
	@$(MAKE) -C VMM all

.PHONY: installer
installer: release guest-image vmm
	@$(MAKE) -C pkginstaller BUILD_VERSION="$(BUILD_VERSION)" pkginstaller

.PHONY: installer-signed
installer-signed: release guest-image vmm
	@$(MAKE) -C pkginstaller BUILD_VERSION="$(BUILD_VERSION)" installer-signed

.PHONY: installer-notarized
installer-notarized: release guest-image vmm
	@$(MAKE) -C pkginstaller BUILD_VERSION="$(BUILD_VERSION)" installer-notarized

.PHONY: release-artifacts
release-artifacts: release guest-image vmm
	@$(MAKE) -C pkginstaller BUILD_VERSION="$(BUILD_VERSION)" release-artifacts

.PHONY: release-artifacts-local
release-artifacts-local: release guest-image vmm
	@$(MAKE) -C pkginstaller BUILD_VERSION="$(BUILD_VERSION)" verify

.PHONY: installer-test
installer-test:
	@$(MAKE) -C pkginstaller test

.PHONY: release-tools-test
release-tools-test:
	@sh scripts/tests/release-tools-test.sh

.PHONY: shellcheck
shellcheck:
	@shellcheck scripts/benchmark-tools.sh scripts/release/*.sh scripts/tests/benchmark-tools-test.sh scripts/tests/release-tools-test.sh \
		pkginstaller/tests/*.sh VMM/scripts/*.sh
	@shellcheck -x Guest/scripts/*.sh
	@shellcheck -s bash pkginstaller/Resources/glassdock.in \
		pkginstaller/Resources/glassdock-uninstall.in
	@shellcheck -s sh pkginstaller/Resources/scripts/*.in

.PHONY: actionlint
actionlint:
	@go run github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION)

.PHONY: installer-help
installer-help:
	@$(MAKE) -C pkginstaller help

.PHONY: installer-clean
installer-clean:
	@$(MAKE) -C pkginstaller clean

.PHONY: clean
clean: installer-clean
	@echo Cleaning the build files...
	@$(SWIFT) package clean
