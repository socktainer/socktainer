#!/bin/sh

set -eu

menu_binary="${1:-.build/arm64-apple-macosx/release/GlassDock.app/Contents/MacOS/GlassDockMenu}"
"$menu_binary" --show-popover >/dev/null 2>&1 &
menu_pid=$!

cleanup() {
    kill "$menu_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

swift scripts/assert-menu-popover.swift "$menu_pid"
