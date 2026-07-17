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
- [x] M7 — batch `apply`, xcodebuild verification, agent docs

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
`--diff` (show the unified diff), `--no-backup`, and `--verify-xcodebuild`
(after writing, run `xcodebuild -list` and fail the save if Xcode doesn't
accept the result — off by default, since it spawns XCBBuildService and is slow).

### Batch edits: `apply`

Multi-step edits ("add 3 files, a package, and a setting") should go through
`apply` rather than N separate invocations — one parse, one write, one diff,
and no window where another process (Xcode) could touch the file mid-sequence:

```sh
cat > ops.json <<'EOF'
[
  {"op": "add-file", "path": "Feature.swift", "targets": ["MyApp"], "group": "Sources"},
  {"op": "set-build-setting", "key": "SWIFT_VERSION", "value": "6.0", "target": "MyApp"},
  {"op": "add-target", "name": "Tool", "type": "commandLineTool", "platform": "macOS"}
]
EOF
projector apply ops.json --project MyApp.xcodeproj --check   # preview the combined diff
projector apply ops.json --project MyApp.xcodeproj --verify-xcodebuild
```

Supported `op` values: `add-file`, `remove-file`, `add-group`, `add-target`,
`remove-target`, `add-dependency`, `remove-dependency`, `add-package`,
`remove-package`, `set-build-setting`, `unset-build-setting`, `set-xcconfig`.
(Schemes and plist/entitlement edits use a separate direct-file-write
mechanism and aren't batchable — run those as individual commands.) Pass `-`
as the path to read from stdin. Run `projector apply --help` for the full
per-op field reference.

### JSON contract for agents

Every command's `--json` output is one flat object:

```json
{ "ok": true, "action": "add-file", "result": "applied",
  "changes": [{"kind": "buildFile", "detail": "...", "target": "MyApp"}],
  "fidelity": "surgical", "diff": null, "warnings": [], "schemaVersion": 1 }
```

`result` is one of `applied` / `already-satisfied` / `would-apply` (under
`--check`) / `no-change`. `fidelity` is `surgical` (unchanged bytes preserved,
diff confined to the edit), `reserialize` (the splice couldn't be verified —
still correct, but a large diff; treat as a signal something is unusual about
the project), or `none` (no-op). On error, the envelope is
`{"ok": false, "error": "...", "schemaVersion": 1}` instead.

Exit codes: `0` success (applied or already-satisfied), `2` `--check` found
pending changes, `3` entity not found, `4` validation failed, `5` project
parse error, `6` write/lock/verify error, `64` usage error.

## Development

```sh
swift build
swift test                           # ProjectorKitTests + CLITests, no Xcode build required
Scripts/run-integration-tests.sh     # slow: real xcodebuild, gated out of `swift test`
```
