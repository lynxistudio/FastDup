#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE_DIR="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"
TEST_BINARY="$ROOT_DIR/.build/DeleteDedupRegression"

mkdir -p "$MODULE_CACHE_DIR"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" swiftc -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos14.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -framework QuickLookUI \
  -framework CoreServices \
  -framework Quartz \
  "$ROOT_DIR/Tests/DeleteDedupRegression.swift" "$ROOT_DIR"/Models/*.swift "$ROOT_DIR"/Services/*.swift \
  -lsqlite3 \
  -o "$TEST_BINARY"

"$TEST_BINARY"
