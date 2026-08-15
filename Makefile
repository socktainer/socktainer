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
TEST_PARALLELISM ?= $(shell sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu)
TEST_SWIFT_FLAGS ?= --disable-index-store

SWIFT := "swift"
DESTDIR ?= /usr/local/
ROOT_DIR := $(shell git rev-parse --show-toplevel)

MACOS_VERSION := $(shell sw_vers -productVersion)
MACOS_MAJOR := $(shell echo $(MACOS_VERSION) | cut -d. -f1)
# Build information - only shows real version if exactly on a tagged commit
export BUILD_VERSION := $(shell git describe --tags --exact-match HEAD 2>/dev/null || echo "0.0.0-dev")
export BUILD_GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
# Keep debug and test manifests stable so local rebuilds can reuse BuildInfo.
# Release builds override this with the actual build timestamp below.
export BUILD_TIME ?= development
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
release: BUILD_TIME = $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
release: all
	@codesign --force --sign - --entitlements entitlements.plist .build/release/glassdock

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
	@echo "  all              - Build glassdock (default)"
	@echo "  build            - Build in debug mode"
	@echo "  release          - Build in release mode"
	@echo "  test             - Run tests"
	@echo "  integration      - Run live Docker lifecycle integration tests"
	@echo "  benchmark-preflight - Validate runtime benchmark configuration"
	@echo "  benchmark-discover - Report known runtime availability"
	@echo "  benchmark-test   - Test benchmark scheduling, statistics, and parsers"
	@echo "  benchmark        - Run the configured runtime benchmark matrix"
	@echo "  fmt              - Format source code"
	@echo "  clean            - Clean build artifacts"
	@echo "  version          - Show version information"
	@echo "  installer        - Build unsigned macOS .pkg installer"
	@echo "  installer-signed - Build signed macOS .pkg installer"
	@echo "  installer-notarized - Build signed and notarized .pkg installer"
	@echo "  installer-help   - Show detailed installer help"
	@echo "  help             - Show this help message"

.PHONY: test
test: lint-pipes benchmark-test
	@$(SWIFT) test -c $(BUILD_CONFIGURATION) $(TEST_SWIFT_FLAGS) \
		--experimental-maximum-parallelization-width $(TEST_PARALLELISM)

.PHONY: integration
integration:
	@bash scripts/integration-runtime.sh

.PHONY: benchmark-preflight
benchmark-preflight:
	@bash scripts/benchmark-runtime.sh --preflight

.PHONY: benchmark-discover
benchmark-discover:
	@bash scripts/benchmark-runtime.sh --discover

.PHONY: benchmark-test
benchmark-test:
	@bash scripts/tests/benchmark-runtime-parser-test.sh

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
	@$(MAKE) -C Guest image

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

.PHONY: installer-help
installer-help:
	@$(MAKE) -C pkginstaller help

.PHONY: installer-clean
installer-clean:
	@$(MAKE) -C pkginstaller clean

.PHONY: clean
clean: installer-clean
	@echo Cleaning the build files...
	@rm -rf bin/ libexec/
	@$(SWIFT) package clean
