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

## Screenshots

<p align="center">
  <img src="docs/images/workspace.png" width="900" alt="The iTERMiNAL window: an icon rail and a Workspaces sidebar with a pinned tab, a terminal showing a git history graph, and the floating composer with a command typed into it, coloured as it is typed.">
</p>

A tour of the app in thirty-four pictures, in five groups.

### The window

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/split-panes.png" alt="One tab split into three panes: a terminal listing git history, a terminal showing a request log, and the file browser.">
      <br><b>Split panes</b> — terminals and the file browser side by side in one tab. The layout is saved and comes back when you relaunch.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/dock.png" alt="The window with the terminal dock open along the bottom: two tabs, the first showing git status and the last five commits, under the main terminal and the composer.">
      <br><b>Terminal dock</b> — a row of shells along the bottom, each its own tab, under whatever is open above.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/tasks.png" alt="The task manager listing seven running shells, each with the command it is running, where it lives, how long it has been going, and Go to and Stop buttons.">
      <br><b>Task manager</b> — every shell the app is running, wherever it lives, with how long it has been going and one click to jump to it or stop it.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/command-palette.png" alt="The command palette: a search box over a list of actions — New Terminal Tab, New Workspace, Split Right, Split Down, Split with Browser, Split with Files — each with its shortcut.">
      <br><b>Command palette</b> — every action in one searchable list, with its shortcut beside it.
    </td>
  </tr>
</table>

### The terminal

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/terminal-context-menu.png" alt="The menu a right-click on a terminal opens: Copy, Paste and Select All, then Find and Clear Scrollback, then Split Right, Split Down and New Tab, each with its shortcut.">
      <br><b>Right-click menu</b> — Copy, Paste, Select All, Find… and Clear Scrollback, and, for a terminal that is a tab or a pane, the split and new-tab commands. Copy is greyed out until something is selected.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/terminal-colors.png" alt="A terminal after ls -AF: folders in bold blue, a symbolic link in bold cyan, a script in bold green, and the other files plain.">
      <br><b>Colored <code>ls</code></b> — folders, links and programs, in the colors of the terminal theme. Nothing to install: the app sets the variables <code>ls</code> reads. See <a href="#colored-output">Colored output</a>.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/terminal-colors-man.png" alt="The ls man page in less: headings and option names in red, the words you fill in in green.">
      <br><b>Colored man pages</b> — headings and options in red, what you fill in in green, from the same environment.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/terminal-tools.png" alt="A terminal after imgcat, bat and rg: a green-to-blue picture with a white disc drawn in the terminal itself, then main.rs listed by bat with line numbers and syntax colours, then the line rg found with the match in red.">
      <br><b>Command-line tools</b> — <code>rg</code>, <code>bat</code> and <code>imgcat</code> ship inside the app and are on every terminal's <code>PATH</code>. Here: a picture drawn in the terminal, a source file with syntax colours, and a search hit. See <a href="#command-line-tools">Command-line tools</a>.
    </td>
  </tr>
</table>

### The composer and the assistant

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/composer-history.png" alt="The composer with “git” typed into it and a list of earlier git commands above, with the keys that work in the list underneath.">
      <br><b>History search</b> — ⌃R lists earlier commands that match what you have typed; ↑↓ choose, and ↩ puts the choice in the input without running it.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/ai-assistant.png" alt="A reply from the assistant above the composer: a sentence of explanation, two git commands in a block with a warning that they throw away uncommitted changes, Insert and Copy buttons, and a closing tip.">
      <br><b>Ask the assistant</b> — start a line with <code>@ai</code> and the reply appears above the composer. A command in it can be put in the input or copied; only you pressing ↩ runs anything.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/error-help.png" alt="A failed make command in the terminal and, above the composer, a line reading “That looked like an error” with Explain and Fix it buttons.">
      <br><b>Explain / Fix it</b> — when a command prints something that reads like an error, the composer offers to explain it or suggest a fix. Nothing is sent until you choose one.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/settings-ai.png" alt="Settings, AI page: the provider preset (Ollama, local), its base URL and model, and the API key, which a local address does not need.">
      <br><b>AI settings</b> — any OpenAI-compatible endpoint, a model on this Mac included. A local one needs no key; a key, when there is one, is kept in the Keychain.
    </td>
  </tr>
</table>

### Panels and tools

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/http-client.png" alt="The HTTP client panel after a GET request: the method and address, two headers, and the 200 response with its timing, size and pretty-printed JSON body.">
      <br><b>HTTP client</b> — build a request, send it, and read the status, timing and formatted body.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/site-explorer.png" alt="The site explorer in the HTTP panel: a command-line session that opens a local site, lists its top-level paths with where each was declared, and prints a tree of /docs.">
      <br><b>Site explorer</b> — walk what a site publishes (its <code>robots.txt</code>, its sitemaps and the links in pages you fetch) like a directory. It never guesses at paths.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/extract-images.png" alt="The Extract tab on the Images list of a fetched page: six images, each with a small picture, its description, address and size, three ticked, and Filter, Previews, All, Download and Export controls beneath.">
      <br><b>Extract</b> — read a response into lists you can filter, copy, save and download from: links, images (with previews, if you turn them on), video and audio, files, tables, text.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/extract-query.png" alt="The Extract tab's query box: a CSS selector, img::attr(src), and the four image addresses it found, each with its element.">
      <br><b>Query</b> — ask the response a question in CSS selectors, XPath, JSONPath or a regular expression, and take the answers as a list. See <a href="#extract">Extract</a>.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/extract-crawl-confirm.png" alt="The crawl sheet: the site, up to 25 pages, 2 links deep, a second between requests, an option to stay under the page's folder, and four lines on what it will and won't do.">
      <br><b>Crawl</b> — follow a page's own links to the rest of its site, after a sheet that says how far, how fast, and what it will and won't do.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/extract-crawl.png" alt="The crawl's pages: each address reached with its status, title and depth, and the one robots.txt rules out listed as left alone.">
      <br><b>What a crawl reached</b> — one page at a time, <code>robots.txt</code> first and obeyed: the page it rules out is listed, not fetched. See <a href="#extract">Extract</a>.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/extract-ask-confirm.png" alt="The Ask sheet: a request, the question that would be sent and where, and a disclosure for every character of it.">
      <br><b>Ask the assistant</b> — says where the page's text would go, and shows every character of it, before anything is sent.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/extract-ask.png" alt="The assistant's answer as a table of regions with revenue and costs, labelled as written by the assistant.">
      <br><b>Rows from a page</b> — the answer as a table of text, labelled as a model's. It is only ever shown: nothing in it is run, opened or fetched.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/extract-download-confirm.png" alt="The download sheet: four files from localhost, the folder they will go in, the size limit, and a line saying one more will not be fetched.">
      <br><b>Download</b> — says which sites, which folder, and what will not be fetched (and why) before anything is requested.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/extract-crawl-links.png" alt="The links found on the crawled pages, each once with how often it came up and the first page it was found on.">
      <br><b>What a crawl found</b> — every link, image, video and file on the pages it reached, each once, with the page it was first found on, in the same lists as above.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/browser.png" alt="The browser panel beside a terminal: three tabs with the pages' titles, an address bar, and the sample site's home page.">
      <br><b>Browser</b> — a tabbed web view in a panel or a split pane, which the local scripting API can drive.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/files.png" alt="The file browser panel beside a terminal, listing the sample project's folders and files with their modification times.">
      <br><b>File browser</b> — this Mac or any saved SFTP host, in a panel or a split pane.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/files-sftp-denied.png" alt="The file browser after a refused sign-in: Couldn't sign in to deploy@127.0.0.1, why, five numbered steps with commands to copy, and the buttons Try Again, Set Up Key, Sign In in a Terminal and Connection Settings.">
      <br><b>When a host won't let you in</b> — what went wrong, what to do in order, and a button for the next move. See <a href="#when-a-host-cant-be-reached">When a host can't be reached</a>.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/files-sftp-shared.png" alt="The file browser listing a host after a terminal tab signed in to it, with a link icon beside the path.">
      <br><b>A host that wants a password</b> — sign in once in a terminal tab, where the password goes to <code>ssh</code> and not to the app, and the file browser uses that connection. See <a href="#a-host-that-wants-a-password">A host that wants a password</a>.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/superfile.png" alt="superfile, the terminal file manager, in a panel: a sidebar of places, the sample project's files with icons, and process, metadata and clipboard panels underneath.">
      <br><b>superfile</b> — a terminal file manager, built in and wearing the terminal's colours. See <a href="#bundled-tools">Bundled tools</a>.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/btop.png" alt="btop, the resource monitor, in a panel: CPU, memory, disk, network and process boxes in the terminal's colours.">
      <br><b>btop</b> — a resource monitor, built in the same way.
    </td>
  </tr>
