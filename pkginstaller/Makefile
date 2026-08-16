# Build the complete Glass Dock macOS runtime package and archive.
SHELL := /bin/bash

BUILD_VERSION ?= 0.0.0-dev
SOURCE_DATE_EPOCH ?= $(shell git -C .. log -1 --format=%ct 2>/dev/null || echo 0)
ARTIFACT_BASENAME := glassdock-$(BUILD_VERSION)-macos-arm64
PKG_NAME ?= $(ARTIFACT_BASENAME).pkg
ARCHIVE_NAME ?= $(ARTIFACT_BASENAME).tar.gz
CHECKSUM_NAME ?= SHA256SUMS
METADATA_NAME ?= BUILD-METADATA.txt

INSTALL_PREFIX ?= /opt/glassdock
PACKAGE_IDENTIFIER ?= io.github.glassdock.pkg
SERVICE_LABEL ?= io.github.glassdock.daemon
PATHS_D_NAME ?= glassdock
INSTALL_PATHS_D ?= 1

DAEMON_SOURCE ?= ../.build/release/glassdock
VMM_SOURCE_DIR ?= ../VMM/out
GUEST_SOURCE_DIR ?= ../Guest/out
CODESIGN_IDENTITY ?=
INSTALLER_SIGNING_IDENTITY ?=
CODESIGN_REQUIRED ?= 0

BUILD_DIR := build
PACKAGE_ROOT := $(BUILD_DIR)/root
VERSION_ROOT := $(PACKAGE_ROOT)$(INSTALL_PREFIX)/versions/$(BUILD_VERSION)
PRIVATE_BIN := $(VERSION_ROOT)/libexec/glassdock
PUBLIC_BIN := $(VERSION_ROOT)/bin
SHARE_DIR := $(VERSION_ROOT)/share/glassdock
RESOURCES_DIR := $(BUILD_DIR)/Resources
SCRIPTS_DIR := $(BUILD_DIR)/scripts
ARCHIVE_DIR := $(BUILD_DIR)/archive
OUT_DIR := out

.DEFAULT_GOAL := pkginstaller

