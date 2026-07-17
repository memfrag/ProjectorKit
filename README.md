# Projector

A Swift framework (`ProjectorKit`) and CLI (`projector`) for reliably inspecting and
manipulating Xcode project files — built for scripts and coding agents.

**Core promise: minimal, reviewable diffs.** Projector edits `project.pbxproj`
surgically: unchanged objects keep their original bytes, byte-for-byte. A no-op save
is byte-identical. Every mutation is idempotent, validated before writing, written
atomically, and can be previewed with `--check`.

Built on [tuist/XcodeProj](https://github.com/tuist/XcodeProj) (pinned exactly —
serialization style changes are deliberate, golden-re-baselined upgrades).

## Status

Early development. Milestones:

- [x] M0 — scaffold, project loading, `list targets`
- [x] M1 — inspect commands (`list`, `show`, `get`) + `validate`
- [x] M2 — fidelity harness (surgical writer, goldens, `--check`)
- [x] M3 — file & group operations (classic groups and Xcode 16+ synchronized folders)
- [x] M4 — targets, dependencies, Swift packages
- [x] M5 — build settings & xcconfig
- [x] M6 — schemes, Info.plist, entitlements
- [ ] M7 — batch `apply`, xcodebuild verification, agent docs

## Usage

```sh
# Inspect
projector list targets --project MyApp.xcodeproj --json
projector show target MyApp
projector get build-setting SWIFT_VERSION --target MyApp --resolved
projector validate

# Mutate (idempotent; --check previews without writing)
projector set build-setting SWIFT_VERSION 6.0 --target MyApp --check
projector add file Sources/Helper.swift --target MyApp --group Support
projector remove file Sources/Old.swift --delete
projector add target Tool --type commandLineTool --platform macOS
projector add dependency --target MyApp --on Tool
projector add package https://github.com/apple/swift-log.git --product Logging --target MyApp
projector add package ../LocalPkg --local --product LocalLib --target MyApp
projector set xcconfig-value --file Shared.xcconfig SWIFT_STRICT_CONCURRENCY complete
projector set xcconfig Shared.xcconfig --target MyApp --configuration Debug
```

`set xcconfig-value` edits an `.xcconfig` file's own text directly, preserving
every other line's comments and formatting exactly — it never routes through
XcodeProj's xcconfig writer, which would drop comments. `set xcconfig` attaches
an existing `.xcconfig` file as a configuration's base configuration in the
pbxproj (surgically, like every other mutation here).

```sh
projector add scheme Release-CI --target MyApp --test-target MyAppTests --check
projector set plist CFBundleDisplayName "My App" --target MyApp
projector set entitlement com.apple.security.network.client true --target MyApp
```

`add scheme` writes a shared `.xcscheme` file (create-only; re-running with the
same name is a no-op) and supports `--check`. `set plist`/`set entitlement`
route to whichever mechanism is correct for the target: an `INFOPLIST_KEY_*`
build setting when `GENERATE_INFOPLIST_FILE = YES`, or a direct edit of the
physical plist/entitlements file otherwise (preserving every other key via a
generic property-list round-trip, not just the ones Projector knows about).
These two do not support `--check` — the physical-file path writes immediately
and has no meaningful dry run.

`--project` may be omitted when exactly one `.xcodeproj` exists in the current
directory. Mutating commands take `--check` (dry-run, exit 2 if changes pend),
`--diff` (show the unified diff), and `--no-backup`.

## Development

```sh
swift build
swift test
```

Integration tests (real `xcodebuild`): `PROJECTOR_INTEGRATION=1 Scripts/run-integration-tests.sh`.
