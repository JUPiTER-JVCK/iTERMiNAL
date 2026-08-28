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
- **Chat-style shell** — sidebar with New terminal / Automations / Skills rows
  and workspaces whose tabs read like conversations (blue activity dots for
  live background sessions); a landing screen with quick-start cards and
  recent commands from your shell history; a composer bar carrying the
  workspace, host, and the focused session's git branch.
- **Dockable panels** — a terminal dock along the bottom and a browser or file
  panel down the right, opened independently from the toggles at the top right
  of the content area, with draggable dividers whose sizes persist.
- **Workspaces → tabs → splits** — arbitrary horizontal/vertical split trees
  per tab, snapshotted to Application Support and restored on launch. A tab
  with one pane renders flush; focus rings appear only once it is split.
- **Scriptable browser** — an embedded WKWebView usable as a tabbed right
  panel or a split pane, with page zoom, print and a scoped "clear browsing
  data", and drivable from the API (navigate, click, fill, read text, wait for
  a selector, screenshot) for testing a web UI from an agent.
- **Remote sessions and files** — SSH/Mosh terminal sessions to saved hosts
  (with reconnect), plus a Finder-style file pane that browses this Mac or any
  saved host over SFTP, with upload, download, and drag-and-drop.
- **Local scripting API + CLI** — a Unix-socket JSON API and the `iterminalctl`
  command for creating workspaces, splitting panes, sending input, and driving
  the browser, plus an event stream plugins and agents can subscribe to.
- **Command palette** — ⌘K, fuzzy search over every action.
- **Settings for everything** — General, Appearance, Terminal (theme, font,
  cursor, scrollback, GPU), Panels, Connections, Security, Sync, Shortcuts, and
  Advanced, all applying live.
- **AI seam** — the composer reserves `@ai …` and the app ships an
  `AssistantService` protocol; a real assistant plugs in without UI changes.

## Requirements

- macOS 14 (Sonoma) or later, Intel or Apple Silicon (universal binary)
- Xcode 16 or later (SwiftTerm's manifest uses Swift tools 6.0)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Running it

It's a native macOS app, so it needs a Mac (14+, Intel or Apple Silicon).
There are two ways to get it running.

### Download a build (no Xcode needed)

Every green CI run publishes the built app. Open the
[Actions tab](https://github.com/JUPiTER-JVCK/iTERMiNAL/actions), click the
most recent successful **Build** run, and download **iTERMiNAL-app** from the
Artifacts section. Then:

```sh
unzip iTERMiNAL.zip
xattr -dr com.apple.quarantine iTERMiNAL.app   # see note below
open iTERMiNAL.app
```

These builds are **unsigned**, and macOS quarantines anything downloaded
through a browser — so without that `xattr` line Gatekeeper refuses to open
it ("damaged or can't be verified"). Right-click → Open works too. Signing
properly needs an Apple Developer ID, which this project doesn't have yet.

### Build from source

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
| `browser.open` / `newTab` / `navigate` / `eval` / `click` / `fill` / `text` / `html` / `wait` / `screenshot` | `url`, `selector`, `value`, `script`, `timeout`, `path`, `pane` |
| `files.list` | `path`, `connection`, `hidden` |
| `connection.list` | — |
| `terminal.reconnect` | `session` |
| `subscribe` / `unsubscribe` | `events` |

The wire protocol is newline-delimited JSON over a Unix socket, so any language
can speak it:

```jsonc
// request
{"id":"1","token":"…","command":"terminal.send","params":{"text":"ls\n"}}
// response
{"id":"1","ok":true,"result":{"session":"…"}}
```

### Event stream

Subscribe and the connection stays open, pushing a frame per event — this is
what plugins and agents hook into:

```sh
iterminalctl subscribe
iterminalctl subscribe events=session.exited,tab.created
```

```jsonc
{"event":"session.exited","data":{"session":"…","exitCode":0,"remote":true}}
```

| Event | Fires when |
| --- | --- |
| `session.started` / `session.exited` | a session launches or its process ends |
| `session.directory` / `session.title` | the shell reports a new cwd or title |
| `session.activity` | a session repaints (debounced to 4/sec) |
| `session.link` | the user clicks a link in a terminal |
| `tab.created` / `tab.closed` / `tab.selected` | tab lifecycle |
| `workspace.created`, `pane.split`, `pane.closed` | layout changes |
| `browser.navigated` | a browser pane finishes loading |
| `browser.tab.created` / `browser.tab.closed` | browser panel tab lifecycle |
| `dock.session.created` / `dock.session.closed` | terminal dock lifecycle |

## Remote sessions and files

Add hosts in **Settings → Connections**, then open one from the sidebar's
**Connect** row, the composer's `+` menu, or the palette. Transport can be
`ssh`, `mosh`, or a custom command (which is how Tailscale SSH or Eternal
Terminal fit — `%h`, `%p`, `%u`, `%d` expand to host, port, user, and
user@host). The same hosts appear in the Files panel's source menu for SFTP.

Both features run the system's own clients, reusing your `~/.ssh/config`,
`known_hosts`, agent, and keys — this app never stores, prompts for, or
transmits an SSH password. A terminal session has a real TTY, so `ssh` can ask
you for a password or 2FA code itself; the file browser runs `sftp`
non-interactively and therefore **requires key-based authentication**.

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
- **No sandbox, but Hardened Runtime is on.** A terminal exists to launch your
  programs, and sandboxed children inherit the sandbox — a sandboxed build
  could not read `~/.ssh`, Homebrew tools, or repos outside its container. No
  general-purpose terminal ships sandboxed. Hardened Runtime is the part
  notarization actually requires, and it doesn't restrict spawned processes.

## Keyboard shortcuts

| Action | Keys |
| --- | --- |
| Command palette | ⌘K |
| New terminal tab | ⌘T |
| New workspace | ⇧⌘N |
| Split right / down | ⌘D / ⇧⌘D |
| Split with browser | ⇧⌘B |
| Close pane / tab | ⇧⌘W / ⌥⌘W |
| Terminal dock | ⌘J |
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
- [ ] Pane attention notifications (OSC 9/777) via the event bus
- [ ] Editable key bindings
- [ ] iCloud sync (needs a signing/entitlement story)
- [ ] Optional libghostty engine
- [ ] Signed/notarized releases

## License

MIT — see [LICENSE](LICENSE).