.PHONY: validate-config
validate-config:
	@../scripts/release/validate-version.sh "$(BUILD_VERSION)"
	@case "$(INSTALL_PREFIX)" in /opt/*) ;; *) echo "INSTALL_PREFIX must be a child of /opt" >&2; exit 1 ;; esac
	@case "$(INSTALL_PREFIX)" in \
		*//*|*/|*/.|*/..|*/./*|*/../*) echo "INSTALL_PREFIX contains an unsafe path component" >&2; exit 1 ;; \
		*) ;; \
	esac
	@printf '%s' "$(INSTALL_PREFIX)" | grep -Eq '^/opt/[A-Za-z0-9._/-]+$$' \
		|| { echo "INSTALL_PREFIX contains unsafe characters" >&2; exit 1; }
	@printf '%s' "$(PACKAGE_IDENTIFIER)" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$$' \
		|| { echo "invalid PACKAGE_IDENTIFIER" >&2; exit 1; }
	@printf '%s' "$(SERVICE_LABEL)" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$$' \
		|| { echo "invalid SERVICE_LABEL" >&2; exit 1; }
	@printf '%s' "$(PATHS_D_NAME)" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$$' \
		|| { echo "invalid PATHS_D_NAME" >&2; exit 1; }
	@case "$(INSTALL_PATHS_D)" in 0|1) ;; *) echo "INSTALL_PATHS_D must be 0 or 1" >&2; exit 1 ;; esac

.PHONY: prepare-root
prepare-root: validate-config
	@rm -rf "$(PACKAGE_ROOT)" "$(RESOURCES_DIR)" "$(SCRIPTS_DIR)" "$(ARCHIVE_DIR)"
	@mkdir -p "$(PRIVATE_BIN)" "$(PUBLIC_BIN)" "$(SHARE_DIR)" \
		"$(RESOURCES_DIR)" "$(SCRIPTS_DIR)" "$(ARCHIVE_DIR)" "$(OUT_DIR)"

.PHONY: copy-runtime
copy-runtime: prepare-root
	@for artifact in \
		"$(DAEMON_SOURCE)" \
		"$(VMM_SOURCE_DIR)/glassdock-vmm" \
		"$(VMM_SOURCE_DIR)/libkrun.1.dylib" \
		"$(VMM_SOURCE_DIR)/gvproxy" \
		"$(GUEST_SOURCE_DIR)/glassdock-vmlinux" \
		"$(GUEST_SOURCE_DIR)/glassdock-root.ext4"; do \
		[ -f "$$artifact" ] || { echo "runtime artifact not found: $$artifact" >&2; exit 1; }; \
	done
	@COPYFILE_DISABLE=1 cp -X "$(DAEMON_SOURCE)" "$(PRIVATE_BIN)/glassdock"
	@COPYFILE_DISABLE=1 cp -X "$(VMM_SOURCE_DIR)/glassdock-vmm" "$(VMM_SOURCE_DIR)/libkrun.1.dylib" \
		"$(VMM_SOURCE_DIR)/gvproxy" "$(PRIVATE_BIN)/"
	@COPYFILE_DISABLE=1 cp -X "$(GUEST_SOURCE_DIR)/glassdock-vmlinux" "$(GUEST_SOURCE_DIR)/glassdock-root.ext4" \
		"$(SHARE_DIR)/"
	@COPYFILE_DISABLE=1 cp -X ../LICENSE "$(VERSION_ROOT)/LICENSE"
	@sed -e 's|__SERVICE_LABEL__|$(SERVICE_LABEL)|g' \
		Resources/glassdock.in > "$(PUBLIC_BIN)/glassdock"
	@sed -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' \
		-e 's|__PACKAGE_IDENTIFIER__|$(PACKAGE_IDENTIFIER)|g' \
		-e 's|__PATHS_D_NAME__|$(PATHS_D_NAME)|g' \
		-e 's|__SERVICE_LABEL__|$(SERVICE_LABEL)|g' \
		Resources/glassdock-uninstall.in > "$(PUBLIC_BIN)/glassdock-uninstall"
	@sed -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' \
		-e 's|__SERVICE_LABEL__|$(SERVICE_LABEL)|g' \
		Resources/LaunchAgent.plist.in > "$(SHARE_DIR)/$(SERVICE_LABEL).plist"
	@chmod 0755 "$(PUBLIC_BIN)/glassdock" "$(PUBLIC_BIN)/glassdock-uninstall" \
		"$(PRIVATE_BIN)/glassdock" "$(PRIVATE_BIN)/glassdock-vmm" "$(PRIVATE_BIN)/gvproxy"
	@chmod 0644 "$(PRIVATE_BIN)/libkrun.1.dylib" "$(SHARE_DIR)/glassdock-vmlinux" \
		"$(SHARE_DIR)/glassdock-root.ext4" "$(SHARE_DIR)/$(SERVICE_LABEL).plist" \
		"$(VERSION_ROOT)/LICENSE"

.PHONY: sign-runtime
sign-runtime: copy-runtime
	@if [ "$(CODESIGN_REQUIRED)" = "1" ]; then \
		test -n "$(CODESIGN_IDENTITY)" || { echo "CODESIGN_IDENTITY is required" >&2; exit 1; }; \
		test -n "$(INSTALLER_SIGNING_IDENTITY)" || { echo "INSTALLER_SIGNING_IDENTITY is required" >&2; exit 1; }; \
	fi
	@if [ -n "$(CODESIGN_IDENTITY)" ]; then \
		echo "Signing runtime code"; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" --options runtime --timestamp \
			--identifier io.github.glassdock.libkrun "$(PRIVATE_BIN)/libkrun.1.dylib"; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" --options runtime --timestamp \
			--identifier io.github.glassdock.gvproxy "$(PRIVATE_BIN)/gvproxy"; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" --options runtime --timestamp \
			--identifier io.github.glassdock.vmm --entitlements ../VMM/helper/entitlements.plist \
			"$(PRIVATE_BIN)/glassdock-vmm"; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" --options runtime --timestamp \
			--identifier io.github.glassdock.daemon "$(PRIVATE_BIN)/glassdock"; \
		for artifact in libkrun.1.dylib gvproxy glassdock-vmm glassdock; do \
			codesign --verify --strict --verbose=2 "$(PRIVATE_BIN)/$$artifact"; \
		done; \
	fi

$(BUILD_DIR)/Distribution: Resources/Distribution.in | $(BUILD_DIR)
	@sed -e 's|__VERSION__|$(BUILD_VERSION)|g' \
		-e 's|__PACKAGE_IDENTIFIER__|$(PACKAGE_IDENTIFIER)|g' \
		$< > $@

$(RESOURCES_DIR)/welcome.html: Resources/welcome.html.in | $(RESOURCES_DIR)
	@sed -e 's|__VERSION__|$(BUILD_VERSION)|g' $< > $@

$(RESOURCES_DIR)/conclusion.html: Resources/conclusion.html.in | $(RESOURCES_DIR)
	@sed -e 's|__VERSION__|$(BUILD_VERSION)|g' $< > $@

$(SCRIPTS_DIR)/preinstall: Resources/scripts/preinstall.in | $(SCRIPTS_DIR)
	@sed -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' $< > $@
	@chmod 0755 $@

$(SCRIPTS_DIR)/postinstall: Resources/scripts/postinstall.in | $(SCRIPTS_DIR)
	@sed -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' \
		-e 's|__VERSION__|$(BUILD_VERSION)|g' \
		-e 's|__PATHS_D_NAME__|$(PATHS_D_NAME)|g' \
		-e 's|__INSTALL_PATHS_D__|$(INSTALL_PATHS_D)|g' $< > $@
	@chmod 0755 $@

$(BUILD_DIR) $(RESOURCES_DIR) $(SCRIPTS_DIR):
	@mkdir -p $@

.PHONY: component-pkg
component-pkg: sign-runtime $(SCRIPTS_DIR)/preinstall $(SCRIPTS_DIR)/postinstall
	@COPYFILE_DISABLE=1 pkgbuild --root "$(PACKAGE_ROOT)" \
		--component-plist Resources/components.plist \
		--identifier "$(PACKAGE_IDENTIFIER)" \
		--version "$(BUILD_VERSION)" \
		--install-location / \
		--scripts "$(SCRIPTS_DIR)" \
		--ownership recommended \
		"$(OUT_DIR)/glassdock.pkg"

.PHONY: product-pkg
product-pkg: component-pkg $(BUILD_DIR)/Distribution $(RESOURCES_DIR)/welcome.html $(RESOURCES_DIR)/conclusion.html
	@COPYFILE_DISABLE=1 productbuild --distribution "$(BUILD_DIR)/Distribution" \
		--resources "$(RESOURCES_DIR)" \
		--package-path "$(OUT_DIR)" \
		"$(OUT_DIR)/glassdock-unsigned.pkg"

.PHONY: pkginstaller
pkginstaller: product-pkg
	@if [ -n "$(INSTALLER_SIGNING_IDENTITY)" ]; then \
		productsign --timestamp --sign "$(INSTALLER_SIGNING_IDENTITY)" \
			"$(OUT_DIR)/glassdock-unsigned.pkg" "$(OUT_DIR)/$(PKG_NAME)"; \
		rm -f "$(OUT_DIR)/glassdock-unsigned.pkg"; \
	else \
		mv "$(OUT_DIR)/glassdock-unsigned.pkg" "$(OUT_DIR)/$(PKG_NAME)"; \
	fi
	@rm -f "$(OUT_DIR)/glassdock.pkg"
	@echo "Created $(OUT_DIR)/$(PKG_NAME)"

.PHONY: installer-signed
installer-signed: CODESIGN_REQUIRED := 1
installer-signed: pkginstaller

.PHONY: installer-notarized
installer-notarized: installer-signed
	@../scripts/release/notarize.sh "$(OUT_DIR)/$(PKG_NAME)"

.PHONY: archive
archive: sign-runtime
	@archive_root="$(ARCHIVE_DIR)/$(ARTIFACT_BASENAME)"; \
		rm -rf "$$archive_root"; \
		mkdir -p "$$archive_root"; \
		COPYFILE_DISABLE=1 cp -RX "$(VERSION_ROOT)/." "$$archive_root/"; \
		timestamp=$$(../scripts/release/build-time.sh "$(SOURCE_DATE_EPOCH)" | \
			sed -E 's/[-:]//g; s/T([0-9]{4})([0-9]{2})Z/\1.\2/'); \
		find "$$archive_root" -exec touch -h -t "$$timestamp" {} +; \
		(cd "$(ARCHIVE_DIR)" && find "$(ARTIFACT_BASENAME)" -print | LC_ALL=C sort | \
			COPYFILE_DISABLE=1 tar -n -cf - -T -) | gzip -n > "$(OUT_DIR)/$(ARCHIVE_NAME)"
	@echo "Created $(OUT_DIR)/$(ARCHIVE_NAME)"

.PHONY: checksums
checksums: pkginstaller archive
	@$(MAKE) metadata
	@$(MAKE) write-checksums

.PHONY: metadata
metadata:
	@SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" ../scripts/release/build-metadata.sh \
		"$(BUILD_VERSION)" "$${BUILD_GIT_COMMIT:-$$(git -C .. rev-parse HEAD)}" \
		"$(OUT_DIR)/$(METADATA_NAME)" "$(OUT_DIR)/$(PKG_NAME)" "$(OUT_DIR)/$(ARCHIVE_NAME)"

.PHONY: write-checksums
write-checksums:
	@(cd "$(OUT_DIR)" && shasum -a 256 "$(PKG_NAME)" "$(ARCHIVE_NAME)" "$(METADATA_NAME)" > "$(CHECKSUM_NAME)")

.PHONY: verify
verify: checksums
	@../scripts/release/verify-artifacts.sh \
		"$(OUT_DIR)/$(PKG_NAME)" "$(OUT_DIR)/$(ARCHIVE_NAME)" "$(OUT_DIR)/$(CHECKSUM_NAME)"

.PHONY: release-artifacts
release-artifacts: CODESIGN_REQUIRED := 1
release-artifacts: installer-notarized archive
	@$(MAKE) metadata
	@$(MAKE) write-checksums
	@../scripts/release/verify-artifacts.sh --require-signature --require-notarization \
		"$(OUT_DIR)/$(PKG_NAME)" "$(OUT_DIR)/$(ARCHIVE_NAME)" "$(OUT_DIR)/$(CHECKSUM_NAME)"

.PHONY: test
test:
	@sh tests/package-smoke.sh

.PHONY: clean
clean:
	@rm -rf "$(BUILD_DIR)" "$(OUT_DIR)"

.PHONY: help
help:
	@echo "Glass Dock release packaging"
	@echo "  pkginstaller         Build an unsigned package"
	@echo "  installer-signed     Sign runtime code and the package"
	@echo "  installer-notarized  Sign, notarize, and staple the package"
	@echo "  archive              Build the complete arm64 runtime archive"
	@echo "  checksums            Build SHA256SUMS after final artifacts"
	@echo "  release-artifacts    Build and verify distributable artifacts"
	@echo "  test                 Build and inspect fixture artifacts"
