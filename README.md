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
- [ ] M4 — targets, dependencies, Swift packages
- [ ] M5 — build settings & xcconfig (scoped set/unset done; xcconfig editing pending)
- [ ] M6 — schemes, Info.plist, entitlements
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
```

`--project` may be omitted when exactly one `.xcodeproj` exists in the current
directory. Mutating commands take `--check` (dry-run, exit 2 if changes pend),
`--diff` (show the unified diff), and `--no-backup`.

## Development

```sh
swift build
swift test
```

Integration tests (real `xcodebuild`): `PROJECTOR_INTEGRATION=1 Scripts/run-integration-tests.sh`.
