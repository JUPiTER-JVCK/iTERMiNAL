# Ghostty configuration

A terminal design for [Ghostty](https://ghostty.org): iTERMiNAL's twenty colour
schemes exported as Ghostty themes, plus a config that sets up the rest of the
look — muted slate-green background, Nerd Font, generous padding, translucency,
tinted split dividers — and matching configs for the TUI tools that make a
terminal look like something other than white text on black.

Everything here is plain text you can read before running it. Nothing is
compiled, and nothing talks to the network.

## Install

```sh
cd contrib/ghostty
./install.sh              # Ghostty config + all twenty themes
./install.sh --extras     # also starship, btop and fastfetch
./install.sh --dry-run    # print what it would do, touch nothing
```

Existing files are moved aside with a timestamped `.bak` suffix, never
overwritten in place. By default everything lands in `~/.config/ghostty`, which
Ghostty reads on both macOS and Linux; pass `--config-dir` to put it somewhere
else.

Then restart Ghostty, or press <kbd>⌘⇧R</kbd> to reload.

### The one thing you have to install yourself

A **Nerd Font**. btop, starship, fastfetch, yazi and lualine all draw their
icons and powerline separators from the private-use range of a patched font;
without one you get empty boxes where every icon should be.

```sh
brew install --cask font-jetbrains-mono-nerd-font
```

The config asks for `JetBrainsMono Nerd Font`. If you install a different one,
change the `font-family` line to match — the name must be exactly what the font
calls itself, which `fc-list : family` (or Font Book) will tell you.

## What's in here

| File | What it is |
| --- | --- |
| `config` | The Ghostty config: theme, font, padding, transparency, splits, keybinds. Commented throughout. |
| `themes/` | All twenty iTERMiNAL schemes as Ghostty theme files, named `iterminal-*`. |
| `export-themes.py` | Regenerates `themes/` from the Swift source. |
| `extras/starship.toml` | Two-line powerline prompt on the Everforest palette. |
| `extras/btop.theme` | btop theme with a different accent per panel. |
| `extras/fastfetch.jsonc` | The system-info block for a new-terminal greeting. |
| `install.sh` | Copies it all into place, with backups. |

## Changing the theme

Edit the `theme =` line in the config. `ls ~/.config/ghostty/themes` lists what
is available:

```
iterminal-dark                iterminal-light
iterminal-everforest-dark     iterminal-gruvbox-dark      iterminal-gruvbox-light
iterminal-tokyo-night         iterminal-tokyo-night-storm iterminal-kanagawa
iterminal-catppuccin-mocha    iterminal-catppuccin-macchiato
iterminal-catppuccin-frappe   iterminal-catppuccin-latte
iterminal-nord                iterminal-dracula           iterminal-monokai
iterminal-one-dark            iterminal-one-light         iterminal-rose-pine
iterminal-solarized-dark      iterminal-solarized-light
```

The default is `iterminal-everforest-dark` — the muted green-grey that Omarchy
made popular, and the reason the screenshots of these setups don't read as
"black terminal with coloured text".

The `iterminal-` prefix is deliberate: Ghostty ships built-in themes called
`Everforest Dark`, `Nord`, `Dracula` and so on, and files in your own themes
directory shadow the built-ins of the same name. Prefixing keeps both sets
available, so you can compare.

To follow the system appearance, name a theme for each side:

```
theme = light:iterminal-catppuccin-latte,dark:iterminal-everforest-dark
```

## Machine-local tweaks

The config ends with:

```
config-file = ?config.local
```

Anything you put in `~/.config/ghostty/config.local` is loaded afterwards and
wins. The `?` means "ignore this if it doesn't exist". Keep your font size or
opacity there and `install.sh` can replace the main config without eating your
changes.

## Keeping the themes in sync

`themes/` is generated from `Sources/iTERMiNAL/Chrome/TerminalTheme.swift`,
which is the single source of truth for the app's palettes. After changing a
colour there:

```sh
./export-themes.py            # regenerate
./export-themes.py --check    # exit 1 and name the stale files if it drifted
```

## Verifying the config

Ghostty reports config errors on startup rather than refusing to launch, so a
typo is easy to miss. Ask it directly:

```sh
ghostty +validate-config      # parses your live config, names bad lines
ghostty +list-themes          # confirms it can see the iterminal-* themes
```

On macOS the CLI lives inside the app bundle, so unless you have it on `PATH`:

```sh
/Applications/Ghostty.app/Contents/MacOS/ghostty +validate-config
```

## Notes on a few settings

- **`background-opacity = 0.94` with `background-blur = 20`** is the glass
  effect. Set opacity to `1.0` if text legibility over a busy wallpaper matters
  more than the effect.
- **`window-theme = ghostty`** paints the titlebar with the terminal's own
  colours instead of the system grey. This is a big part of why a riced
  terminal looks like one window rather than a theme inside a frame.
- **`macos-option-as-alt`** is commented out. Turn it on for `alt+f`/`alt+b`
  word motions at the prompt; leave it off if you type accented characters
  with <kbd>⌥</kbd>.
- **`global:super+grave_accent`** opens Ghostty's quick terminal from anywhere.
  macOS only, and it needs Accessibility permission before the hotkey fires
  (System Settings → Privacy & Security → Accessibility).
- **`scrollback-limit`** is in bytes, not lines. 10000000 is about 10 MB.

## Companion tools

None of these are required, and the Ghostty config works without them — but
they are what fills the screen in the setups this is modelled on.

```sh
brew install starship fastfetch btop
brew install --cask font-jetbrains-mono-nerd-font
```

Then, in `~/.zshrc`:

```sh
eval "$(starship init zsh)"
fastfetch
```

`install.sh --extras` writes the configs for all three. btop additionally needs
to be told which theme to use — set `color_theme = "iterminal-everforest"` in
`~/.config/btop/btop.conf`, or pick it from <kbd>Esc</kbd> → Options → Color
theme.

## Why this lives in the iTERMiNAL repo

Same palettes, different terminal. The themes are generated from the app's own
`TerminalTheme.swift`, so a scheme picked in iTERMiNAL's Appearance settings and
the same scheme in Ghostty are the same colours to the byte — useful if you use
both, and a reason to keep the palettes in one place.
