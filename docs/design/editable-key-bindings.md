# Design: editable key bindings

Status: design only — not implemented yet.

## Goal

Let users change the shortcuts for app actions (split, panels, composer,
palette, etc.) in Settings, with conflicts surfaced clearly, without breaking
the menu bar or the command palette.

## What exists today

- Shortcuts are hardcoded on `AppCommands` in `iTERMiNALApp.swift` via
  `.keyboardShortcut(...)`.
- Settings → Shortcuts (`ShortcutsSettingsView`) is a **read-only** table of
  `(action, keys)` pairs that mirrors the README / menu — display only.
- Command palette actions carry their own shortcut strings for display and
  invoke the same store methods as the menus.
- Terminal input still needs first claim on most keystrokes when a pane is
  focused; app shortcuts are mostly Command-chord menus.

## Approach

### 1. Single source of truth

Introduce a `KeybindingCatalog` (name flexible) that owns:

- Stable action IDs (`newTab`, `splitRight`, `toggleBrowserPanel`, …)
- Default chord for each action
- User overrides persisted in `AppSettings` (or a small adjacent plist)
- Resolved chord = override ?? default

Menus (`AppCommands`), Settings, command palette subtitles, and any in-app
cheat sheet all read from the catalog. Stop maintaining three parallel lists.

### 2. Chord model

Store chords as a small Codable struct, e.g. key + modifier flags (not a free
string), so validation and conflict detection are reliable. Display with the
same glyphs the README already uses (⌘ ⌥ ⇧ ⌃).

### 3. Settings UX

Replace the read-only Shortcuts pane with:

- Grouped list (Terminal / Panels / Composer / General) matching menu structure
- Click a row → record next key chord (Esc cancels)
- Reset row / Reset all to defaults
- Inline conflict: "Also used by Split Right" with option to clear the other
  or cancel
- Actions that cannot be rebound in v1 (system-reserved or terminal-passthrough)
  shown disabled with a reason

### 4. Wiring menus dynamically

SwiftUI `.keyboardShortcut` needs a `KeyEquivalent` + `EventModifiers` at view
build time. Rebuild `AppCommands` from the catalog whenever overrides change
(`AppSettings` is already `@ObservedObject` in `AppCommands`).

If a chord is cleared, omit `.keyboardShortcut` for that item (menu item
remains clickable).

### 5. Scope boundaries (important)

**v1 rebinds app chrome shortcuts only** — the chords currently on
`AppCommands` / documented in Settings.

**Out of v1:** per-terminal keymaps (vim-style raw key passthrough tables),
rebind of keys without modifiers that would steal typing from the PTY, and
user-defined chords that conflict with macOS reserved shortcuts (warn and
block).

### 6. Sync / export

Keybinding overrides are preferences, not secrets. Include them in
`PreferencesArchive` / future iCloud sync once that lands (optional field so
old archives still decode). Do not sync anything from the keychain.

## Implementation order

1. Catalog + defaults matching today's `AppCommands` / Shortcuts list.
2. Persist overrides; drive Settings UI (record chord, conflicts, reset).
3. Point `AppCommands` and palette shortcut labels at the catalog.
4. Tests: round-trip Codable; conflict detection; "defaults match previous
   hardcoded set."
5. README: note that Shortcuts are editable; keep the default table as the
   factory defaults reference.

## Out of scope for v1

- Sharing keybinding files between apps (Ghostty / VS Code import)
- Modal keybinding schemes (spacemacs-style leader keys)
- Rebinding inside the VT layer (that belongs with engine config, and later
  with optional libghostty)
