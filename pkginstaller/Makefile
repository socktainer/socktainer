# Makefile for building the Socktainer macOS package installer
SHELL := bash

# Configuration variables
BUILD_VERSION ?= 0.0.0-dev
PKG_NAME := socktainer-installer.pkg
APPLE_APPLICATION_ID ?= -
APPLE_PRODUCT_ID ?= mock
NO_CODESIGN ?= 1
NO_NOTARIZE ?= 1
NOTARIZE_USERNAME ?=
NOTARIZE_PASSWORD ?=
NOTARIZE_TEAM ?=
INSTALL_PREFIX ?= /opt/socktainer

# Directory structure
BUILD_DIR := build
PACKAGE_ROOT := $(BUILD_DIR)/root
RESOURCES_DIR := $(BUILD_DIR)/Resources
SCRIPTS_DIR := $(BUILD_DIR)/scripts
OUT_DIR := out
TMP_DIR := tmp

.PHONY: default
default: pkginstaller

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(RESOURCES_DIR): | $(BUILD_DIR)
	@mkdir -p $(RESOURCES_DIR)

$(SCRIPTS_DIR): | $(BUILD_DIR)
	@mkdir -p $(SCRIPTS_DIR)

.PHONY: setup
setup: $(BUILD_DIR) $(RESOURCES_DIR) $(SCRIPTS_DIR)
	@echo "Setting up installer directory structure..."
	@mkdir -p $(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin
	@mkdir -p $(OUT_DIR)
	@mkdir -p $(TMP_DIR)

.PHONY: resources
resources: setup $(BUILD_DIR)/Distribution $(RESOURCES_DIR)/welcome.html $(RESOURCES_DIR)/conclusion.html

$(BUILD_DIR)/Distribution: Resources/Distribution.in | $(BUILD_DIR)
	@echo "Generating Distribution file..."
	@sed -e 's|__VERSION__|$(BUILD_VERSION)|g' \
	     -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' $< > $@
	@echo "Generated Distribution file (size: $$(wc -c < $@) bytes)"

$(RESOURCES_DIR)/welcome.html: Resources/welcome.html.in | $(RESOURCES_DIR)
	@echo "Generating welcome.html..."
	@sed -e 's|__VERSION__|$(BUILD_VERSION)|g' \
	     -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' $< > $@

$(RESOURCES_DIR)/conclusion.html: Resources/conclusion.html.in | $(RESOURCES_DIR)
	@echo "Generating conclusion.html..."
	@sed -e 's|__VERSION__|$(BUILD_VERSION)|g' \
	     -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' $< > $@

.PHONY: scripts
scripts: setup $(SCRIPTS_DIR)/preinstall $(SCRIPTS_DIR)/postinstall

$(SCRIPTS_DIR)/preinstall: Resources/scripts/preinstall.in | $(SCRIPTS_DIR)
	@echo "Generating preinstall script..."
	@sed -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' $< > $@
	@chmod +x $@

$(SCRIPTS_DIR)/postinstall: Resources/scripts/postinstall.in | $(SCRIPTS_DIR)
	@echo "Generating postinstall script..."
	@sed -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' $< > $@
	@chmod +x $@

.PHONY: copy-binary
copy-binary: setup
	@echo "Copying socktainer binary..."
	@if [ ! -f "../.build/release/socktainer" ]; then \
		echo "Error: socktainer binary not found. Run 'make release' in the parent directory first."; \
		exit 1; \
	fi
	@cp ../.build/release/socktainer $(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/
	@chmod +x $(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/socktainer

.PHONY: sign-binary
sign-binary: copy-binary
	@if [ "$(NO_CODESIGN)" != "1" ] && [ "$(APPLE_APPLICATION_ID)" != "-" ]; then \
		echo "Signing binary..."; \
		codesign --sign "$(APPLE_APPLICATION_ID)" --options runtime --timestamp --force \
			$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/socktainer; \
	fi

.PHONY: component-pkg
component-pkg: sign-binary scripts
	@echo "Creating component package..."
	@pkgbuild --root $(PACKAGE_ROOT) \
		--identifier com.socktainer.socktainer \
		--version $(BUILD_VERSION) \
		--install-location / \
		--scripts $(SCRIPTS_DIR) \
		--ownership preserve \
		$(OUT_DIR)/socktainer.pkg

.PHONY: product-pkg
product-pkg: component-pkg resources
	@echo "Creating distribution package..."
	@productbuild --distribution $(BUILD_DIR)/Distribution \
		--resources $(RESOURCES_DIR) \
		--package-path $(OUT_DIR) \
		$(OUT_DIR)/socktainer-unsigned.pkg

.PHONY: sign-pkg
sign-pkg: product-pkg
	@if [ "$(NO_CODESIGN)" = "1" ]; then \
		mv $(OUT_DIR)/socktainer-unsigned.pkg $(OUT_DIR)/$(PKG_NAME); \
		echo "✅ Unsigned installer created: $(OUT_DIR)/$(PKG_NAME)"; \
	else \
		echo "Signing installer package..."; \
		productsign --timestamp --sign "$(APPLE_PRODUCT_ID)" \
			$(OUT_DIR)/socktainer-unsigned.pkg \
			$(OUT_DIR)/$(PKG_NAME); \
		rm $(OUT_DIR)/socktainer-unsigned.pkg; \
		echo "✅ Signed installer created: $(OUT_DIR)/$(PKG_NAME)"; \
	fi
	@rm -f $(OUT_DIR)/socktainer.pkg

# Notarize the signed package
.PHONY: notarize
notarize: sign-pkg
	@if [ -z "$(APPLE_ID)" ] || [ -z "$(APPLE_ID_PASSWORD)" ] || [ -z "$(APPLE_TEAM_ID)" ]; then \
		echo "❌ Missing notarization credentials. Set APPLE_ID, APPLE_ID_PASSWORD, and APPLE_TEAM_ID"; \
		exit 1; \
	fi
	@echo "Submitting installer for notarization..."
	@xcrun notarytool submit $(OUT_DIR)/$(PKG_NAME) \
		--apple-id "$(APPLE_ID)" \
		--password "$(APPLE_ID_PASSWORD)" \
		--team-id "$(APPLE_TEAM_ID)" \
		--wait
	@echo "Stapling notarization ticket..."
	@xcrun stapler staple $(OUT_DIR)/$(PKG_NAME)
	@echo "✅ Installer notarized and stapled: $(OUT_DIR)/$(PKG_NAME)"

.PHONY: pkginstaller
pkginstaller: sign-pkg

.PHONY: installer-signed
installer-signed: NO_CODESIGN = 0
installer-signed: pkginstaller

.PHONY: installer-notarized
installer-notarized: NO_CODESIGN = 0
installer-notarized: notarize

.PHONY: help
help:
	@echo "Socktainer macOS Package Installer"
	@echo ""
	@echo "Targets:"
	@echo "  pkginstaller       - Build unsigned .pkg installer (default)"
	@echo "  installer-signed   - Build signed .pkg installer"
	@echo "  installer-notarized - Build signed and notarized .pkg installer"
	@echo "  notarize           - Notarize existing signed installer"
	@echo "  setup              - Create directory structure"
	@echo "  clean              - Clean all generated files"
	@echo "  clean-legacy       - Clean legacy files from old build system"
	@echo "  help               - Show this help message"
	@echo ""
	@echo "Configuration:"
	@echo "  BUILD_VERSION=x.x.x       - Version string (default: $(BUILD_VERSION))"
	@echo "  NO_CODESIGN=1             - Skip code signing (default)"
	@echo "  APPLE_APPLICATION_ID=<id>    - Code signing identity"
	@echo "  APPLE_PRODUCT_ID=<id> - Product signing identity"
	@echo "  APPLE_ID=<email> - Apple ID for notarization"
	@echo "  APPLE_ID_PASSWORD=<pass>  - App-specific password for notarization"
	@echo "  APPLE_TEAM_ID=<team_id>   - Team ID for notarization"
	@echo "  INSTALL_PREFIX=/path      - Installation prefix (default: $(INSTALL_PREFIX))"
	@echo ""
	@echo "Example signed build:"
	@echo "  make APPLE_APPLICATION_ID='Developer ID Application: Your Name' \\"
	@echo "       APPLE_PRODUCT_ID='Developer ID Installer: Your Name' \\"
	@echo "       NO_CODESIGN=0 pkginstaller"
	@echo ""
	@echo "Example notarized build:"
	@echo "  make APPLE_APPLICATION_ID='Developer ID Application: Your Name' \\"
	@echo "       APPLE_PRODUCT_ID='Developer ID Installer: Your Name' \\"
	@echo "       APPLE_ID='your@email.com' \\"
	@echo "       APPLE_ID_PASSWORD='app-specific-password' \\"
	@echo "       APPLE_TEAM_ID='TEAM123ID' \\"
	@echo "       installer-notarized"
	@echo ""
	@echo "Prerequisites:"
	@echo "  - Run 'make release' in the parent directory to build the binary"
	@echo "  - Ensure Xcode command line tools are installed"
	@echo "  - For notarization: Apple Developer account with app-specific password"

.PHONY: clean-legacy
clean-legacy:
	@echo "Cleaning legacy files from old build system..."
	@rm -f Distribution welcome.html conclusion.html
	@rm -rf Resources root tmp
	@rm -f scripts/preinstall scripts/postinstall
	@echo "Legacy files cleaned. Only source templates (.in files) remain."

.PHONY: clean
clean: clean-legacy
	@echo "Cleaning installer build files..."
	@rm -rf $(BUILD_DIR) $(OUT_DIR) $(TMP_DIR)

