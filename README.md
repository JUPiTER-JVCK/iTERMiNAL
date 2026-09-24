# iTERMiNAL

A native macOS terminal with a chat-app shell: a conversation-style sidebar of
workspaces and tabs, a rounded composer bar, sliding side panels for an
embedded web browser and a file browser (local or remote over SFTP), split-pane
layouts that survive relaunch, and a local scripting API so agents and scripts
can drive it.

Built in Swift with SwiftUI/AppKit on top of
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — a real VT100/xterm
terminal (vim, htop, and ssh all work), not a command runner. No Electron.

> **Just want to run it?**
> [**Download the app**](https://github.com/JUPiTER-JVCK/iTERMiNAL/releases)
> — the newest build is at the top of that page. For the newest *version*
> rather than the newest build, [releases/latest](https://github.com/JUPiTER-JVCK/iTERMiNAL/releases/latest).
> The green **Code** button above gives you the source tree, not the app.

## Features

- **Real terminal emulation** — PTY-backed login shell, full ANSI/xterm
  support, alternate-screen apps, configurable scrollback and cursor style,
  and an opt-in Metal GPU renderer.
- **Chat-style shell** — sidebar with New terminal / Automations / Skills rows
  and workspaces whose tabs read like conversations (blue activity dots for
  live background sessions); a landing screen with quick-start cards and
  recent commands from your shell history; and a floating composer that types
  into whichever terminal has focus — drag it anywhere, minimise it to a pill,
  and recall earlier commands with the arrow keys. The chip above the input
  names the terminal it will run in, and switches it to a private shell of its
  own if you want one.
- **Dockable panels** — a terminal dock along the bottom and a browser or file
  panel down the right, opened independently from the toggles at the top right
  of the content area, with draggable dividers whose sizes persist. A dock tab
  can be a local shell, a saved connection, or a running shell moved down from
  a pane, and it reopens as whatever it was.
- **Task manager** — every shell the app is running, wherever it lives: tab
  panes, the terminal dock, and the composer. Uptime while alive, exit code
  once it isn't, and one click to jump to it or stop it.
- **System monitor** — live CPU, memory, GPU and network for the machine along
  the bottom right of the window; hover for the detail, including the app's own
  footprint. Switch it off in Settings → Appearance and the sampling stops too.
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
- **Quick connect** — the sidebar's Connect menu lists saved hosts, saved
  screen-sharing endpoints, and whatever the local network is advertising right
  now. VNC and RDP open through the system's own client; SSH, SFTP and web open
  in the app.
- **Notes panel** — a scratchpad beside the terminal (⌥⌘N), saved as you type
  and kept out of exported snapshots.
- **superfile and btop, built in** — two icons at the top right, left of the
  panel toggles, open [superfile](https://github.com/yorukot/superfile) (a
  terminal file manager, ⌥⌘S) and [btop](https://github.com/aristocratos/btop)
  (a resource monitor, ⌥⌘P) in the side panel. Both ship inside the app,
  nothing to install, and both wear the terminal's colours — light, dark, and
  every change between. See [Bundled tools](#bundled-tools).
- **Proxmox VE** — list the VMs and containers on a cluster over its API, open
  a guest's console in the browser panel, and save a guest as an SSH host. The
  API token's secret half stays in the keychain; a self-signed certificate is
  handled by pinning one you confirm, never by relaxing trust.
- **Local scripting API + CLI** — a Unix-socket JSON API and the `iterminalctl`
  command for creating workspaces, splitting panes, sending input, and driving
  the browser, plus an event stream plugins and agents can subscribe to.
- **Command palette** — ⌘K, fuzzy search over every action.
- **Settings for everything** — General, Appearance, Terminal (theme, font,
  cursor, scrollback, GPU), Panels, Connections, Security, AI, Backup,
  Shortcuts, and Advanced, all applying live.
- **AI assistant** — type `@ai …` in the composer to ask an OpenAI-compatible
  endpoint (OpenAI, Ollama, or any `/v1` proxy). Keys stay in the keychain;
  replies appear above the input and are never auto-run in a PTY.

## Requirements

- macOS 14 (Sonoma) or later, Intel or Apple Silicon (universal binary)
- Xcode 16 or later (SwiftTerm's manifest uses Swift tools 6.0)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Running it

It's a native macOS app, so it needs a Mac (14+, Intel or Apple Silicon).
There are two ways to get it running.

### Download a build (no Xcode needed)

From [Releases](https://github.com/JUPiTER-JVCK/iTERMiNAL/releases), where the
newest is at the top. Every green build of `main` publishes its own
**Build _n_** — an optimised Release build, the same configuration a shipped
copy would be — and version tags get a release of their own with a changelog.

Version releases are the only ones with a fixed link:
[`releases/latest`](https://github.com/JUPiTER-JVCK/iTERMiNAL/releases/latest)
resolves to the newest of them, since they are the releases *not* marked as
prereleases. Per-build downloads have no rolling link — this repository has
immutable releases enabled, so a tag can back exactly one release for all time
and cannot be reused, which is why each build gets a tag of its own.

```sh
unzip iTERMiNAL-*.zip
xattr -dr com.apple.quarantine iTERMiNAL.app   # see note below
open iTERMiNAL.app
```

These builds are **unsigned**, and macOS quarantines anything downloaded
through a browser — so without that `xattr` line Gatekeeper refuses to open
it ("damaged or can't be verified"). Right-click → Open works too. Signing
properly needs an Apple Developer ID, which this project doesn't have yet.

To try a branch that hasn't merged, the same app is attached to every CI run
as the **iTERMiNAL-app** artifact under the
[Actions tab](https://github.com/JUPiTER-JVCK/iTERMiNAL/actions). Prefer a
release where one exists: artifacts expire after 90 days and are buried inside
a workflow run, while a release keeps its link forever and sits in the repo
sidebar.

While this repository is private, both routes need a GitHub account with
access to it. Making the repository public is what turns the release link into
one anybody can open — artifacts would still require an account even then.

### Build from source

```sh
brew install xcodegen
xcodegen generate
open iTERMiNAL.xcodeproj
```

Then build and run the `iTERMiNAL` scheme. CI builds every push on a macOS
runner (`.github/workflows/build.yml`).

### Cutting a release

Two routes, and neither needs `MARKETING_VERSION` bumped in `project.yml` — CI
overrides it from the version being released, so the About box always agrees
with the release it came from.

**From the Actions tab.** Run the **Build** workflow with a `version` input
(`0.112` or `v0.112` — the `v` is optional). It builds first and only then
creates the tag and the release, using `GITHUB_TOKEN` from inside the run.

This exists because pushing a tag is not something every client driving this
repository can do. The Claude Code GitHub relay refuses `refs/tags/*` writes
and the releases API outright, so an agent can open and merge pull requests but
cannot cut a release. `GITHUB_TOKEN` inside Actions is not subject to that.

**Or push a tag**, if you have a checkout and the access:

```sh
git tag v0.112 && git push origin v0.112
```

Either way CI publishes the zip with a generated changelog, and the changelog
runs from the previous `v*` tag — stated explicitly, because the default
baseline would be the `build-*` prerelease published minutes earlier at the
same commit, which is no range at all.

The version is checked before anything is built: the workflow refuses a tag
that already exists or is not shaped like a version. That check is not
politeness. This repository has immutable releases enabled, so a tag name that
has ever backed a published release is reserved permanently — a typo cannot be
deleted and retried, which is how `latest` was burned here for good.

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

## Ghostty configuration

The same twenty palettes, exported for [Ghostty](https://ghostty.org), with a
config that carries the rest of the design — muted slate-green background over
the usual black, Nerd Font, padding, translucency, tinted split dividers — plus
matching btop, starship, yazi, fzf and fastfetch configs.

```sh
cd contrib/ghostty && ./install.sh --extras
```

The themes are generated from `TerminalTheme.swift`, so a scheme looks the same
in both terminals — and `--theme` re-themes the companions too, so btop and
starship follow the terminal rather than staying one palette behind:

```sh
./install.sh --extras --theme iterminal-tokyo-night
```

See [`contrib/ghostty/README.md`](contrib/ghostty/README.md).

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
| `session.attention` | bell / OSC 9 / 777 from a pane (debounced ~1s; separate from activity) |
| `session.link` | the user clicks a link in a terminal |
| `tab.created` / `tab.closed` / `tab.selected` | tab lifecycle |
| `workspace.created`, `pane.split`, `pane.closed` | layout changes |
| `browser.navigated` | a browser pane finishes loading |
| `browser.tab.created` / `browser.tab.closed` | browser panel tab lifecycle |
| `dock.session.created` / `dock.session.closed` | terminal dock lifecycle (`connection` set on a remote tab) |
| `dock.session.moved` | a running shell was moved from a pane into the dock |

From an unfocused pane (or while the app is in the background), try:

```sh
printf '\a'                                          # bell
printf '\033]9;build done\007'                      # OSC 9
printf '\033]777;notify;title;body\007'             # OSC 777
```

With **Settings → Terminal → Notifications** set to in-app (default), the
sidebar shows a blue attention mark. System banners require the in-app +
system mode.

## Remote sessions and files

Add hosts in **Settings → Connections**, then open one from the sidebar's
**Connect** row, the composer's `+` menu, the terminal dock's `+` menu, or the
palette. Transport can be
`ssh`, `mosh`, or a custom command (which is how Tailscale SSH or Eternal
Terminal fit — `%h`, `%p`, `%u`, `%d` expand to host, port, user, and
user@host). The same hosts appear in the Files panel's source menu for SFTP.

Both features run the system's own clients, reusing your `~/.ssh/config`,
`known_hosts`, agent, and keys — this app never stores, prompts for, or
transmits an SSH password. A terminal session has a real TTY, so `ssh` can ask
you for a password or 2FA code itself; the file browser runs `sftp`
non-interactively and therefore **requires key-based authentication**.

### Screen sharing, and what the network is advertising

**Settings → Connections** has two sections beyond saved SSH hosts.

**On this network** browses Bonjour for `_rfb._tcp` (VNC / Apple Screen
Sharing), `_ssh._tcp`, `_sftp-ssh._tcp` and `_http._tcp`, so a machine already
advertising itself can be reached without typing an address. It browses only:
nothing about this Mac is advertised, and no connection is opened until you
pick a result. A Bonjour listing names a *service*, not a host, so the address
behind it is looked up at the moment you connect rather than while listening.
macOS asks for local network access the first time; declining leaves the list
empty and changes nothing else. Discovery starts when you open that section or
the sidebar's **Connect** menu, so a user who never does is never asked.

**Screen sharing and remote desktop** holds endpoints saved by hand. iTERMiNAL
implements neither VNC nor RDP — it hands the address to whichever app has
registered the scheme (Screen Sharing for `vnc://`, Microsoft Remote Desktop or
similar for `rdp://`), so that client is what authenticates and no password is
stored here. If nothing has registered the scheme, you are told, rather than
the button appearing to do nothing.

SSH, SFTP and web entries open inside the app instead — a terminal tab, the
Files panel, and the browser panel.

### Proxmox VE

**Settings → Connections → Proxmox** takes an endpoint and an API token id
(`user@realm!tokenid`); the token's secret half goes to the keychain, and the
host record itself carries no secret — the same rule saved SSH hosts follow.

Discovery is API-driven, not a port scan. Proxmox does not leave a VNC port
listening per VM — a console is created on demand by `vncproxy` behind a
one-time ticket — and it never exposes a guest's RDP at all, since that is a
service inside the guest on the guest's own address. A scan would find almost
nothing and miss every VM worth listing, so the app reads `/nodes`, then the
`qemu` and `lxc` guests per node, and asks the guest agent for addresses. No
agent means no address, not a failed refresh.

From the list, a guest's console opens in the app's browser panel (Proxmox
already serves noVNC over its own web UI, so there is no VNC client involved),
and a guest with a reported address can be saved as an SSH host in one click.

**Certificates.** A default Proxmox install serves a self-signed certificate,
and this app's ATS exemption covers web content only — which relaxes transport
*policy*, not certificate *trust* — so neither the API calls nor the console
page would load. Rather than disabling validation or widening the exemption,
which would weaken every connection the app makes, the system's verdict is
tried first and you confirm a SHA-256 fingerprint once; exactly that
certificate is then accepted, for that host and port alone. A host with a real
certificate needs no pin. The pin is honoured by both the API client and the
browser panel, because WKWebView runs its own trust evaluation and never
consults URLSession's delegate.

## Security model

- **The scripting API is opt-in.** It ships disabled, with separate toggles for
  sending terminal input and controlling the browser.
- **The socket is user-only**: mode 0600 inside a 0700 directory, and every
  request must carry a 256-bit token held in your keychain and compared in
  constant time.
- **Secrets live only in the keychain** — never in preferences, the saved
  layout, or exported snapshots.
- **The assistant sends only what you switch on.** Working directory, git
  branch and workspace name travel by default; the visible terminal screen
  does not, and has to be turned on in Settings → AI. Nothing redacts secrets
  from that screen, so it is off until you say otherwise.
- **App Transport Security stays on**, with two narrow exemptions: web-view
  content, so the browser pane can preview a plain-http dev server, and local
  networking, so the assistant can reach a model server on loopback. Anything
  routable still has to be HTTPS.
- **Certificate validation is never disabled.** A self-signed Proxmox host is
  reached by pinning the one certificate you confirmed by fingerprint, for that
  host and port alone — the system's own verdict is tried first, so pinning can
  only ever *add* an accepted certificate, never subtract a check.
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
| Browser / Files / Notes panel | ⌥⌘B / ⌥⌘F / ⌥⌘N |
| superfile / btop | ⌥⌘S / ⌥⌘P |
| Focus composer | ⇧⌘R |
| Minimise / expand composer | ⇧⌘M |
| Task manager | ⌥⌘T |
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
│   ├── Remote/      Proxmox VE client, Bonjour discovery, remote services
│   ├── API/         Unix-socket server, message envelope, command router
│   ├── Security/    keychain wrapper
│   ├── Backup/      workspace snapshot archive, export/import
│   ├── Settings/    preferences store + settings window
│   └── AI/          AssistantService + OpenAI-compatible client
└── iterminalctl/    command-line client, bundled into the app
```

The terminal backend sits behind `TerminalEngine`
(`Sources/iTERMiNAL/Terminal/TerminalEngine.swift`) and the file backend behind
`FileSystemProvider` (`Sources/iTERMiNAL/Files/FileSystemProvider.swift`), so
either can be swapped (libghostty, an in-process SSH stack) without touching
the UI.

## AI assistant (`@ai`)

Configure a provider in **Settings → AI**, then type `@ai …` in the composer.
Replies appear in a banner above the input — suggested commands are never
executed automatically.

### OpenAI

1. Preset **OpenAI** (base URL `https://api.openai.com/v1`).
2. Pick a model (default `gpt-4o-mini`).
3. Paste an API key and click **Save Key** (stored in the keychain as
   `assistant.apiKey`, never in preferences or export snapshots).

### Ollama (local)

1. Run Ollama and pull a model, e.g. `ollama pull llama3.2`.
2. In Settings → AI, choose **Ollama (local)** or set the base URL to
   `http://127.0.0.1:11434/v1`.
3. Set the model name to match (e.g. `llama3.2`). No API key is required for
   localhost. Plain HTTP works here only because ATS is given the
   `NSAllowsLocalNetworking` exemption, which covers loopback and local-link
   addresses alone — a LAN hostname over plain HTTP is still refused.

## Backup and restore

Workspaces and preferences live on this Mac, under Application Support.
Settings → Backup shows where, and moves them: **Export Workspaces…** writes a
single `.iterminal` JSON snapshot, **Import Workspaces…** reads one back and
replaces the current layout.

A snapshot carries workspaces, tabs, the split layout, and non-secret
preferences. It deliberately leaves out secrets — the API token stays in the
keychain, SSH has no passwords to carry — and machine-local paths such as
`composerShell`, so importing on another Mac cannot point the app at a shell
that isn't there. Terminal scrollback is excluded too: transcripts stay in
their own 0600 files on this Mac.

There is no background sync and nothing leaves the machine unless you export
it. An earlier version offered iCloud through CloudKit; it needed an Apple
Developer iCloud container to bind, so it was visible in every build and usable
only in a signed one, and it has been removed along with the app's entitlements
file. App Sandbox stays off; Hardened Runtime stays on.

## Bundled tools

Two third-party programs ship inside `iTERMiNAL.app`, in
`Contents/Resources/Tools`, and open from the icons at the top right:

| Tool | What it is | Licence | How it gets into the app |
| --- | --- | --- | --- |
| [superfile](https://github.com/yorukot/superfile) (`spf`) | Terminal file manager | MIT | Upstream's macOS release binaries for both chips, checked against pinned SHA-256 hashes that were matched to upstream's own checksums file, merged into one universal binary |
| [btop](https://github.com/aristocratos/btop) | Resource monitor | Apache-2.0 | Built by CI from a pinned commit — upstream publishes no macOS binaries — with Homebrew's GCC 15, once per chip on a native runner |

Selecting an icon starts the tool in the side panel; turning it off, or
closing its panel, ends the process. Putting the whole panel region away
leaves it running. superfile opens in the directory of the terminal you were
using. The composer never types into either of them: with one focused, it
sends commands to the tab behind it instead.

Both need room, and fall back to a "too small" message when squeezed, so the
panel widens to at least 640pt while one is in front — capped so your terminal
keeps its minimum — and returns to your usual width when you switch back to
Browser, Files or Notes.

**They wear the terminal's colours**, and change with it — a new theme in
Settings, or the Mac switching between light and dark:

- superfile is given a theme written in the terminal's ANSI palette, with its
  background and body text left to the terminal, so what it draws *is* the
  terminal's palette and restyles the moment that changes. Code previews are
  the exception: the highlighter needs literal colours, so the preview style
  (matched to the terminal theme by name where one exists) updates the next
  time superfile starts.
- btop only accepts literal colours, so it gets a theme generated from the
  palette — background left to the terminal — and is sent `SIGUSR2`, btop's
  own reload signal, whenever the palette changes.

Their settings live in `~/Library/Application Support/iTERMiNAL/Tools` and are
passed on the command line, so a copy of either tool you installed yourself
keeps its own configuration. The one file written elsewhere is superfile's
`iterminal.toml`, in superfile's theme folder, since that is the only place it
reads themes from. The bundled superfile also doesn't check GitHub for updates:
its version moves with this repository.

**Icons render with any font.** superfile draws file and folder icons from
[Nerd Font](https://www.nerdfonts.com) code points, which no macOS font has, so
they showed as boxes. The app bundles *Symbols Nerd Font Mono* (MIT; the icon
sets' own credits ship beside it) and puts it behind the terminal font as a
fallback, the way Ghostty and WezTerm do. It is used only for characters your
font has no glyph for, in every terminal — prompts like Starship benefit too —
and is registered for this app alone: nothing is installed on your Mac. CI
checks, on a real Mac, that the icons resolve to it.

**What makes bundling safe.** btop links GCC's runtime statically —
`STATIC=true`, plus `CXX_IS_CLANG=false` to get past a bug in btop's Makefile
that otherwise makes that setting a no-op on macOS — and CI refuses any build
that links a library outside `/usr/lib` and `/System/Library`: a binary that
loads Homebrew's `libstdc++` would run in CI and on no one else's Mac. CI then checks
both tools *in the finished bundle*: present, executable, both architectures,
system-only linkage, and that they actually run.

**Versions** live in `scripts/tools.env` and move only by a PR that edits it;
nothing updates itself or is downloaded at runtime. Settings → Advanced lists
the bundled versions and opens each licence. The tools take the download from
about 5 MB to about 35 MB; btop accounts for about 3 MB of that, superfile the
rest. The symbols font adds about 1.5 MB more.

**Deliberately not done:** btop's README recommends setting it suid-root so it
can show every user's processes. It does not run that way here — a suid-root
binary inside an app bundle is a privilege-escalation risk — so btop shows
full detail for your own processes and less for others'.

A local Xcode build works without the tools and the font, and says so in their
panels and in Settings. To include them, on a Mac:

```sh
scripts/fetch-superfile.sh                 # needs curl, lipo, codesign
brew install gcc@15 make && scripts/build-btop.sh Vendor/Tools   # this Mac's arch only
scripts/fetch-symbols-font.sh              # needs curl; runs anywhere
```

## Roadmap

- [x] AI assistant behind the `@ai` composer prefix (OpenAI-compatible; no tool calling)
- [x] Pane attention notifications (OSC 9/777) via the event bus
- [ ] Editable key bindings
- [x] Workspace snapshots: export/import with no account required
- [ ] Optional libghostty engine
- [ ] Signed/notarized releases

## License

MIT — see [LICENSE](LICENSE).
