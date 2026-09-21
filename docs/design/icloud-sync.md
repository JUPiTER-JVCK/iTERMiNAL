# Design: iCloud sync

Status: **implemented** (PR #22). Kept as the design record; see
*What shipped differently* at the end — including one line of reasoning
below that should not be reused.

## Goal

Sync workspaces and non-secret preferences across Macs signed into the same
iCloud account, with clear Settings UX to enable/disable and see status.

## What exists today

`SyncEngine` is already an intentional seam. `LocalOnlySyncEngine` is the only
implementation: it saves to Application Support and exposes Export/Import.
Comments in `SyncEngine.swift` say a CloudKit engine should adopt the same
protocol later without touching the UI.

`WorkspaceArchive` is the portable payload (versioned JSON):
`AppStateSnapshot` workspaces plus `PreferencesArchive`. Secrets are already
excluded (API token stays in the keychain; SSH has no passwords).
Machine-local bits like launch-at-login and `composerShell` are skipped.

Settings → Sync and the command palette both call `WorkspaceArchiveIO` for
file export/import. The Sync pane currently hardcodes
`LocalOnlySyncEngine.shared`.

## Approach: CloudKit via the existing protocol

Add `CloudKitSyncEngine: SyncEngine` rather than inventing a second sync path.
Keep file Export/Import forever as the offline / OSS fallback.

### Payload

Reuse `WorkspaceArchive` (or a thin `SyncDocument` wrapper around it) as the
CloudKit record body. Same encode/decode, same “secrets never leave this Mac”
rules. Bump `WorkspaceArchive.currentVersion` only when the schema changes;
reject newer versions the way import already does.

### CloudKit model (v1)

One private-database record type, e.g. `ITerminalSyncState`, with fields like:

- `payload` (bytes/asset)
- `schemaVersion` (Int)
- `modifiedAt` (Date)
- `deviceName` (String, display only)

One record per iCloud account (fixed record ID such as `primary`),
last-writer-wins. That matches how import already replaces state wholesale.
True CRDT / per-workspace merge can wait until people actually hit conflicts.

### Local flow

On enable and on a “Sync Now” button: build archive from `WorkspaceStore` +
`AppSettings` → fetch remote → if remote is newer, apply; if local is newer,
upload; if equal, no-op.

Also push after a debounced local save (reuse whatever debounce
`WorkspaceStore.saveNow` already uses). Pull on launch and when the app
becomes active. Surface last sync time and last error in `statusDescription`.

### Engine selection

Introduce a small `SyncEngineProvider` (or preference
`syncMode: local | iCloud`) that Settings binds to. When iCloud is selected but
unavailable, stay on local and show why. Never crash unsigned Debug builds.

## Signing / entitlements

iCloud needs a paid Apple Developer account, the iCloud capability, and signed
builds. That matches the comment already in `SyncEngine.swift`.

Practical split:

1. **Code always ships.** `CloudKitSyncEngine`, Settings picker, graceful
   `isAvailable == false` when the container isn’t entitled or the account
   isn’t signed in.
2. **Capability wiring** in `project.yml` / entitlements: CloudKit + a
   container ID (e.g. `iCloud.com.jupiter.iTERMiNAL`). Document that unsigned
   CI/OSS builds keep “This Mac only”; iCloud only lights up on a
   development-signed or Developer ID build with the capability.
3. **Do not turn on App Sandbox** just to get iCloud. This app deliberately
   ships without sandbox so shells can reach `~/.ssh`, Homebrew, and arbitrary
   paths. CloudKit works with Hardened Runtime + the iCloud entitlement
   without forcing sandbox.

## Settings UX

Keep Status / Snapshots. Add a Mode control: “This Mac only” vs “iCloud”.
When iCloud is on: Sync Now, last synced, account/container status, short note
that secrets and SSH keys are not synced. Export/Import remain available
either way.

## What syncs vs what never syncs

**Sync:** workspace layout tree, tabs/splits metadata, the preference fields
already in `PreferencesArchive` (theme, fonts, SSH connection configs as today
— host/user/port only).

**Never sync:** keychain API token, any future secrets, launch-at-login,
absolute paths like `composerShell`, scrollback buffers, browser cookies/cache,
live PTY state.

Optional hardening for v1: strip or relativize machine-absolute
`defaultDirectory` / shell paths on apply if they don’t exist on this Mac,
same spirit as skipping `composerShell`.

## Implementation order

1. `CloudKitSyncEngine` + provider; Settings stops hardcoding
   `LocalOnlySyncEngine`.
2. Entitlements / container ID in `project.yml`, with README notes for signing.
3. Debounced push + launch/active pull + Sync Now.
4. Unit tests around archive round-trip and “no secret keys in encoded
   payload.”
5. Manual check on two Macs (or one Mac + iCloud.com) with a signed build.

## Out of scope for v1

Signed/notarized release pipeline, multi-record merge, syncing shell history
or scrollback, public iCloud / sharing between Apple IDs.

## What shipped differently

**Do not reuse this document's reasoning about last-writer-wins.** The line
"One record per iCloud account …, last-writer-wins. That matches how import
already replaces state wholesale" is the origin of two data-loss bugs, and it
is wrong in a way that is easy to miss: Import and sync do not have the same
licence. Import replaces everything because the user clicked a button asking
for exactly that. A sync runs on its own schedule with nobody watching, so
reusing the same wholesale-replace path meant a remote update killed every
running shell (`applySnapshot` begins with `terminateAllSessions()`) and
permanently deleted local transcripts, which are deliberately never uploaded
and so could not come back.

Last-writer-wins on the *record* is fine. What does not follow is that
applying the winning record may destroy local state. The shipped code splits
the two: `applySnapshot` keeps its destructive behaviour for Import, and
`applyRemoteSnapshot` — the only path sync may use — merges recents instead of
replacing them and holds a layout change back while any shell is still
running, surfacing it in Settings so closing those shells stays a decision
someone makes.

**The push signal is the one place the design was right and the code was
not.** "Also push after a debounced local save (reuse whatever debounce
`WorkspaceStore.saveNow` already uses)" is exactly correct. The first
implementation instead polled the state file's mtime every two seconds to
*infer* that a save had happened, which cannot distinguish sync's own writes
from the user's and needed a suppression counter held open across an async
save it could not see the end of. It now does what this paragraph said.

**Preferences needed their own signal.** They live in `UserDefaults`, not the
state file, so nothing about a theme or connection change reaches `saveNow`.
Without a separate observer they synced one way only: uploaded when an
unrelated layout edit happened to follow, and otherwise overwritten by the
next remote apply.

**Entitlements need `com.apple.developer.icloud-container-environment`**, which
the signing section above does not mention. Container identifier and CloudKit
service alone are not enough for any build outside the Mac App Store.
