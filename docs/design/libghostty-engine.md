# Design: optional libghostty terminal engine

Status: design only — not implemented yet.

## Goal

Offer libghostty as an alternate `TerminalEngine` behind the existing protocol
so users can opt into Ghostty's emulator without rewriting SwiftUI chrome,
workspaces, or the scripting API.

## What exists today

- `TerminalEngine` already documents the intent: "swapped for another engine
  (e.g. libghostty) without touching the UI layer."
- `SwiftTermEngine` is the sole implementation: PTY lifecycle, appearance,
  palette, optional GPU path, visible-text capture, activity / link / focus
  callbacks.
- `TerminalSession` + `TerminalHostView` talk only to the protocol.
- `contrib/ghostty/` already shares **themes and companion configs** with
  Ghostty — visual parity, not the emulator itself.
- App ships as a universal macOS binary via XcodeGen (`project.yml`); CI builds
  on macOS runners.

## Approach

### 1. Keep SwiftTerm as default

Default engine remains SwiftTerm. libghostty is opt-in in Settings → Terminal
→ Engine: "SwiftTerm (default)" / "Ghostty (libghostty)" (names TBD).

Changing engine applies to **new** sessions; existing sessions keep their
engine until restart (or offer "Restart all sessions to apply"). Avoid live
swapping a live PTY between emulators mid-flight in v1.

### 2. `GhosttyEngine: TerminalEngine`

Implement every protocol requirement:

| Protocol API | Notes |
| --- | --- |
| `view` | NSView (or wrapping NSView) hosting Ghostty's surface |
| `start` / `send` / `terminate` | Map `TerminalLaunchConfiguration` onto Ghostty's process / PTY APIs |
| `apply` / `applyPalette` | Bridge `TerminalAppearance` + `PaletteColor` into Ghostty config |
| `setGPUAcceleration` | Map to Ghostty's renderer; return actual state |
| `captureVisibleText` | Required for `iterminalctl terminal.capture` |
| `onActivity` / `onLinkActivated` / `onFocusGained` | Wire to Ghostty equivalents |
| `onAttention` (once pane-attention lands) | Map bell / OSC if Ghostty exposes them |

Delegate title / cwd / exit stay on `TerminalEngineDelegate` as today.

### 3. Packaging and build

libghostty is a native dependency with its own build story. Design constraints:

- Prefer a **prebuilt** xcframework / sparse checkout strategy documented in
  README rather than compiling Zig inside every CI job on day one, if that is
  what Ghostty upstream supports for embedders.
- Gate the Ghostty target with an XcodeGen setting / compiler flag so OSS
  contributors can still build SwiftTerm-only without the Ghostty toolchain.
- Universal (arm64 + x86_64) must keep working for Release zips; if libghostty
  is arm64-only temporarily, disable the engine option on Intel and say so in
  Settings.
- App Sandbox stays **off**; Hardened Runtime stays **on** — same stance as the
  rest of the app.

Exact fetch/build steps belong in an implementation PR once the upstream
embedder API is pinned to a version.

### 4. Config bridge

iTERMiNAL Settings remain the source of truth for font, theme, cursor,
scrollback, GPU. On session start, translate into Ghostty config keys. Do not
require users to edit `config` files for the in-app engine.

`contrib/ghostty` stays for **standalone Ghostty.app** users who want matching
palettes — separate from the embedded engine.

### 5. Feature parity expectations

**Must work for engine GA:** login shell / PTY, ANSI/xterm apps (vim, htop,
ssh), theme/font live update, scrollback capture for API, link click →
`onLinkActivated`, activity debounce, GPU toggle honesty.

**May lag in v1:** every SwiftTerm niche; document gaps in Settings help text.
Missing protocol methods block shipping the option — implement or stub with a
clear capability flag (`supportsGPU`, etc.) rather than crashing.

### 6. Selection and rollback

If Ghostty fails to load (missing dylib, arch mismatch), fall back to SwiftTerm
and show an error in Settings. Persist the user's preference but record
`lastEngineLaunchError` for support.

## Implementation order

1. Spike: embed a hello-world Ghostty surface in a sample target; confirm
   notarization / Hardened Runtime / universal story.
2. `GhosttyEngine` implementing `TerminalEngine`; feature-flagged in Settings.
3. Wire palette/appearance; capture; activity/links.
4. CI matrix: SwiftTerm-only job + Ghostty job (or same job with cached
   artifact).
5. README: how to enable, requirements, and known gaps vs SwiftTerm.

## Out of scope for v1

- Replacing SwiftTerm entirely
- Using Ghostty's GTK/other-platform ports
- Importing arbitrary `ghostty` config files as the app's settings store
- Windows/Linux (app is macOS-only)
