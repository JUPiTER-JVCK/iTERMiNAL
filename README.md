# iTERMiNAL

A native macOS terminal with a chat-app shell: a conversation-style sidebar of
workspaces and tabs, a rounded composer bar, sliding side panels for an
embedded web browser and a file browser (local or remote over SFTP), split-pane
layouts that survive relaunch, and a local scripting API so agents and scripts
can drive it.

Built in Swift with SwiftUI/AppKit on top of
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — a real VT100/xterm
terminal (vim, htop, and ssh all work), not a command runner. No Electron.

## Features

- **Real terminal emulation** — PTY-backed login shell, full ANSI/xterm
  support, alternate-screen apps, configurable scrollback and cursor style,
  and an opt-in Metal GPU renderer.
- **Chat-style shell** — translucent sidebar with New terminal / Automations /
  Skills rows and workspaces whose tabs read like conversations (blue activity
  dots for live background sessions); a "Let's build" landing screen; a
  composer bar with Local / Worktree / Cloud context tabs and the focused
  session's git branch.
- **Workspaces → tabs → splits** — arbitrary horizontal/vertical split trees
  per tab, snapshotted to Application Support and restored on launch.
- **Scriptable browser pane** — an embedded WKWebView, usable as a sliding
  panel or a split pane, drivable from the API (navigate, click, fill, read
  text, wait for a selector, screenshot) for testing a web UI from an agent.
- **Local and remote files** — a Finder-style file pane that browses this Mac
  or any saved SSH host over SFTP, with upload, download, drag-and-drop, and
  open-in-place.
- **Local scripting API + CLI** — a Unix-socket JSON API and the `iterminalctl`
  command for creating workspaces, splitting panes, sending input, and driving
  the browser.
- **Command palette** — ⌘K, fuzzy search over every action.
- **Settings for everything** — General, Appearance, Terminal (theme, font,
  cursor, scrollback, GPU), Panels, Connections, Security, Sync, Shortcuts, and
  Advanced, all applying live.
- **AI seam** — the composer reserves `@ai …` and the app ships an
  `AssistantService` protocol; a real assistant plugs in without UI changes.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later (SwiftTerm's manifest uses Swift tools 6.0)
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

## Scripting API

Enable it in **Settings → Security** (it's off by default — it can type into
live shells), then install the CLI from the same panel and run:

```sh
iterminalctl ping
iterminalctl tab.create directory=~/code
iterminalctl terminal.send text="git status" newline=true
iterminalctl terminal.capture
iterminalctl browser.open url=localhost:3000
iterminalctl browser.fill selector="#email" value=me@example.com
iterminalctl browser.click selector="#submit"
iterminalctl browser.wait selector=".result" timeout=15
iterminalctl browser.screenshot path=~/shot.png
```

| Command | Parameters |
| --- | --- |
| `help`, `ping`, `app.info` | — |
| `workspace.list`, `workspace.create` | `name` |
| `tab.list`, `tab.create`, `tab.select`, `tab.close` | `id`, `workspace`, `directory` |
| `pane.list`, `pane.split`, `pane.close` | `direction`, `kind` |
| `terminal.send`, `terminal.capture` | `text`, `newline`, `session` |
| `browser.open` / `navigate` / `eval` / `click` / `fill` / `text` / `html` / `wait` / `screenshot` | `url`, `selector`, `value`, `script`, `timeout`, `path`, `pane` |
| `files.list` | `path`, `connection`, `hidden` |

The wire protocol is newline-delimited JSON over a Unix socket, so any language
can speak it:

```jsonc
// request
{"id":"1","token":"…","command":"terminal.send","params":{"text":"ls\n"}}
// response
{"id":"1","ok":true,"result":{"session":"…"}}
```

## Remote files (SFTP)

Add hosts in **Settings → Connections**, then pick one from the Files panel's
source menu. Transfers run through the system's own `sftp` client in batch
mode, reusing your `~/.ssh/config`, `known_hosts`, agent, and keys — so
**key-based authentication is required** and this app never stores, prompts
for, or transmits an SSH password.

## Security model

- **The scripting API is opt-in.** It ships disabled, with separate toggles for
  sending terminal input and controlling the browser.
- **The socket is user-only**: mode 0600 inside a 0700 directory, and every
  request must carry a 256-bit token held in your keychain and compared in
  constant time.
- **Secrets live only in the keychain** — never in preferences, the saved
  layout, or exported snapshots.
- **App Transport Security stays on**; only web-view content is exempt, so the
  browser pane can preview a plain-http dev server.
- **No sandbox** — a terminal exists to launch your programs, so it can't run
  sandboxed. Capabilities are narrowed individually instead.

## Keyboard shortcuts

| Action | Keys |
| --- | --- |
| Command palette | ⌘K |
| New terminal tab | ⌘T |
| New workspace | ⇧⌘N |
| Split right / down | ⌘D / ⇧⌘D |
| Split with browser | ⇧⌘B |
| Close pane / tab | ⇧⌘W / ⌥⌘W |
| Browser / Files panel | ⌥⌘B / ⌥⌘F |
| Settings | ⌘, |

## Architecture

```
Sources/
├── iTERMiNAL/
│   ├── App/         entry point, window scene, menu commands
│   ├── Chrome/      sidebar, composer, command palette, themes
│   ├── Terminal/    TerminalEngine protocol + SwiftTerm implementation,
│   │                TerminalSession (PTY lifecycle, cwd/title/git metadata)
│   ├── Workspace/   Workspace → Tab → PaneNode split tree, persistence
│   ├── Panels/      scriptable browser pane, file pane
│   ├── Files/       FileSystemProvider protocol, local + SFTP providers
│   ├── API/         Unix-socket server, message envelope, command router
│   ├── Security/    keychain wrapper
│   ├── Sync/        sync seam, workspace export/import
│   ├── Settings/    preferences store + settings window
│   └── AI/          AssistantService seam (null implementation for now)
└── iterminalctl/    command-line client, bundled into the app
```

The terminal backend sits behind `TerminalEngine`
(`Sources/iTERMiNAL/Terminal/TerminalEngine.swift`) and the file backend behind
`FileSystemProvider` (`Sources/iTERMiNAL/Files/FileSystemProvider.swift`), so
either can be swapped (libghostty, an in-process SSH stack) without touching
the UI.

## Roadmap

- [ ] AI assistant behind the `@ai` composer prefix (provider-pluggable)
- [ ] Pane attention notifications (OSC 9/777)
- [ ] Editable key bindings
- [ ] SSH terminal sessions (not just SFTP file transfer)
- [ ] iCloud sync (needs a signing/entitlement story)
- [ ] Optional libghostty engine
- [ ] Signed/notarized releases

## License

MIT — see [LICENSE](LICENSE).
