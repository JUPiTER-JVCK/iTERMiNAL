# iTERMiNAL

A native macOS terminal with a chat-app shell: a conversation-style sidebar of
workspaces and tabs, a rounded composer bar, sliding side panels for an
embedded web browser and a Finder-style file list, and split-pane layouts that
survive relaunch.

Built in Swift with SwiftUI/AppKit on top of
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — a real VT100/xterm
terminal (vim, htop, and ssh all work), not a command runner.

## Features

- **Real terminal emulation** — PTY-backed login shell via SwiftTerm, full
  ANSI/xterm support, alternate-screen apps, configurable scrollback and
  cursor style.
- **Chat-style shell** — translucent sidebar listing workspaces and tabs like
  conversations, with working directory and git branch under each title; a
  bottom composer bar that sends commands to the focused terminal.
- **Workspaces → tabs → splits** — arbitrary horizontal/vertical split trees
  per tab; layouts are snapshotted to Application Support and restored on
  launch.
- **Sliding panels** — a right-hand inspector hosting an embedded WKWebView
  browser and a Finder-style file browser that can follow the focused
  terminal's directory. Both can also be placed as split panes next to
  terminals.
- **Settings for everything** — General, Appearance (theme, accent,
  opacity), Terminal (font, cursor, scrollback), Panels, Shortcuts, and
  Advanced, all applying live.
- **AI seam** — the composer reserves `@ai …` and the app ships an
  `AssistantService` protocol; a real assistant plugs in without UI changes.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Building

```sh
brew install xcodegen
xcodegen generate
open iTERMiNAL.xcodeproj
```

Then build and run the `iTERMiNAL` scheme. CI builds every push on a macOS
runner (`.github/workflows/build.yml`).

## Shell integration (recommended)

The sidebar and file panel follow your working directory via OSC 7. zsh
doesn't emit it by default — add this to `~/.zshrc`:

```zsh
# Report the working directory to iTERMiNAL (OSC 7)
if [[ "$TERM_PROGRAM" == "iTERMiNAL" ]]; then
  _iterminal_cwd() { print -Pn "\e]7;file://%m%d\a" }
  precmd_functions+=(_iterminal_cwd)
fi
```

## Keyboard shortcuts

| Action | Keys |
| --- | --- |
| New terminal tab | ⌘T |
| New workspace | ⇧⌘N |
| Split right / down | ⌘D / ⇧⌘D |
| Split with browser | ⇧⌘B |
| Close pane / tab | ⇧⌘W / ⌥⌘W |
| Browser / Files panel | ⌥⌘B / ⌥⌘F |
| Settings | ⌘, |

## Architecture

```
Sources/iTERMiNAL/
├── App/        entry point, window scene, menu commands
├── Chrome/     sidebar, composer bar, theme, materials
├── Terminal/   TerminalEngine protocol + SwiftTerm implementation,
│               TerminalSession (PTY lifecycle, cwd/title/git metadata)
├── Workspace/  Workspace → Tab → PaneNode split-tree model, persistence,
│               split-tree rendering
├── Panels/     browser pane (WKWebView) and Finder-style file pane
├── Settings/   AppSettings store + settings window sections
└── AI/         AssistantService seam (null implementation for now)
```

The terminal backend is isolated behind the `TerminalEngine` protocol
(`Sources/iTERMiNAL/Terminal/TerminalEngine.swift`) so the SwiftTerm engine
can later be swapped for another (e.g. libghostty) without touching the UI.

## Roadmap

- [ ] AI assistant behind the `@ai` composer prefix (provider-pluggable)
- [ ] Pane attention notifications (OSC 9/777) with focus rings
- [ ] Listening-port and process metadata in the sidebar
- [ ] Editable key bindings
- [ ] SSH/SFTP remote sessions
- [ ] Optional libghostty engine
- [ ] Signed/notarized releases

## License

MIT — see [LICENSE](LICENSE).
