#!/bin/zsh
# Build the injectable dylib for Messages.app IMCore access
# Requires SIP disabled for DYLD_INSERT_LIBRARIES to work

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$ROOT_DIR/.build/release"
SRC="$ROOT_DIR/Sources/IMsgHelper/EngramInjected.m"

mkdir -p "$OUT_DIR"

echo "Building engram-imcore-helper.dylib..."
clang -dynamiclib -arch arm64e -fobjc-arc \
    -framework Foundation \
    -Wno-arc-performSelector-leaks \
    -o "$OUT_DIR/engram-imcore-helper.dylib" \
    "$SRC"

echo "Built: $OUT_DIR/engram-imcore-helper.dylib"
