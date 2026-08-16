VENDOR_DIR := vendor/libkrun
OUT_DIR := out
BUILD_DIR := build
LINUX_SYSROOT := $(abspath $(BUILD_DIR)/linux-sysroot)
LIBKRUN := $(VENDOR_DIR)/target/release/libkrun.dylib
LIBKRUN_SOURCES := $(shell find $(VENDOR_DIR)/src -type f) \
	$(VENDOR_DIR)/Cargo.toml $(VENDOR_DIR)/Cargo.lock $(VENDOR_DIR)/Makefile \
	linux-sysroot.lock scripts/prepare-linux-sysroot.sh ../rust-toolchain.toml
HELPER := $(OUT_DIR)/glassdock-vmm
GVPROXY := $(OUT_DIR)/gvproxy
LIBKRUN_OUT := $(OUT_DIR)/libkrun.1.dylib
CLANG := /usr/bin/clang

.PHONY: all clean test

all: $(HELPER) $(GVPROXY)

$(LINUX_SYSROOT)/.sysroot_ready: linux-sysroot.lock scripts/prepare-linux-sysroot.sh
	OUTPUT_DIR="$(LINUX_SYSROOT)" sh scripts/prepare-linux-sysroot.sh

$(LIBKRUN): $(LIBKRUN_SOURCES) $(LINUX_SYSROOT)/.sysroot_ready
	CARGO_INCREMENTAL=0 $(MAKE) -C $(VENDOR_DIR) BLK=1 NET=1 SYSROOT_LINUX="$(LINUX_SYSROOT)"

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

$(LIBKRUN_OUT): $(LIBKRUN) | $(OUT_DIR)
	cp $(LIBKRUN) $(LIBKRUN_OUT)
	install_name_tool -id @rpath/libkrun.1.dylib $(LIBKRUN_OUT)
	codesign --force --sign - $(LIBKRUN_OUT)

$(GVPROXY): gvproxy/build.sh gvproxy/source.lock | $(OUT_DIR)
	sh gvproxy/build.sh $(GVPROXY)

$(HELPER): helper/glassdock_vmm.c helper/gvproxy_process.c helper/gvproxy_process.h helper/entitlements.plist $(LIBKRUN_OUT) $(GVPROXY) | $(OUT_DIR)
	$(CLANG) -std=c17 -O3 -Wall -Wextra -Werror -fblocks \
		-I$(VENDOR_DIR)/include helper/glassdock_vmm.c helper/gvproxy_process.c \
		$(LIBKRUN_OUT) -Wl,-rpath,@executable_path \
		-framework CoreFoundation -framework Hypervisor -o $(HELPER)
	install_name_tool -change libkrun.1.dylib @rpath/libkrun.1.dylib $(HELPER)
	codesign --force --sign - --entitlements helper/entitlements.plist $(HELPER)

test: $(HELPER) $(GVPROXY)
	sh tests/helper-cli.sh $(HELPER)
	sh tests/gvproxy-supply-chain.sh
	$(CLANG) -std=c17 -O2 -Wall -Wextra -Werror -Ihelper \
		tests/gvproxy-stop.c helper/gvproxy_process.c -o $(OUT_DIR)/gvproxy-stop-test
	$(OUT_DIR)/gvproxy-stop-test

clean:
	$(MAKE) -C $(VENDOR_DIR) clean
	rm -rf $(OUT_DIR) $(BUILD_DIR)
