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

SWIFT := "swift"
DESTDIR ?= /usr/local/
ROOT_DIR := $(shell git rev-parse --show-toplevel)

MACOS_VERSION := $(shell sw_vers -productVersion)
MACOS_MAJOR := $(shell echo $(MACOS_VERSION) | cut -d. -f1)
# Build information - only shows real version if exactly on a tagged commit
export BUILD_VERSION := $(shell git describe --tags --exact-match HEAD 2>/dev/null || echo "0.0.0-dev")
export BUILD_GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
export BUILD_TIME := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
# Build information - docker engine API versions
export DOCKER_ENGINE_API_MIN_VERSION := v1.32
export DOCKER_ENGINE_API_MAX_VERSION := v1.51

SUDO ?= sudo
.DEFAULT_GOAL := all

.PHONY: all
all: socktainer

.PHONY: build
build:
	@echo Building socktainer binary...
	@$(SWIFT) build -c $(BUILD_CONFIGURATION)

.PHONY: socktainer
socktainer: build 

.PHONY: release
release: BUILD_CONFIGURATION = release
release: all

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
	@echo "  all              - Build socktainer (default)"
	@echo "  build            - Build in debug mode"
	@echo "  release          - Build in release mode"
	@echo "  test             - Run tests"
	@echo "  fmt              - Format source code"
	@echo "  clean            - Clean build artifacts"
	@echo "  version          - Show version information"
	@echo "  installer        - Build unsigned macOS .pkg installer"
	@echo "  installer-signed - Build signed macOS .pkg installer"
	@echo "  installer-notarized - Build signed and notarized .pkg installer"
	@echo "  installer-help   - Show detailed installer help"
	@echo "  help             - Show this help message"

.PHONY: test
test:
	@$(SWIFT) test -c $(BUILD_CONFIGURATION)

.PHONY: fmt
fmt:	swift-fmt

.PHONY: swift-fmt
SWIFT_SRC = $(shell find . -type f -name '*.swift' -not -path "*/.*" -not -path "*.pb.swift" -not -path "*.grpc.swift" -not -path "*/checkouts/*")
swift-fmt:
	@echo Applying the standard code formatting...
	@$(SWIFT) format --recursive --configuration .swift-format -i $(SWIFT_SRC)

# Installer targets - delegated to pkginstaller subdirectory
.PHONY: installer
installer: release
	@$(MAKE) -C pkginstaller BUILD_VERSION="$(BUILD_VERSION)" pkginstaller

.PHONY: installer-signed
installer-signed: release
	@$(MAKE) -C pkginstaller BUILD_VERSION="$(BUILD_VERSION)" installer-signed

.PHONY: installer-notarized
installer-notarized: release
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