</table>

### Look, keys and settings

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/light-theme.png" alt="The same window in the light theme: sidebar, terminal and composer in light colours, with the same git history.">
      <br><b>Light theme</b> — the window follows the system's light and dark appearance, or is set to one by hand.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/custom-look.png" alt="The window with the Catppuccin Mocha terminal theme, a purple accent, a rounder frame and a rounded interface typeface.">
      <br><b>Make it yours</b> — a terminal theme, an accent colour, the frame's tint and corner radius, and the interface typeface.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/keyboard-shortcuts.png" alt="The Keyboard Shortcuts window: a search box over the shortcuts, grouped as General and Tabs and panes, each drawn as key caps.">
      <br><b>Keyboard shortcuts</b> — every shortcut in one searchable window, opened with ⌘/.
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/settings-appearance.png" alt="Settings, Appearance page: theme, accent colours, terminal opacity, and a preview of the workspace frame.">
      <br><b>Appearance settings</b> — theme, accent colour, terminal opacity and the workspace frame. The whole Settings window is one colour, the rail and the page alike.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/settings-security.png" alt="Settings, Security page: the local scripting API switch, off, and a list of how the app handles your data.">
      <br><b>Security settings</b> — the local scripting API stays off until you turn it on, and the page says how your data is handled.
    </td>
  </tr>
</table>

<sub>These pictures are taken from the app itself by the [Screenshots workflow](.github/workflows/screenshots.yml), on a macOS runner, against an invented project (`hello-api`), a small web site on localhost, a stand-in for an AI model on localhost, and two SSH servers on localhost — one that lets no one in, and one that takes a single key made for the run — so nothing in them is real data, and the assistant's replies are canned ones, not a model's answers. The superfile and btop pictures show the runner's own files and processes, and the shared-sign-in picture the path of the sample project in its home folder, under its generic `runner` account. To retake them after the interface changes, run that workflow (Actions → Screenshots → Run workflow), download its artifact, and run `python3 scripts/screenshots/publish.py <folder>` on it: that writes these thirty-four into `docs/images/`.</sub>

## Features

- **Real terminal emulation** — PTY-backed login shell, full ANSI/xterm
  support, alternate-screen apps, configurable scrollback, cursor style and
  cursor animation, inline images, and an opt-in Metal GPU renderer.
- **Right-click menu** — right-click a terminal (or the margin around it) for
  Copy, Paste, Select All, Find… and Clear Scrollback, and, for a terminal that
  is a tab or a pane, Split Right, Split Down and New Tab. Copy is greyed out
  until something is selected; Paste goes to the terminal you clicked, even if
  another one had the keyboard; Clear Scrollback drops only the history above
  the screen, so it is safe while a program is running. A program that has
  switched on mouse reporting does not receive the right button (the terminal
  engine never reported it), so the menu takes nothing from it.
- **Colored output** — `ls` prints folders, links and programs in color, and
  `man` pages (and anything read through `less`) get colored headings, options
  and placeholders, with no shell plugin to install: the app gives each local
  shell the environment those plugins set. See
  [Colored output](#colored-output).
- **Links** — ⌘-click a web address in a terminal and it opens in this app's own
  browser pane. Right-click one and the menu leads with the address as it will
  really be opened — a program can print a hyperlink whose text says one thing
  and whose address is another — then **Open Link** (the ⌘-click route), **Open in
  Default Browser** and **Copy Link**. Only `http` and `https` addresses are
  offered for opening; any kind of link can be copied.
- **Cursor animations** — Settings → Terminal → Cursor has an Animation choice
  beside the cursor style: Breathing, Heartbeat, Neon flicker, Pulse and Candle,
  each a fixed table of opacities, so the cursor looks the same on every launch.
  An animation takes the place of the blink while the terminal is the one you are
  typing in. It needs the default renderer — with the opt-in GPU renderer on, the
  cursor stays as its style says — and it is off while Reduce Motion is.
- **Your own fonts** — Settings → Terminal → Font has an **Import Font…** button
  for `.ttf`, `.otf`, `.ttc` and `.otc` files. What you import appears in the
  picker under **Imported**, grouped by family — a family spread over several
  files is one entry — and is listed under the preview with its file name and
  how many styles it holds, each with a Remove button. The preview draws sample
  text — letters, digits, ligature candidates, box drawing and two icon glyphs —
  in the font and size the terminal will use, so a choice shows before it is
  made. An imported font is copied into the app's own folder and registered for
  this app only: nothing is installed on your Mac, it is not in Font Book, and
  removing it here deletes the copy. A file is refused before anything reads it
  if it is not one of those four kinds or is over 50 MB.
- **Terminal opacity** — Settings → Appearance → Window → Terminal opacity
  (20–100 %) lets the desktop show through a terminal's background, softly
  blurred. Text and the cursor stay solid, and so do the chrome, the panels,
  btop and superfile; the frame has its own *Translucent frame* switch.
- **Chat-style shell** — sidebar with New terminal / Automations / Skills rows
  and workspaces whose tabs read like conversations (blue activity dots for
  live background sessions; drag a tab to put it where you want it, or onto
  another project to move it there); a landing screen with quick-start cards and
  recent commands from your shell history; and a floating composer that types
  into whichever terminal has focus — drag it anywhere, minimise it to a pill,
  and recall earlier commands with the arrow keys. It colours what you type —
  commands, flags, strings, variables, pipes — in your terminal theme's colours,
  switching to a palette tuned for the input wherever a theme's own colours
  would not read on it (4.5:1 contrast, checked in CI). A command word is
  coloured if it is a shell builtin, an executable on this app's `PATH` or in
  `~/.local/bin`, `~/.cargo/bin`, `~/bin` or `~/go/bin`, or a path such as
  `./script` that points at an executable file (checked against the terminal's
  directory, for local terminals only). Anything else — an alias or a shell
  function, say — is left plain, never marked wrong. As you type, the rest of
  a command you have run before shows in grey after the caret (→ or ⇥ takes it,
  esc waves it away); ⌃R searches your history, ↑↓ choose and ↩ puts the choice
  in the input without running it; and ⇥ completes file names — filling in what
  the candidates share first, then listing the rest — for terminals on this
  Mac, never for a remote session. Suggestions come from what the composer has
  run and from the tail of your shell's history file (`~/.zsh_history` or
  `~/.bash_history`, up to 512 KB, read locally); they are held in memory, never
  saved, exported or sent anywhere, and a setting turns the file off. Only
  single-line commands are suggested. The chip above the input names the
  terminal it will run in, and switches it to a private shell of its own if you
  want one.
- **Framed window with an icon rail** — one top bar and an icon rail down the
  left edge frame the content, which sits in a rounded card. The rail holds
  Terminal, Workspaces and Connect, with a `···` menu for the rest (Tasks,
  Automations, Skills): each has a pin that puts its icon on the rail. The
  Workspaces panel opens beside the content and can be pinned there, or left
  unpinned to float over it until you pick something or click away (⌃⌘S shows
  or hides it). A button at the bottom left of the frame toggles the terminal
  dock. Settings → Appearance sets the frame's tint, corner radius and edge
  thickness, whether it is translucent or outlined, and the interface
  typeface; a preview there shows the change as you make it.
