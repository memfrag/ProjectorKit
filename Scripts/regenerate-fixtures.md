# Fixture provenance and regeneration

Fixtures live in `Tests/ProjectorKitTests/Fixtures/`. Each is a complete, buildable
project committed verbatim (no `xcuserdata/`).

## Provenance

The fixtures were hand-authored to match the output of the Xcode version noted below,
then validated against the real toolchain:

- `plutil -lint project.pbxproj` passes
- `xcodebuild -list -project … -json` reports the expected targets/schemes
- `xcodebuild build … CODE_SIGNING_ALLOWED=NO` succeeds (macOS-target fixtures)

| Fixture      | Style                                            | objectVersion | Modeled on |
|--------------|--------------------------------------------------|---------------|------------|
| SyncedApp    | macOS SwiftUI app, synchronized root group       | 77            | Xcode 26.5 |

## Regenerating with real Xcode (preferred when possible)

For maximum realism, fixtures can be re-created in the Xcode GUI and re-committed:

1. File → New → Project…, choose the template noted in the table.
2. Name it exactly as the fixture directory, save to a temp location.
3. Close Xcode. Delete `xcuserdata/` from the `.xcodeproj`.
4. Replace the fixture directory contents; keep source files minimal.
5. Run the validation commands above, then run `swift test` — golden fidelity
   tests will fail and must be re-baselined **in the same commit**, with the diff
   reviewed by hand.

Record the Xcode version used in the table above.
