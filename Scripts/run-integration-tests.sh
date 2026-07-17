#!/bin/sh
# Ground-truth integration check: builds the CLI, exercises it against a copy
# of the SyncedApp fixture, and confirms Xcode itself accepts and builds the
# result. Not part of `swift test` (which only proves ProjectorKit and
# XcodeProj agree with each other) — this proves Xcode agrees too.
#
# Requires a full Xcode installation (`xcodebuild`). Slow: spawns
# XCBBuildService and a real compile. Run explicitly, or gate CI on
# PROJECTOR_INTEGRATION=1.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building projector"
swift build

BIN="$ROOT/.build/debug/projector"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Staging a scratch copy of the SyncedApp fixture"
cp -R "$ROOT/Tests/ProjectorKitTests/Fixtures/SyncedApp" "$WORK/SyncedApp"
cd "$WORK/SyncedApp"

echo "==> add file + set build setting + create target, via a single apply batch"
printf 'import Foundation\nenum IntegrationCheck { static let ok = true }\n' > Feature.swift
cat > ops.json <<'EOF'
[
  {"op": "add-file", "path": "Feature.swift", "targets": ["SyncedApp"], "group": "Sources"},
  {"op": "set-build-setting", "key": "SWIFT_VERSION", "value": "6.0", "target": "SyncedApp"},
  {"op": "add-target", "name": "Tool", "type": "commandLineTool", "platform": "macOS"}
]
EOF
"$BIN" apply ops.json --project SyncedApp.xcodeproj --verify-xcodebuild --json

mkdir -p Tool
printf 'print("integration check ok")\n' > Tool/main.swift
"$BIN" add file Tool/main.swift --target Tool --project SyncedApp.xcodeproj

echo "==> xcodebuild -list"
xcodebuild -list -project SyncedApp.xcodeproj

echo "==> xcodebuild build (SyncedApp)"
xcodebuild build -project SyncedApp.xcodeproj -scheme SyncedApp \
  -derivedDataPath "$WORK/dd" CODE_SIGNING_ALLOWED=NO

echo "==> xcodebuild build (Tool) and run it"
xcodebuild build -project SyncedApp.xcodeproj -scheme Tool \
  -derivedDataPath "$WORK/dd" CODE_SIGNING_ALLOWED=NO
"$WORK/dd/Build/Products/Debug/Tool" | grep -q "integration check ok"

echo "==> validate reports no errors"
"$BIN" validate --project SyncedApp.xcodeproj

echo "==> re-running the same batch is a no-op"
"$BIN" apply ops.json --project SyncedApp.xcodeproj --check
# --check exits 0 only when nothing is pending; a nonzero here fails the script.

echo "Integration checks passed."
