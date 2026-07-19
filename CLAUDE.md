# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ProjectorKit is a Swift library (`ProjectorKit`) plus a CLI (`projector`) for reliably inspecting and mutating Xcode `.xcodeproj` files — built for scripts and coding agents. The central design constraint, and the thing that makes this codebase non-obvious, is **minimal, reviewable diffs**: a mutation must change only the bytes that semantically changed, not reformat the whole file the way a naive parse-mutate-serialize library would.

## Commands

```sh
swift build                          # builds ProjectorKit + projector
swift test                           # ProjectorKitTests + CLITests — no Xcode/xcodebuild required
swift test --filter FidelityTests    # run one test suite
swift test --filter noOpSaveIsByteIdentical   # run one test by name
Scripts/run-integration-tests.sh     # slow: spawns real xcodebuild against a scratch copy of the fixture; not run by swift test
```

Running the CLI locally against a project:

```sh
.build/debug/projector list targets --project Tests/ProjectorKitTests/Fixtures/SyncedApp/SyncedApp.xcodeproj
```

There is no linter configured; there's nothing to run beyond `swift build`/`swift test`.

## Architecture

### Two targets, one direction of dependency

`Sources/ProjectorKit` is the library — all Xcode-project logic lives here and has no knowledge of ArgumentParser, JSON output, or exit codes. `Sources/projector` is a thin CLI shell that parses arguments, calls into ProjectorKit, and renders the result. When adding a new capability, the operation belongs in ProjectorKit; only argument parsing and JSON/text rendering belong in `projector`.

### The fidelity pipeline (the part worth understanding before touching anything)

Raw `XcodeProj` (the underlying pbxproj parser/serializer) re-serializes the *entire* file on every write, in its own formatting style — which would make every edit touch nearly every line. ProjectorKit avoids this with a splice pipeline spread across `Sources/ProjectorKit/Fidelity/`:

1. **`PBXTextIndex`** — a string/brace/comment-aware lexer that maps the on-disk pbxproj text to byte ranges per object entry and per `/* Begin/End X section */` block, without needing to understand the object graph.
2. **`SurgicalWriter`** — serializes both the *pristine* graph (as loaded) and the *mutated* graph (after operations ran) through `SerializationStyle`'s pinned `PBXOutputSettings`, diffs them at object granularity using two `PBXTextIndex` passes, then splices only the changed/added/removed object blocks into the original on-disk text. The result is verified by re-parsing and re-serializing it and checking it's byte-identical to the mutated-graph serialization; if that verification fails for any reason, it silently falls back to a full reserialize rather than risk corrupting the file (this fallback is reported to the caller as `fidelity: "reserialize"` vs `"surgical"`).
3. **`DiffReport`** — a stdlib-only unified diff (no shelling out to `diff`) used both for `--check` previews and for the diff embedded in `--json` output.

`Sources/ProjectorKit/Core/SavePipeline.swift` (`ProjectorProject.check()`/`.save()`) is what operations actually call: validate → optimistic-lock check against the file's mtime/size at load time → run the fidelity pipeline → atomic write (`Safety/AtomicWriter.swift`, temp file + rename, optional `.projector-backup` sibling) → re-parse sanity check → optional `xcodebuild -list` ground-truth check (`Safety/SanityChecks.swift`, opt-in via `--verify-xcodebuild` because it's slow).

### Not every mutation goes through the pbxproj splice path

Two capabilities intentionally bypass the pbxproj pipeline above because they aren't pbxproj edits:

- **`.xcconfig` value edits** (`Operations/XCConfigOperations.swift`, `set xcconfig-value`) edit the xcconfig file's own text directly with a small regex-based line editor, because XcodeProj's `XCConfig` writer drops comments on write. (`set xcconfig`, by contrast — *attaching* an xcconfig file to a build configuration — is a normal pbxproj edit and does go through the splice path.)
- **Schemes and Info.plist/entitlements** (`Operations/SchemeOperations.swift`, `Operations/PlistOperations.swift`) write their own XML files directly (schemes: full-file write, create-only, idempotent by name; plists: a generic `Any`-typed round-trip through `PropertyListSerialization` with sorted keys, so untouched keys of types ProjectorKit doesn't know about are never dropped). These do not support `--check` — there's no meaningful dry run for a direct file write. `setInfoPlistValue` additionally has a routing decision: if the target has `GENERATE_INFOPLIST_FILE = YES`, scalar values go to an `INFOPLIST_KEY_*` build setting (a real pbxproj edit) instead of touching a physical file.

The CLI's `apply` batch command (`Commands/ApplyCommand.swift`) only supports operations that go through the pbxproj splice path, for exactly this reason — it can't offer "one write" semantics across two different write mechanisms.

### Operations pattern

Every mutation lives in `Sources/ProjectorKit/Operations/*.swift` as an `extension ProjectorProject`, returns `OperationResult` (`.applied(changes:)` or `.alreadySatisfied`), and is idempotent by construction — an operation checks the current state before mutating and returns `.alreadySatisfied` if the desired end-state already holds. New operations should follow this shape rather than throwing on "already exists."

### CLI command pattern

Every mutating subcommand in `Sources/projector/Commands/` follows the same shape: parse args → call one `ProjectorProject` operation → hand the `OperationResult` to `MutationRunner.finish` (`Sources/projector/MutationSupport.swift`), which handles `--check`/`--diff`/`--no-backup`/`--verify-xcodebuild`, the JSON envelope, and exit codes uniformly. Read-only commands use the simpler `runCommand`/`emit` helpers in `Sources/projector/Projector.swift`/`Output.swift` instead. Exit codes are centralized in `ProjectorExitCode` — reuse them rather than inventing new ones.

### `Inspect/` is the read model

`Inspect/ProjectSnapshot.swift` defines the versioned Codable structs that back every `--json` inspect command; `Inspect/Inspector.swift` builds them from a loaded project (it's also what resolves Xcode-16 synchronized-folder membership by walking the filesystem, since those files have no explicit pbxproj entries); `Inspect/BuildSettingResolver.swift` resolves a build setting's effective value across the target → project → xcconfig layering and reports which layer won.

### Fixtures and goldens

`Tests/ProjectorKitTests/Fixtures/` holds real, buildable `.xcodeproj` projects committed verbatim — they're the ground truth the fidelity tests splice against, not synthetic data. `Scripts/regenerate-fixtures.md` documents how to add or refresh one (hand-authored/created in real Xcode, validated with `plutil -lint`, `xcodebuild -list`, and `xcodebuild build`, with the Xcode version recorded in that file's provenance table). Fidelity tests must be re-baselined by hand in the same commit as any fixture change.

### Dependency pinning

`XcodeProj` is pinned with `exact:` in `Package.swift`, not `from:`. Any upstream serialization-style change alters ProjectorKit's output bytes, so upgrading it is a deliberate action that requires re-baselining the golden fixture tests in the same commit — never bump it as a routine dependency update.