- **Dockable panels** — a terminal dock along the bottom and a browser, file,
  notes or HTTP panel down the right, opened from the one button at the top
  right (each can also open in full view, across the whole content area), with
  draggable dividers whose sizes persist. A dock tab can be a local shell, a
  saved connection, or a running shell moved down from a pane, and it reopens
  as whatever it was.
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
  saved host over SFTP, with upload, download, and drag-and-drop. A saved host
  can be reached **through jump hosts** — a bastion, or several in a row — by
  the terminal and the file browser alike, and has a choice about **forwarding
  your ssh-agent**: see [Jump hosts and the SSH agent](#jump-hosts-and-the-ssh-agent).
  When a host turns the file browser away it says why and what to do about it — see
  [When a host can't be reached](#when-a-host-cant-be-reached) — and one that
  wants a password can be browsed through a terminal tab you sign in to, without
  this app ever being given the password: see
  [A host that wants a password](#a-host-that-wants-a-password).
- **Edit in Terminal** — right-click a file in the file browser, on this Mac, and
  the menu has **Edit in Terminal**: a new terminal tab in the file's folder,
  with the file open in your editor. Settings → General → Editor chooses which:
  *Automatic* takes the first of Helix (`hx`), Neovim, Vim and Nano that this Mac
  has, or pick one, or write a command of your own (the file's path goes at the
  end). Helix and Neovim are not bundled; the setting says where to get them
  (`brew install helix`, `brew install neovim`) and, under the picker, which
  program it will run — Vim and Nano come with macOS. The line typed into the tab
  names the editor by the absolute path found for it and quotes the file's, and a
  file whose name has a control character in it is refused.
- **Quick connect** — the sidebar's Connect menu lists saved hosts, saved
  screen-sharing endpoints, and whatever the local network is advertising right
  now. VNC and RDP open through the system's own client; SSH, SFTP and web open
  in the app.
- **Notes panel** — a scratchpad beside the terminal (⌥⌘N), saved as you type
  and kept out of exported snapshots.
- **HTTP client** — a request builder and response viewer, as a split pane or
  a right-hand panel (⌥⌘R): method, URL, headers, body; pretty-printed JSON;
  ⌘Return sends from anywhere in the pane; "Copy as cURL"; per-pane history.
  Requests only ever go out over HTTPS, or plain HTTP to this Mac itself —
  never a relaxed ATS exception for an arbitrary host. History is run
  through this app's best-effort secret masking (values that look like
  credentials, not a guarantee) before it touches disk, and stays out of
  exported snapshots.
- **Site explorer** — the HTTP pane's second mode (Request | Explore): type an
  address and walk what the site publishes like a directory, with `ls`, `cd`,
  `tree`, `find`, `get` and Tab completion. See
  [Site explorer](#site-explorer) for what it reads and what it won't.
- **Extract** — the response area's second tab reads the response in hand into
  lists you can filter, copy, save and open: a page's links, images, video and
  audio, files, headings, tables, metadata, structured data and readable text
  (plain or Markdown), and the rows of JSON, CSV and feeds — with a query box
  that speaks CSS selectors, XPath, JSONPath and regular expressions. Images,
  media and files can be downloaded, after a sheet that says from where, into
  which folder, and what will not be fetched. Image previews (off until you turn
  them on), a same-site crawl that obeys `robots.txt`, and **Ask…**, which has your
  AI assistant read the page into rows, are each one click, after a sheet that says
  what they will do. See [Extract](#extract).
- **superfile and btop, built in** — two icons at the top right, left of the
  panel toggles, open [superfile](https://github.com/yorukot/superfile) (a
  terminal file manager, ⌥⌘S) and [btop](https://github.com/aristocratos/btop)
  (a resource monitor, ⌥⌘P) in the side panel. Both ship inside the app,
  nothing to install, and both wear the terminal's colours — light, dark, and
  every change between. See [Bundled tools](#bundled-tools).
- **ripgrep, bat and imgcat, built in** — `rg` (fast regular-expression search),
  `bat` (`cat` with syntax highlighting, paged through `less` when it is longer
  than the screen) and `imgcat` (shows a PNG, JPEG, GIF, HEIC or TIFF in the
  terminal itself) are on the `PATH` of every local terminal, after whatever you
  have installed yourself, so yours is the one that runs. See
  [Command-line tools](#command-line-tools).
- **Proxmox VE** — list the VMs and containers on a cluster over its API, open
  a guest's console in the browser panel, and save a guest as an SSH host. The
  API token's secret half stays in the keychain; a self-signed certificate is
  handled by pinning one you confirm, never by relaxing trust.
- **Local scripting API + CLI** — a Unix-socket JSON API and the `iterminalctl`
  command for creating workspaces, splitting panes, sending input, and driving
  the browser, plus an event stream plugins and agents can subscribe to.
- **Command palette** — ⌘K (or ⌘P), fuzzy search over every command in the
  menus, your saved hosts, the themes and the tabs that are open.
- **Gentle motion** — panels, the dock, banners and the sidebar's sections
  move on springs, and hover and selection in the sidebar, toolbar and dock
  fade instead of flashing. With Reduce Motion on (System Settings →
  Accessibility → Display) the sliding panels, dock and banners fade in place
  and the springs behind them become a short ease. The app follows the setting
  live, so changing it applies without a relaunch. Splitting or closing a pane
  is not animated.
- **Settings for everything** — General, Appearance, Terminal (theme, font,
  cursor, scrollback, GPU), Composer, Panels, Connections, Security, AI, HTTP
  Client, Backup, Shortcuts, and Advanced, all applying live.
- **AI assistant** — type `@ai …` in the composer to ask an OpenAI-compatible
  endpoint (OpenAI, Ollama, or any `/v1` proxy). Keys stay in the keychain;
  replies appear above the input and are never auto-run in a PTY. When a
  command you ran from the composer prints something that reads like an error,
  an **Explain / Fix it** offer appears; a suggested command goes into the
  input for you to review, with a note if it is the kind that is easy to
  regret.

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

This repository is public, so a release opens for anybody. An Actions artifact
still needs a GitHub account to download.

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

## Colored output

Settings → Terminal → **Colored output**, on by default, applies to terminals
opened after you change it. It does what the zsh plugins
[zsh-colored-man-pages](https://github.com/ael-code/zsh-colored-man-pages),
[zsh-colorls](https://github.com/Kallahan23/zsh-colorls) and
[zpm-zsh/colors](https://github.com/zpm-zsh/colors) do, with nothing to install
and for whichever shell the terminal starts — bash and fish get it too. It
wraps and intercepts nothing: it adds a few environment variables, the ones
those commands already read, to each **local** shell.

| Setting | Variables | What you see |
|---|---|---|
| **ls: directories, links and scripts** | `CLICOLOR=1`, `LSCOLORS` | macOS's `ls`: folders in bold blue, symbolic links in bold cyan, programs in bold green, and sockets, pipes, devices, set-id files and writable folders in the usual extra colors. macOS's `ls` colors by kind of file and has no way to color by ending: an archive or a picture is plain there. |
| | `LS_COLORS` | GNU `ls --color` and eza read this instead, and add archives (red), pictures and video (magenta) and audio (cyan) by their ending. |
| **man pages and less** | `LESS_TERMCAP_*`, `GROFF_NO_SGR=1` | Headings, command names and option names in bold red; what you fill in (`file`) in green; `less`'s own status line in yellow on blue. These are the choices zsh-colored-man-pages made. |

- **The theme decides how they look.** Every color is an ANSI palette number,
  never an RGB value, so the output follows a theme change and reads on a light
  theme and a dark one alike. The terminal draws bold in the bright variant of
  a color, so "bold blue" is whatever bright blue the theme has.
- **Anything you set wins.** The variables are set before your shell's startup
  files run, so a `LSCOLORS` or `LESS_TERMCAP_md` in `.zshrc` replaces ours, and
  a variable already present in the environment the app was started with is
  left alone. A non-empty `NO_COLOR` — the convention for "no color, anywhere"
  — switches the whole thing off.
- **Local shells only.** SSH and Mosh sessions, superfile and btop are not
  given any of it.
- **Some commands only color when asked.** `grep` prints its matches plain
  unless it is given `--color`, whatever the environment says, and iTERMiNAL
  does not edit your shell's startup files. Settings → Terminal → *grep, GNU ls
  and other commands* shows the three aliases to add and has a Copy button.
- **What it is not.** The terminal never rewrites output after the fact, and
  nothing here wraps commands in a colorizer the way zpm-zsh/colorize wraps
  them with `grc`. What you type in the composer is colored separately — see
  the composer in [Features](#features). What you type at your shell's own
  prompt is drawn by the shell, so coloring commands, functions and paths there
  is the shell's job: fish does it out of the box, and for zsh it is
  [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting)
  (`brew install zsh-syntax-highlighting`, then the `source` line Homebrew
  prints, in your `.zshrc`).

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
| `pane.list`, `pane.split`, `pane.close` | `direction`, `kind` (`terminal`, `browser`, `files`, `http`) |
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
| `composer.session.created` | the composer started a shell of its own |
| `dock.session.moved` | a running shell was moved from a pane into the dock |
| `http.sent` | an HTTP client pane's request finished — status on success, error on failure |

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
non-interactively, so it signs in **with a key, or through a terminal tab you
have signed in to** ([below](#a-host-that-wants-a-password)).

### Jump hosts and the SSH agent

A saved `ssh` host has two more settings in **Settings → Connections**.

**Jump host(s)** is a chain of hosts to go through on the way — a bastion, or
several in a row — written the way `ssh -J` takes them: `[user@]host[:port]`,
separated by commas, at most five, in the order they are used. The terminal tab
and the file browser both use it (as `-o ProxyJump=…` for `ssh`, `sftp` and
`ssh-copy-id`), so a host that is only reachable through a bastion browses like
any other. What is written is checked before it goes anywhere near a command
line, and what does not pass is refused rather than trimmed into something that
does: the editor says what is wrong in place, and a connection with a bad list
does not connect at all, because one meant to go through a bastion must never
quietly go direct. Only `ssh` uses jump hosts: `mosh` talks to the host directly
over UDP, which a host behind a bastion cannot accept, and a custom command is
yours to write. `ssh` checks each hop's host key against your `known_hosts` as it
always does, and a hop you have never connected to can ask whether to trust it —
a question the file browser, with no terminal to ask on, cannot put. If a listing
through a new bastion fails on its host key, connect to it once in a terminal tab
and ask again.

**Forward SSH agent** is the choice of whether a terminal session lets the host
use the keys in your ssh-agent. Forwarding lets a program on the host — and
anyone who can act as you there, such as root — ask the agent on this Mac to
sign in elsewhere for as long as the connection is open. The keys themselves
never leave this Mac either way; the risk is the use of them. So the default
adds nothing, and the four choices are:

| Choice | What happens |
| --- | --- |
| As in `~/.ssh/config` (default) | Nothing is added; your config decides, as it does for `ssh` outside this app |
| Never | `-o ForwardAgent=no`, even where your config says yes |
| Ask each time I connect | A question before each new tab and each reconnect, with **Don't Forward** as the button Return presses; *Forward Agent* adds `-A`, the other adds `ForwardAgent=no` |
| Always | `-A` on every connection |

That is a choice of *when* to forward: never, per connection, or always. A
prompt for each *use* of a key — what some clients offer as per-request
approval — is not built; see [Considered and left out](#considered-and-left-out).
The file browser does not forward the agent: it has no use for it.

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

A VNC or RDP entry can be set to **Go through** a saved SSH host: the address is
then read as that host sees it, an `ssh` forward carries it to a port on this
Mac's loopback, and the client is pointed there. **Share This Mac's Screen…**
opens System Settings → General → Sharing, where Screen Sharing is switched on;
iTERMiNAL does not change it.

A VNC service can be set to **Open with → Built-in viewer**, which opens the
desktop in a window of this app instead of handing it to Screen Sharing. It is a
small client, on purpose: RFB 3.3 to 3.8, **no authentication or a VNC
password**, raw and copy-rectangle updates, and a desktop that changes size —
each a few lines whose bounds can be read, because every encoding is code that
trusts bytes from a server. Sizes are bounded before anything is allocated and a
rectangle that doesn't lie inside the screen is refused.

- **The password is asked for each time and never kept.** A sheet in the window
  asks; it is used once to answer the server's challenge and dropped. It is not
  saved, logged, or put in the Keychain.
- **Not encrypted, and a weak check.** VNC's password check is DES against a
  challenge anyone watching can read, and the picture crosses the network
  as it is. The window says so; **Go through** a saved SSH host carries it
  through an `ssh` forward, which is the way to use it past a network you trust.
- **macOS Screen Sharing's own sign-in is not supported.** By default a Mac
  offers Apple's authentication, not a password. Turn on *VNC viewers may
  control screen with password* (System Settings → General → Sharing → Screen
  Sharing, ⓘ), or keep the system app for that host. The viewer says this when
  that is all a server offers.
- **Plain updates.** Without compressed encodings the picture is larger on the
  wire than other viewers send, so a local network or a tunnel suits it better
  than a slow link. Clipboard sharing, file transfer, audio and RDP are not
  there; RDP still opens in the system's app.
- Command is the remote machine's Super key and Option its Alt; keys held when
  the window loses focus are released.

### Terminal type, transport options and port forwards

**Settings → Terminal → Terminal type** chooses the `TERM` that local shells and
remote sessions announce — `xterm-256color` (the default), `xterm-ghostty`,
`xterm`, `xterm-color`, `screen-256color`, `tmux-256color`, `vt220`, `vt100` or
`linux` — and a host can override it under **Settings → Connections**. It is
what programs are *told*, not what the terminal can do: the engine is
xterm-compatible whichever is chosen, and naming a type a machine has no
terminfo entry for makes `less`, `vim` and `tput` complain or fall back. The
settings say whether *this Mac* has the entry; they cannot say it for a remote
host, so for `xterm-ghostty` they print the command that teaches one
(`infocmp -x xterm-ghostty | ssh HOST tic -x -`). `COLORTERM=truecolor` is set
only for types that claim 256 colours or more.

**Connections → Terminal and transport** adds, per ssh host, an address family
(`-4`/`-6`), compression (`-C`), a keep-alive (`ServerAliveInterval`) and **port
forwards** — local (`-L`), remote (`-R`) and SOCKS5 (`-D`) — opened with every
ssh terminal tab on that host. Each option is written only when set, so a host
that sets none leaves `~/.ssh/config` in charge. Forwards listen on the
loopback address only, ports and targets are validated before they reach a
command line, and a rule that isn't valid is left out and reported. **Add This
Mac** saves `127.0.0.1` as a host (it needs Remote Login switched on).
**Quick connect** takes `user@host:port`, a pasted `ssh -p 2222 user@host`, or a
pattern — `web[1-3].example.com`, `r[01-10]`, `db-{a,b}.lan` — and opens a tab
for each (up to 8; more are saved but not opened). **Look up a host** shows what
this Mac's own resolver says about a name or an address; nothing goes to a
lookup service.

### Background tunnels

**Settings → Connections → Background tunnels** keeps port forwards — local,
remote or SOCKS5, the same rules a host's tabs can open — running through a
saved host with no terminal tab open. Each is an `ssh -N` of its own: start and
stop it from the list, or mark it to start when iTERMiNAL opens. It signs in
with a key or your agent and never a typed password, so a host that wants one
shows as failed with the reason (**Set Up Key Login** on the host is the fix).
It listens on this Mac's loopback only, fails rather than reusing a port that
is already in use, and ends when you stop it or quit the app; it is not
restarted if the connection drops, and the list says so.

### Lookup (in the HTTP client)

The HTTP client's **Lookup** tab shows what this Mac's own resolver says about
a name or an address: the addresses behind a name, the name behind an address,
and what kind each is (public, private, loopback, link-local, shared
address space). For a *public* address it can also say where it is — but that
sends the address to a third-party service, so it is off until you turn on
**Settings → HTTP Client → IP lookup**, and then happens only when you press
the button, which names the service (default `ipwho.is`; any https service
that takes the address in its URL can be put in its place). Only the address
is sent — never the name you typed — and a private, loopback or reserved
address is never sent at all.

### Remote ports

**Settings → Appearance → Status → Show remote ports** (off by default) puts a
globe at the bottom left of the window, opposite the system monitor. It lists
the TCP ports the focused terminal's machine is listening on — this Mac, or the
saved host the tab is connected to — and choosing one opens it in the browser
panel: directly for this Mac, and through an `ssh` forward on a loopback port for
a host. Nothing is scanned until the list is open; while it stays open it
rescans every five seconds.

The scan and the forwards run with no keyboard: they sign in with a key or the
agent, or ride the connection a terminal tab to that host already has open,
and never a typed password (a host that wants one is told to sign in in a tab
first). A new ssh tab keeps its connection open for them to share — see
[A host that wants a password](#a-host-that-wants-a-password). A port that
is only reachable through one address is forwarded to that address, and the
list says which ports are reachable from outside the machine (all interfaces)
and which are not (this machine only). Process names appear only where the
machine's own tools give them — `ss` and `lsof` show other accounts' sockets
without a name — so a blank name never means nothing owns the port.

### Colors, text and effects

**Settings → Terminal** can override the cursor color, the color of the text
under it and the selection color (each off by default, keeping the theme's), turn
off drawing bold text in bright colors, and set the line height from 0.8× to
1.6×. **Edit a theme** duplicates the current theme into an editable copy — its
background, text and all sixteen ANSI colors, with the changes applied as you
make them — and imported Ghostty themes can be edited the same way. **Settings →
Appearance** takes any accent color beside the six, and an animation speed from
0.5× to 2×.

What these cannot do is limited by the terminal engine (SwiftTerm), which has no
setting for character width, ligatures, a minimum contrast, an always-hollow
block cursor, or the bold and italic faces. Those would need changes to SwiftTerm, so they are not
offered rather than offered and ignored. The interface's own text sizes are fixed
point sizes throughout the views, so there is no global interface scale.

### Ghostty themes

**Settings → Terminal → Ghostty themes → Import Theme Files…** reads Ghostty
theme files (`palette = N=#rrggbb`, `background`, `foreground`) and adds each to
the theme list. Only those colours are read; fonts, keybinds and anything else
in a file are ignored without being interpreted.

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

### When a host can't be reached

The file browser runs `sftp` with no keyboard, so it can fail in ways `sftp`'s
own one-line message does not explain. The commonest is
`Permission denied (publickey,password,keyboard-interactive)`: the server
turned down every key this Mac offered, *and* the file browser has no way to
answer a password prompt, however right the password. The panel used to show
that line, cut short, over an "Empty folder". It now reads what `sftp` said and
shows, in place of the listing:

- the problem in one line, and why it happened;
- what to do, in order, with the commands to copy;
- the buttons that go with it — **Try Again**; **Set Up Key…**, which opens a
  tab on this Mac with the `ssh-copy-id` command typed and *not* run, so you
  press Return and enter the host's password once, in a real terminal;
  **Sign In in a Terminal**, which opens an `ssh` tab the file browser can then
  use; **Forget Old Key…** for a changed host key; and
  **Connection Settings…**;
- the exact words `sftp` used, folded away under **What sftp said**, never
  replaced by the summary.

It tells these apart: a refused sign-in (and which methods the server does
accept), too many keys offered, a changed host key, an identity file that is
missing or readable by others, a refused connection, no answer, no route, a name
that doesn't resolve, a connection closed before sign-in, a host with SFTP off
or a login that prints text, and a folder that is missing or off limits.
Anything else is shown as `sftp` said it, with a Try Again. A failed upload,
download or delete leaves the listing alone and shows a one-line strip with
Details.

**Settings → Connections → Test File Access** signs in the way the file browser
does and shows the same words, so a host can be checked with its settings in
front of you. When a key is named for a host, `ssh` is told to offer only that
one (`IdentitiesOnly=yes`), so a server that allows few attempts doesn't hang
up before reaching it.

### A host that wants a password

The file browser has no keyboard, and iTERMiNAL never handles a password, so it
can't sign in to a host that takes only a password — or a code from a phone — by
itself. It doesn't have to. Sign in to the host in a terminal tab — enter the
password to `ssh`, in a real terminal, as for any session — and the file browser
fills in on its own a couple of seconds later. Any ssh tab to the host will do,
including one you opened earlier: **Settings → Connections → Authentication →
Share each ssh tab's sign-in with the file browser** (on by default, for tabs
opened from now on) starts every ssh tab with `ControlMaster=yes`, so it keeps
its connection open for others, and the file browser's `sftp` joins it
(`ControlMaster=no`) instead of signing in again. **Sign In in a Terminal** on
the message still opens such a tab for you. A small link icon in the file
browser's toolbar says it is using one. While the message is up, the file
browser checks only for that open connection, on this Mac — it sends nothing to
the host, so waiting cannot add failed sign-ins to its log.

To stop needing a tab at all, **Set Up Key Login…** (on the message, as **Set Up
Key…**, and under the host in Settings → Connections) types one command into a
tab: it makes an `ed25519` key if there is none (`ssh-keygen` asks whether to
give it a passphrase), then installs it with `ssh-copy-id`, which asks for the
host's password once. Nothing runs until you press Return, and the password goes
to `ssh`, never to iTERMiNAL. **Try Again** afterwards.

- **The connection is the tab's.** Closing the tab, or `exit`, ends it, and the
  file browser is back to the message until you sign in again. Turn sharing off
  and only **Sign In in a Terminal** (or Remote Ports, if on) shares one. Nothing is left
  running behind it — there is no `ControlPersist`.
- **The socket is yours alone.** It lives in a folder of its own in your
  temporary folder, named for the host, port and user, so a connection is only
  ever shared with its own destination. It is used only if that folder is a real
  folder (not a link) owned by you and closed to everyone else, and only if the
  socket in it is one you made: a socket anyone else could have put there would
  be handed every file that went through it. A socket left behind by an `ssh`
  that was killed is cleared away before a new sign-in listens.
- **It works whatever the saved transport is**: the tab it opens is `ssh`. When
  the transport is `ssh`, the connection's extra arguments go along (so
  `-J bastion` carries the file browser through the jump host too), and a
  `ControlPath` you gave there stays yours — which leaves the file browser no
  socket of the app's to join.
- **A key is still better** where you can have one: nothing needs to stay open.

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
  does not, and has to be turned on in Settings → AI — except that Explain /
  Fix it, which you ask for each time, ask first when it is off. Terminal text
  is sent with control sequences stripped and values that look like API keys,
  tokens, passwords, private keys and URL credentials masked. That is best
  effort, not a promise: a secret in a form it does not recognise still goes,
  which is why sending the screen stays off until you say otherwise.
- **App Transport Security stays on**, with two narrow exemptions: web-view
  content, so the browser pane can preview a plain-http dev server, and local
  networking, so the assistant and the HTTP client panel can reach a server on
  loopback. Anything routable still has to be HTTPS — the HTTP client refuses
  a plain `http://` request to any other host outright, rather than letting it
  fail as a confusing network error.
- **Downloads wait for a yes, and a page can't aim them at your network.**
  Extract fetches only the files you tick, after a sheet that shows the sites
  and the folder. A page from the internet can't make the app request this Mac
  or the network it is on — a redirect included — and requests carry no cookies
  or credentials. Files are never overwritten and are marked as downloaded from
  the web. See [Extract](#extract) for the rules and their one stated gap.
- **The rest of Extract asks first, too.** Image previews are off until you turn
  them on, and go by the same rules as downloads. A crawl stays on the one site,
  reads `robots.txt` before anything else and obeys it (a redirect into a page it
  rules out is not followed either), goes one page at a time, and starts only
  after a sheet that says so. **Ask…** sends a page's text to your assistant only
  after a sheet that names the destination and can show every character, with
  anything that looks like a key or a password masked first (best effort, not a
  promise); what comes back is shown as text and never run, opened or fetched.
- **What reaches a command line is checked first, and refused rather than
  repaired.** Jump hosts must be `[user@]host[:port]`, in the characters `ssh`
  accepts — no quotes, `%` tokens, whitespace or URLs — and a connection whose
  list fails does not connect at all, instead of connecting directly. The line
  *Edit in Terminal* types names the editor by an absolute path and quotes the
  file's, and a file name with a control character in it is refused (a newline
  would end the line early and run what follows). An imported font must have one
  of four extensions and be under 50 MB, is kept under a name that cannot leave
  the app's folder, and is read by macOS's own font parser — the one place an
  untrusted font could do harm — only because you chose it. A link in the
  right-click menu is shown as it will really be opened, with control and
  invisible characters replaced by a dot, and only `http` and `https` addresses
  can be opened from it.
- **The port scan and forwards never take a password and never leave the
  loopback.** They run `ssh` with `BatchMode=yes`, so a host that wants a
  password fails with advice to sign in in a terminal tab (whose connection they
  then share) instead of prompting. A forward listens on `127.0.0.1` on a port
  the system chose, its target is checked against a plain host-name alphabet
  before it reaches a command line, and the app adds no host-key option of its
  own, so a host `ssh` doesn't already trust fails rather than being trusted by
  a background call (unless your `~/.ssh/config` says otherwise). Imported Ghostty themes are read as colour numbers
  only, from a file capped at 64 KB.
- **This app never forwards the ssh-agent on its own.** The default adds
  nothing, leaving it to your `~/.ssh/config`; forwarding happens only where
  you chose *Always* or answered *Forward Agent*, and *Ask each time I connect*
  answers *no* to Return. See
  [Jump hosts and the SSH agent](#jump-hosts-and-the-ssh-agent).
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

**Help → Keyboard Shortcuts** (⌘/) lists every shortcut in a window you can
search, and the same list is under Settings → Shortcuts. The ones the menus
bind:

| Action | Keys |
| --- | --- |
| Command palette | ⌘K or ⌘P |
| Keyboard shortcuts | ⌘/ |
| New terminal tab | ⌘T |
| New workspace | ⇧⌘N |
| Split right / down | ⌘D / ⇧⌘D |
| Split with browser | ⇧⌘B |
| Close pane / tab | ⇧⌘W / ⌃⌘W |
| Terminal dock | ⌘J |
| Show / hide sidebar | ⌃⌘S |
| Browser / Files / Notes panel | ⌥⌘B / ⌥⌘F / ⌥⌘N |
| HTTP Client panel | ⌥⌘R |
| superfile / btop | ⌥⌘S / ⌥⌘P |
| Bigger / smaller text, actual size | ⌘+ / ⌘- / ⌘0 |
| Focus composer | ⇧⌘R |
| Minimise / expand composer | ⇧⌘M |
| Explain the last output / suggest a fix | ⌥⌘E / ⌥⌘X |
| Task manager | ⌥⌘T |
| Send the request (HTTP client) | ⌘↩ |
| Settings | ⌘, |

The composer and the site explorer's prompt have keys of their own — ↑ ↓ for
earlier commands, ⇥ to complete, ⌃R to search history — described under
Features and listed in the window above. Some actions (Split with Files, Split
with HTTP Client) have no shortcut; the command palette finds every action.

## Architecture

```
Sources/
├── iTERMiNAL/
│   ├── App/         entry point, window scene, menu commands; ScreenshotMode takes the
│   │                README pictures (compiled in only by the Screenshots workflow)
│   ├── Chrome/      window frame (top bar, icon rail), workspaces panel,
│   │                composer, command palette, themes
│   ├── Terminal/    TerminalEngine protocol + SwiftTerm implementation,
│   │                TerminalSession (PTY lifecycle, cwd/title/git metadata),
│   │                the right-click menu and the colored-output environment,
│   │                cursor animations, imported fonts, the bundled tools'
│   │                PATH and the editor command line — Foundation-only where
│   │                it can be
│   ├── Input/       the composer's input: shell tokenizer, completion, history
│   │                search, suggestions — Foundation-only where it can be
│   ├── Workspace/   Workspace → Tab → PaneNode split tree, persistence, the
│   │                order a dragged tab lands in
│   ├── Panels/      scriptable browser pane, file pane, notes, HTTP client pane
│   │                with the site explorer and the Extract tab (previews, crawler,
│   │                assistant)
│   ├── HTTP/        request/response types, formatting, the site-explorer and
│   │                Extract parsers (HTML, CSS, XPath, JSONPath, CSV, XML),
│   │                robots rules, crawl frontier — Foundation-only
│   ├── Files/       FileSystemProvider protocol, local + SFTP providers, the
│   │                shared-sign-in control socket, jump hosts and agent
│   │                forwarding (what a saved host adds to an ssh command line)
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

### Explain and Fix it

After a command you ran **from the composer** prints something that reads like
an error — "command not found", "permission denied", "no such file or
directory", a Python traceback, `fatal:`, `npm ERR!`, a failed `make` or build —
a slim row appears: **That looked like an error · Explain · Fix it**. It is a
guess from the words on screen, made on this Mac, and says only that it
*looked* like one: real exit codes would need the shell's help, and a command
that merely printed "permission denied" while searching has not failed.
Turn the offers off in Settings → AI.

The same two actions work any time, for any terminal, without any detection:
**Explain last output** (⌥⌘E) and **Suggest a fix** (⌥⌘X) in the Terminal menu
and the composer's **+** menu.

- **What is sent.** From the offer: the command and only the new text that
  appeared after it was sent. From the menu: what is on screen, and the command
  last sent to that terminal from the composer if it is still there. Either way, control sequences are stripped, values that look like
  secrets are masked, and it is cut to the last 6,000 characters starting on a
  whole line.
- **Asking first.** If "Include recent terminal output" is off, you are asked
  each time, told where it would go (the host's name, or "stays on this Mac"
  for a loopback model), and can read exactly what would be sent. Pressing
  Send does not turn the setting on.
- **Nothing runs.** A fenced command in a reply gets **Insert**, which puts it
  in the input to review — one undo step, nothing sent until you press Return —
  and **Copy**. Code in other languages gets Copy only. A command that deletes
  recursively, uses `sudo`, pipes a download into a shell, overwrites a file,
  force-pushes, or similar carries a short plain warning. No warning does not
  mean safe; it only reads for a few well-known dangers.

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

## Site explorer

Switch an HTTP pane from **Request** to **Explore** and it becomes a command
line over one website's published paths. Type an address (`example.com`, or
`http://localhost:3000` for a local server) and press Return — or, from
Request, press the list icon beside Send to map the address in the URL field.
An illustrative session:

```
$ example.com
mapping example.com — reading what the site publishes
robots.txt  200  14 paths, 1 sitemaps
sitemap  /sitemap.xml  1,204 paths
reading the page you entered for links
page  200  37 links added
mapped 1,251 paths — 1,204 from sitemaps, 14 from robots.txt, 37 from links
example.com:/ $ ls -l
--D-  admin/
S---  blog/      312 inside
---L  about
example.com:/ $ cd blog
example.com:/blog $ get 2024/post-1
```

| Command | Does |
|---|---|
| `ls [-l] [path]` | list a directory; `-l` shows where each entry came from — `S` sitemap, `A` robots Allow, `D` robots Disallow, `L` found as a link |
| `cd [path]`, `pwd` | move around (`..`, `/`, `~`, relative and absolute paths) |
| `tree [-L n] [path]`, `find <text>` | the map below a directory; known paths containing some text |
| `get [path]` (or `cat`) | fetch one address and print the response; links in it are added to the map |
| `req [path]` | load an address into the request builder, without sending |
| `open <address>`, `refresh`, `info`, `clear`, `help` | map another site; read the declarations again; what was read and from where |

Tab completes names from the map, ↑ ↓ recall earlier lines, Esc cancels.

**What it reads, and what it never does.** The map is made only of what the
site itself declares or you fetched: its `robots.txt` (every `Allow` and
`Disallow` path, as written), the sitemaps that file names (an index is
followed a few levels, a few at a time), and the page you entered. `ls`,
`cd`, `tree` and `find` read that map and send nothing.

- **No guessing.** It never probes for common directories, never tries a
  wordlist, and does not fall back to `/sitemap.xml` when `robots.txt`
  doesn't declare one. `get` fetches an address you typed, one at a time.
- **One site.** A sitemap or `Sitemap:` line that names another host (or
  another scheme) is reported and not requested, and a redirect off the site
  is shown, not followed — otherwise a site could aim this app at an address
  of its choosing. Different hosts are never merged: `www.example.com` is not
  `example.com`. The one exception is for the address you typed: when the
  site's own redirect says its front door is its `www.` twin (or the reverse),
  both over https on the same port, `open` maps that host and says so —
  `google.com` sends you to `www.google.com`, and that is where the map is.
- **Bounded.** Four sitemaps at a time, at most 40 files, three levels deep,
  25,000 paths per `open`; responses stop at the HTTP client's size limit.
  `.gz` sitemaps are not read.
- **Lossy where it says so.** Links come from `href`/`src` in HTML and from
  URL-shaped strings in JSON — not scripts, and `<base>` is ignored. A
  server with directory listings on shows up as ordinary links. Settings →
  HTTP Client can switch link-reading off, leaving only what is declared.
- **robots.txt rules are prefixes**, shown as the site wrote them;
  patterns containing `*` or `$` name nothing and are left out.

The map lives in memory for the pane and is not saved with a layout or in a
snapshot. A `get` is recorded in the pane's history and on the `http.sent`
event like any other request; the requests `open` makes on its own are listed
in the transcript instead.

## Extract

The HTTP pane's response area has two tabs: **Body**, the response as it came,
and **Extract**, which reads that one response into lists and tables. It works
on what is already in hand: opening the tab requests nothing, and nothing in it
follows a link by itself. What does reach out is something you ask for by name —
**Fetch** on a row, **Download**, **Previews**, **Crawl…**, **Ask…** — and each of
them says what it will ask of whom before it does, or, for a preview, is off
until you turn it on.

**For a web page**, a row of chips opens each list — only the ones with
something in them:

| List | Shows |
|---|---|
| Overview | Title, description, site, author, date, language, encoding, canonical address, preview image, the feeds the page declares, and a count of everything below |
| Text | The reading part of the page — `<article>`, else `<main>`, else the biggest block of text — as plain text or Markdown, with Copy and Save… |
| Links | Every link, with its text, whether it is the same site, its `rel`, and how often it appears. Links to a place further down the same page are counted, not listed; so are images written into the markup as `data:` addresses |
| Images | `<img>` (including `srcset` and the lazy-load attributes sites use), `<picture>`, video posters, icons, `og:image` and `twitter:image`, with size and where each came from |
| Video & audio | `<video>`, `<audio>`, `<source>`, caption tracks, `og:video` and `og:audio`, and embedded players. YouTube, Vimeo, Dailymotion, Spotify, SoundCloud and Twitch are named, with their watch page; a player is a page, not a file, so it is listed and not downloadable. A streaming playlist (`.m3u8`) is saved as the playlist, not stitched into a video |
| Files | Links to documents, archives, spreadsheets and the like, by their ending |
| Headings, Tables, Meta, Structured data, Scripts & styles, Forms | The outline; each `<table>` as a table; the `<meta>` and `<link>` tags; JSON-LD and microdata; the scripts and stylesheets the page loads; each form's method, action and fields |

**For data**, a JSON array of objects, a CSV or TSV file, an RSS or Atom feed
and a sitemap each become a table (**Records**), and any other response lists
the addresses found in it.

**Query** asks the response a question of your own, in the language a scraper
would use:

- **CSS** — type, `#id`, `.class`, attribute selectors (`[a^=v]`, `[a$=v]`,
  `[a*=v]` and the rest), the four combinators, `:first-child` and its family,
  `:nth-…(An+B)`, `:not()`, `:has()`, `:empty`, and `:contains("text")`; end
  with `::text`, `::html` or `::attr(name)` to say what to take, as in Scrapy.
- **XPath** — the part of XPath 1.0 that scraping uses: paths, `//`, `@attr`,
  `text()`, predicates with `contains`, `starts-with`, `not`, `position()` and
  `last()`. Other axes and unions are not supported.
- **JSONPath** — `$`, members, `[*]`, `..`, slices, several at once, and
  `[?(@.price < 10 && @.stock)]` filters.
- **Regex** — over the response as text; each capture group is a column, and a
  pattern that takes more than three seconds is stopped.

A query that can't be read says where it went wrong. Examples in the menu are
questions about the markup in front of you, not addresses.

**Taking things out.** Every list can be filtered; copied or saved as CSV, TSV,
JSON, a Markdown table or a plain list of addresses (a cell a spreadsheet would
run as a formula — one that starts with `=`, `@`, or a `+`/`-` that isn't a
number — gets a leading apostrophe, since a page can put anything in a link's
text); and each row has a menu: **Copy Address**, **Open in Browser Panel**,
**Load as Request**, **Fetch (GET)**, **Download…**. Load and Fetch are how you
get from one page to the next, one click each. **Save…** beside the tabs saves
the response body itself.

**Downloading.** Tick the rows you want (or use *All*) and choose Download. A
sheet shows how many files, the sites they come from, the folder, the size
limit, each file's name and address, and — under *will not be fetched* — every
address the rules below left out and why. Nothing is requested until you press
Download.

- Files go in `~/Downloads/iTERMiNAL/<site>/` unless Settings → HTTP Client
  names another folder, each under the name its address gives it (a name with
  no ending gets one from the type the server declared), numbered if that name
  is taken — **nothing is ever overwritten** — and marked as downloaded from
  the web, so macOS asks before it opens anything that could run. The first
  download into Downloads makes macOS ask whether iTERMiNAL may use that
  folder (Desktop and Documents do the same); a folder anywhere else, chosen
  in Settings, never asks.
- Three at a time, up to 500 files per batch, and no file larger than the
  limit in Settings (25 MB, 100 MB, 250 MB or 1 GB; a file is stopped the
  moment it passes it, before the rest arrives). *Stop* ends the batch.
- Requests carry no cookies, no credentials and none of the headers the page
  was fetched with: a file on another site isn't owed the login to this one.
  The `Referer` is what a browser sends — the page's address to the same site,
  only the site's own address to another, nothing from a secure page to an
  insecure one.
- **A page can't aim this app at your network.** Addresses come from the page
  you fetched, so an address on this Mac or a network that isn't the internet —
  loopback, private and link-local ranges, `.local` and one-word names — is
  refused unless the page itself came from there, in whatever spelling:
  `localhost.`, `127.1`, `0x7f000001`, `[0::1]` and `[::ffff:7f00:1]` are all
  this Mac, and an IPv6 address is judged by the address it comes to (an IPv4
  address inside one by that), not by how it begins. Names are judged as
  written, not looked up, so a public name that someone has pointed at a
  private address is not caught. Plain `http://` is used only for this Mac
  itself, as everywhere in the HTTP client, and a redirect is judged by the
  same rules as the first address.

**Previews.** The Images list can show a small picture beside each address —
the **Previews** button beside the filter, or Settings → HTTP Client. They start
off: a picture is a request to the site that hosts it, which you didn't type,
and it is decoded by the system's image code, as Quick Look would. Turned on, a
picture is fetched as you scroll to its row, three at a time, for at most 60
pictures a page, none over 5 MB or 40 megapixels, and not SVG. The rules are
downloads' rules — no cookies or credentials, a `Referer` like a browser's,
nothing aimed at your network, a redirect judged again — and a row that isn't
fetched says why when you point at its frame.

**Crawling.** **Crawl…**, at the top right of the Extract tab for a web page,
follows the page's links to the other pages of the same site and gathers what
they hold into the lists above. A sheet comes first, and nothing is requested
until you press Start: the site; how many pages (10 to 200, the one in hand
counted); how deep (1 to 4 links from here); how long to wait between requests
(half a second to five); and, if you like, to stay under the page's own folder.

- **robots.txt comes first, and is obeyed.** It is read the way RFC 9309 says: the
  group that names iTERMiNAL, or failing that the one for everyone; the longest
  matching rule wins, and an allow beats a disallow of the same length; `*` and a
  closing `$` work in patterns, and a rule written in UTF-8 (`Disallow: /café/`)
  matches the address spelled with escapes (`/caf%C3%A9/`), as the RFC says. A page
  it asks crawlers to leave alone is listed,
  marked as left alone, and not fetched — and doesn't use up a place in the page
  limit. A `Crawl-delay` longer than your wait is waited out, up to 30 seconds. A
  robots.txt the server can't deliver (a 5xx, or a redirect off the site) stops the
  crawl before it begins; one that isn't there (any 4xx) asks nothing, as the RFC
  says.
- **Only what the pages declare, on one site.** A link is followed only if it is
  an address the page names, with the same scheme, host and port as the page the
  crawl began on — exactly, so `www.` is another site — and inside the folder if
  you chose that. A link to another site is listed and not followed. Nothing is
  guessed, and no common path is tried.
- **One page at a time**, with the wait between, so it never asks more of a site
  than a person clicking quickly would. Nothing in it goes past the ceilings: 200
  pages, 4 deep, half a second apart, and a queue of at most 5,000 addresses.
- **Web pages only.** An address that ends like a picture, an archive, a document
  or a script isn't requested, and any other whose response says it isn't a web
  page is stopped at the headers, before its body is taken. No page is read past
  2 MB. A redirect is followed only to a page the crawl could have asked for
  itself — on the site, inside the folder if you chose that, and not one
  `robots.txt` rules out — and is otherwise noted and not followed.
- **It says who is asking**: `User-Agent: iTERMiNAL/<version>
  (+https://github.com/JUPiTER-JVCK/iTERMiNAL)`. Each request stands alone — no
  cookies, no credentials, nothing carried from one to the next — and the
  headers the page was first fetched with are not sent.
- **What it found** is the crawl's own tab: the pages (address, status, title,
  depth, how many links and images, size, and the page that linked to it), and
  the links, images, video and audio, and files found on any of them, each once
  with the first page it was found on, in the same lists as above — so Filter,
  Export and Download work on them. **Stop** ends it after the request in flight,
  and what was found stays. A crawl is kept while you look at other pages of the
  same site and dropped when you fetch a page of another, and it is not saved
  with a layout or in a snapshot.

**Asking the assistant.** **Ask…**, beside Crawl…, has the AI assistant you set up
in Settings → AI read the page's text into rows. Say what you want — "every
product with its price" — and a sheet shows where it would go (the assistant on
this Mac, which stays there, or the named host) and, one click away, every
character of what would be sent. Nothing is sent until you press Ask.

- **What goes** is the page's reading as Markdown, its address and title, and your
  request, under a system prompt the sheet shows too. Anything that looks like a
  key or a password is masked first — best effort, and nothing else is, so don't
  ask about a private page — the text is cut at 12,000 characters at the end of a
  whole line, and the sheet says how much of the page that is.
- **The model is told the page is data**, not instructions (a page can try to be
  the second), to answer only from the text, not to invent values or addresses,
  and to reply with a JSON array of objects. The request goes with temperature 0.
- **What comes back is only ever shown.** A JSON array of objects — also inside a
  code fence, with words around it, or as an object holding the list — becomes a
  table, its keys in order as columns, at most 500 rows, 20 columns and 300
  characters a cell; anything else is shown as the text it is. Nothing in an
  answer is run, opened or fetched. A cell is an address you can open or fetch
  only if the page itself named that address, so one the model made up is just
  text; nothing in an answer can be downloaded; and an export puts an apostrophe
  before a cell a spreadsheet would run.
- It uses the endpoint, key and context settings of Settings → AI, and an answer
  is of the page it was asked of: fetching another page clears it. It was written
  by a model, so it can be wrong — the list says so above the rows.

**What it never does.** Nothing is fetched except a row you chose to fetch or
download, a preview you turned on, or a crawl you started from its sheet; the
one thing that is sent anywhere else is the page's text to your assistant, after
its own sheet. It doesn't guess at addresses, run a page's scripts (so what
scripts draw isn't there — the Overview says so), or log in. The reading is lossy
where HTML is: a page that puts its content in scripts has little in the
response to read.

Nothing here is saved with a layout or in a snapshot, and the download folder
is a path on this Mac, so it isn't in exported settings either.

## Backup and restore

Workspaces and preferences live on this Mac, under Application Support.
Settings → Backup shows where, and moves them: **Export Workspaces…** writes a
single `.iterminal` JSON snapshot, **Import Workspaces…** reads one back and
replaces the current layout.

A snapshot carries workspaces, tabs, the split layout, saved connections (jump
hosts and the agent-forwarding choice included — read an imported snapshot's
hosts the way you would read an `ssh_config` someone sent you) and non-secret
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
`Contents/Resources/Tools`, and open from the icons at the top right (three more
tools, for typing rather than opening, are [further down](#command-line-tools)):

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
checks, on a real Mac, that the icons resolve to it, bold included.

The default font needed one more step. macOS hands the system SF Mono out as a
UI font, and a UI font's fallback always ends in a box-drawing font before any
fallback the app adds. So by default the terminal draws with SF Mono from the
complete family macOS ships inside Terminal.app, read in place — the same
typeface, as Terminal.app draws it. Measured in CI at 13 pt: identical width,
lines 0.2 pt taller (both round to the same row), and bold is SF Mono Bold
rather than Semibold. If that family is ever missing, or would not keep a real
bold and italic, the system font is used as before. Any other font you pick is
used as is.

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
rest. The symbols font adds about 1.7 MB more.

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
scripts/fetch-cli-tools.sh                 # rg, bat, imgcat; needs curl, lipo, codesign
```

### Command-line tools

Three more programs ship in the app, for typing rather than for opening from an
icon. They are in `Contents/Resources/Tools/bin`, and that folder is added to the
**end** of the `PATH` of every local terminal — tabs, the dock and the composer's
shell; a remote session has its own machine — so a `rg` or a `bat` you installed
yourself, Homebrew's say, is found first, and the bundled one is what you have
when there is nothing else.

| Command | What it is | Licence | Version | How it gets into the app |
| --- | --- | --- | --- | --- |
| `rg` | [ripgrep](https://github.com/BurntSushi/ripgrep): recursive regular-expression search | MIT or Unlicense | 15.2.0 | Upstream's macOS release binaries for both chips, checked against pinned SHA-256 hashes that were matched to upstream's own `.sha256` files, merged into one universal binary and ad-hoc signed |
| `bat` | [bat](https://github.com/sharkdp/bat): `cat` with syntax highlighting; output longer than the screen is paged through `less` | MIT or Apache-2.0 | 0.26.1 | The same, except that upstream publishes no checksums for it: its hashes are those of the files when the pin was made, so they say a file has not changed since, not that upstream vouched for it |
| `imgcat` | Shows an image in the terminal: `imgcat photo.png`, `imgcat -W 40 photo.heic`, or one piped in; sizes are cells, a percentage or pixels | MIT | this repository's own [script](scripts/imgcat) | Copied as it is |

`imgcat` writes the inline-image escape sequence that iTerm2 introduced, and the
terminal draws it, decoding the file with macOS's own image reader — PNG, JPEG,
GIF, HEIC, TIFF — so it works in any terminal that draws those, and it prints
nothing else. The terminal engine also reads the Kitty graphics protocol: a picture
sent by hand the way a program that speaks it would send one is drawn too. It refuses
a missing file, a size that is not a size, and anything
over 25 MB, with exit codes a script can read.

**Versions** are pinned in `scripts/tools.env` and move only by a pull request
that edits it; nothing is downloaded at runtime. Settings → Advanced lists them
with their licences. In the bundle ripgrep is 8.4 MB and bat 12.0 MB (each is both
chips' binaries in one file); the upstream archives they come from add up to
10.2 MB, which is about what they add to the download.

**What is checked.** CI refuses a finished app in which any of the three is
missing, is not universal, links a library outside `/usr/lib` and
`/System/Library`, or does not run (`--version`). `scripts/imgcat-check.py` — 34
checks, run in CI on a Mac — reads what `imgcat` prints the way the terminal
engine reads an inline image, and holds its refusals to their exit codes. The
rule that puts the folder on the `PATH` is plain Foundation code with its own
checks (it adds nothing that is not an absolute folder, nothing with a colon or a
newline in it, nothing twice, and nothing to an environment with no `PATH`). And
the [Screenshots workflow](.github/workflows/screenshots.yml) runs the real thing
on a Mac: it types `command -v rg bat imgcat` into a login shell in a tab of the
built app, which finds all three inside the app bundle, and then runs them there —
the *Command-line tools* picture at the top of this page is that run.

**What it cannot do.** A shell whose startup files set `PATH` outright, rather
than adding to it, takes the folder off again; `command -v rg` says which `rg` a
tab will run.

## Roadmap

- [x] AI assistant behind the `@ai` composer prefix (OpenAI-compatible; no tool calling)
- [x] Pane attention notifications (OSC 9/777) via the event bus
- [ ] Editable key bindings
- [x] Workspace snapshots: export/import with no account required
- [x] HTTP client pane: request builder, response viewer, history
- [x] HTTP client: declared-site explorer (`robots.txt` / `sitemap.xml` / links in fetched pages), command-line navigation
- [x] HTTP client: Extract tab — parsers, queries, downloads, image previews, a bounded same-site crawl, assistant-read rows
- [ ] HTTP client: saved `.http` collections
- [ ] Optional libghostty engine
- [ ] Signed/notarized releases

### Considered and left out

Things looked at and not built, with the reason, so that a gap reads as a
decision and not as an oversight.

- **A native SSH client written in Swift.** Terminal tabs and the file browser run
  the system's `ssh` and `sftp`, which is how they get your `~/.ssh/config`,
  `known_hosts`, agent, jump hosts and keys without this app ever holding a
  password. An SSH stack of its own would be a large, security-sensitive piece of
  code to write and keep current; `TerminalEngine` and `FileSystemProvider` are
  where one would plug in.
- **Keys in the Secure Enclave, and approval for each use of a key.** Both need an
  ssh-agent of this app's own: the Mac's agent holds the keys and signs without
  asking the app, and keys in the Secure Enclave also need a signed build, which
  is on the list above. Until then `ssh` uses whichever agent your
  `~/.ssh/config` points at, here as anywhere. What is built is the choice of
  *when* to forward the agent
  ([above](#jump-hosts-and-the-ssh-agent)).
- **mtr.** It sends ICMP probes, which on macOS takes root, and a setuid-root
  binary inside an app bundle is the risk the btop note above refuses to take.
  `traceroute` and `ping` ship with macOS and run in any tab.
- **croc, Helix, Vim and curl are not bundled.** The macOS archives of croc are
  8.5 MB and 9.2 MB, one per chip, and Helix's 16.7 MB and 16.1 MB (the versions
  current when this was written: croc 11.5.5, Helix 25.07.1): together about
  50 MB on top of the download, for programs `brew install` puts on the `PATH`
  in a minute. Helix and Neovim are what *Edit in Terminal* opens when they are
  installed; macOS ships Vim, Nano and a curl, upstream Vim publishes no macOS
  binary, and the HTTP client panel is its own client, built on the system's URL
  loading — which uses HTTP/2 wherever a server offers it — with *Copy as cURL*.
- **bsdtar and unzip.** Both ship with macOS (`tar` is libarchive's `bsdtar`).
  Which archive formats they open depends on the macOS release, and this has not
  been checked here, so nothing in this app claims more than that.
- **More Nerd Fonts.** *Symbols Nerd Font Mono* is bundled so Nerd Font icons draw
  with any terminal font ([above](#bundled-tools)), and any Nerd Font family you
  download can be imported (Settings → Terminal → Font). No patched families are
  bundled.
- **A shell of its own.** This is a terminal for the shell you already use; shell
  scripts run in `sh`, `bash` or `zsh` on this Mac.

## License

MIT — see [LICENSE](LICENSE).
