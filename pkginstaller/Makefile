# Makefile for building the Glass Dock macOS package installer
SHELL := bash

# Configuration variables
BUILD_VERSION ?= 0.0.0-dev
PKG_NAME ?= glassdock-installer.pkg
APPLE_APPLICATION_ID ?= -
APPLE_PRODUCT_ID ?= mock
NO_CODESIGN ?= 1
NO_NOTARIZE ?= 1
NOTARIZE_USERNAME ?=
NOTARIZE_PASSWORD ?=
NOTARIZE_TEAM ?=
INSTALL_PREFIX ?= /opt/glassdock
PACKAGE_IDENTIFIER ?= io.github.glassdock
PATHS_D_NAME ?= glassdock
INSTALL_PATHS_D ?= 1
SIGNING_KEYCHAIN ?=

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
setup: validate-config $(BUILD_DIR) $(RESOURCES_DIR) $(SCRIPTS_DIR)
	@echo "Setting up installer directory structure..."
	@mkdir -p $(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin
	@mkdir -p $(PACKAGE_ROOT)$(INSTALL_PREFIX)/share/glassdock
	@mkdir -p $(OUT_DIR)
	@mkdir -p $(TMP_DIR)

.PHONY: validate-config
validate-config:
	@case "$(INSTALL_PREFIX)" in /opt/*) ;; *) echo "Error: INSTALL_PREFIX must be a child of /opt"; exit 1 ;; esac
	@case "$(INSTALL_PREFIX)" in \
		*//*|*/|*/.|*/..|*/./*|*/../*) echo "Error: INSTALL_PREFIX contains an unsafe path component"; exit 1 ;; \
		*) ;; \
	esac
	@printf '%s' "$(INSTALL_PREFIX)" | grep -Eq '^/opt/[A-Za-z0-9._/-]+$$' \
		|| { echo "Error: INSTALL_PREFIX contains unsafe characters"; exit 1; }
	@printf '%s' "$(PACKAGE_IDENTIFIER)" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$$' \
		|| { echo "Error: invalid PACKAGE_IDENTIFIER"; exit 1; }
	@printf '%s' "$(PATHS_D_NAME)" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$$' \
		|| { echo "Error: invalid PATHS_D_NAME"; exit 1; }
	@case "$(INSTALL_PATHS_D)" in 0|1) ;; *) echo "Error: INSTALL_PATHS_D must be 0 or 1"; exit 1 ;; esac

.PHONY: resources
resources: setup $(BUILD_DIR)/Distribution $(RESOURCES_DIR)/welcome.html $(RESOURCES_DIR)/conclusion.html

$(BUILD_DIR)/Distribution: Resources/Distribution.in FORCE | $(BUILD_DIR)
	@echo "Generating Distribution file..."
	@sed -e 's|__VERSION__|$(BUILD_VERSION)|g' \
	     -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' \
	     -e 's|__PACKAGE_IDENTIFIER__|$(PACKAGE_IDENTIFIER)|g' $< > $@
	@echo "Generated Distribution file (size: $$(wc -c < $@) bytes)"

$(RESOURCES_DIR)/welcome.html: Resources/welcome.html.in FORCE | $(RESOURCES_DIR)
	@echo "Generating welcome.html..."
	@sed -e 's|__VERSION__|$(BUILD_VERSION)|g' \
	     -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' $< > $@

$(RESOURCES_DIR)/conclusion.html: Resources/conclusion.html.in FORCE | $(RESOURCES_DIR)
	@echo "Generating conclusion.html..."
	@sed -e 's|__VERSION__|$(BUILD_VERSION)|g' \
	     -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' $< > $@

.PHONY: scripts
scripts: setup $(SCRIPTS_DIR)/preinstall $(SCRIPTS_DIR)/postinstall

$(SCRIPTS_DIR)/preinstall: Resources/scripts/preinstall.in FORCE | $(SCRIPTS_DIR)
	@echo "Generating preinstall script..."
	@sed -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' \
	     -e 's|__PATHS_D_NAME__|$(PATHS_D_NAME)|g' \
	     -e 's|__INSTALL_PATHS_D__|$(INSTALL_PATHS_D)|g' $< > $@
	@chmod +x $@

$(SCRIPTS_DIR)/postinstall: Resources/scripts/postinstall.in FORCE | $(SCRIPTS_DIR)
	@echo "Generating postinstall script..."
	@sed -e 's|__INSTALL_PREFIX__|$(INSTALL_PREFIX)|g' \
	     -e 's|__VERSION__|$(BUILD_VERSION)|g' \
	     -e 's|__PATHS_D_NAME__|$(PATHS_D_NAME)|g' \
	     -e 's|__INSTALL_PATHS_D__|$(INSTALL_PATHS_D)|g' $< > $@
	@chmod +x $@

.PHONY: prepare-root
prepare-root: setup
	@rm -rf "$(PACKAGE_ROOT)"
	@mkdir -p "$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin"
	@mkdir -p "$(PACKAGE_ROOT)$(INSTALL_PREFIX)/share/glassdock"

.PHONY: copy-binary
copy-binary: prepare-root
	@echo "Copying glassdock binary..."
	@if [ ! -f "../.build/release/glassdock" ]; then \
		echo "Error: glassdock binary not found. Run 'make release' in the parent directory first."; \
		exit 1; \
	fi
	@cp ../.build/release/glassdock "$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/"
	@chmod +x "$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/glassdock"
	@for artifact in \
		../VMM/out/glassdock-vmm \
		../VMM/out/libkrun.1.dylib \
		../VMM/out/gvproxy \
		../Guest/out/glassdock-vmlinux \
		../Guest/out/glassdock-root.ext4; do \
		if [ ! -f "$$artifact" ]; then \
			echo "Error: runtime artifact not found: $$artifact"; \
			exit 1; \
		fi; \
	done
	@cp ../VMM/out/glassdock-vmm ../VMM/out/libkrun.1.dylib ../VMM/out/gvproxy \
		"$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/"
	@chmod +x \
		"$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/glassdock-vmm" \
		"$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/gvproxy"
	@cp ../Guest/out/glassdock-vmlinux ../Guest/out/glassdock-root.ext4 \
		"$(PACKAGE_ROOT)$(INSTALL_PREFIX)/share/glassdock/"
	@xattr -cr "$(PACKAGE_ROOT)$(INSTALL_PREFIX)"

.PHONY: sign-binary
sign-binary: copy-binary
	@if [ "$(NO_CODESIGN)" != "1" ] && [ "$(APPLE_APPLICATION_ID)" != "-" ]; then \
		echo "Signing runtime artifacts..."; \
		codesign --sign "$(APPLE_APPLICATION_ID)" --options runtime --timestamp --force \
			"$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/libkrun.1.dylib"; \
		codesign --sign "$(APPLE_APPLICATION_ID)" --options runtime --timestamp --force \
			"$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/gvproxy"; \
		codesign --sign "$(APPLE_APPLICATION_ID)" --options runtime --timestamp --force \
			--entitlements ../VMM/helper/entitlements.plist \
			"$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/glassdock-vmm"; \
		codesign --sign "$(APPLE_APPLICATION_ID)" --options runtime --timestamp --force \
			"$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/glassdock"; \
		for artifact in libkrun.1.dylib gvproxy glassdock-vmm glassdock; do \
			codesign --verify --strict --verbose=2 \
				"$(PACKAGE_ROOT)$(INSTALL_PREFIX)/bin/$$artifact"; \
		done; \
	fi

.PHONY: component-pkg
component-pkg: sign-binary scripts
	@echo "Creating component package..."
	@COPYFILE_DISABLE=1 pkgbuild --root "$(PACKAGE_ROOT)" \
		--identifier "$(PACKAGE_IDENTIFIER)" \
		--version $(BUILD_VERSION) \
		--install-location / \
		--scripts "$(SCRIPTS_DIR)" \
		--ownership preserve \
		$(OUT_DIR)/glassdock.pkg

.PHONY: product-pkg
product-pkg: component-pkg resources
	@echo "Creating distribution package..."
	@COPYFILE_DISABLE=1 productbuild --distribution $(BUILD_DIR)/Distribution \
		--resources $(RESOURCES_DIR) \
		--package-path $(OUT_DIR) \
		$(OUT_DIR)/glassdock-unsigned.pkg

.PHONY: sign-pkg
sign-pkg: product-pkg
	@if [ "$(NO_CODESIGN)" = "1" ]; then \
		mv $(OUT_DIR)/glassdock-unsigned.pkg $(OUT_DIR)/$(PKG_NAME); \
		echo "✅ Unsigned installer created: $(OUT_DIR)/$(PKG_NAME)"; \
	else \
		echo "Signing installer package..."; \
		productsign --timestamp --sign "$(APPLE_PRODUCT_ID)" \
			$(OUT_DIR)/glassdock-unsigned.pkg \
			$(OUT_DIR)/$(PKG_NAME); \
		rm $(OUT_DIR)/glassdock-unsigned.pkg; \
		echo "✅ Signed installer created: $(OUT_DIR)/$(PKG_NAME)"; \
	fi
	@rm -f $(OUT_DIR)/glassdock.pkg

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
	@echo "Glass Dock macOS Package Installer"
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
	@echo "  PACKAGE_IDENTIFIER=id     - Package receipt identifier (default: $(PACKAGE_IDENTIFIER))"
	@echo "  PATHS_D_NAME=name         - /etc/paths.d entry name (default: $(PATHS_D_NAME))"
	@echo "  INSTALL_PATHS_D=0         - Skip modifying /etc/paths.d (useful for isolated QA)"
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
	@echo "  - Run 'make release guest-image vmm' in the parent directory to build the runtime"
	@echo "  - Ensure Xcode command line tools are installed"
	@echo "  - For notarization: Apple Developer account with app-specific password"

.PHONY: clean-legacy
clean-legacy:
	@echo "Cleaning legacy files from old build system..."
	@rm -f Distribution welcome.html conclusion.html
	@rm -rf root tmp
	@rm -f scripts/preinstall scripts/postinstall
	@echo "Legacy files cleaned. Only source templates (.in files) remain."

.PHONY: clean
clean: clean-legacy
	@echo "Cleaning installer build files..."
	@rm -rf $(BUILD_DIR) $(OUT_DIR) $(TMP_DIR)

.PHONY: FORCE
FORCE:
