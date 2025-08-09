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

.PHONY: clean
clean:
	@echo Cleaning the build files...
	@rm -rf bin/ libexec/
	@$(SWIFT) package clean