# Design: the quick reference strip

Status: **implemented**. Kept as the design record.

## Goal

Show the keys for whatever has the focused terminal — `:w` and `:q` in Vim,
⌃O and ⌃X in nano, `q`, `/` and the sections in `man` — on the same screen,
in a way that looks like part of the window rather than a panel laid over it.

## Where it sits

A single line directly above the status bar, the status bar's height, across
the detail column. It follows focus, as the status bar does, so in split panes
it describes the pane you are typing into.

- **It never comes and goes with the program.** A full-screen program redraws
  when its terminal changes size, so a row that appeared when Vim started would
  shrink the terminal just after Vim drew, and make every editor jump. At a
  prompt the line shows the shell's own keys instead; it is only absent with no
  terminal at all, or when it is switched off.
- **The seam under it is the status bar's own**, which runs on across the
  sidebar's footer as one line. When the status bar is switched off the strip
  is the last row, and because it is the same height its seam lines up instead.
- Hints are in the order they matter, and a narrow window drops them from the
  end: nothing wraps or scrolls. `ViewThatFits` picks the longest run of them
  that fits, so the ones left out are not on the screen at all — moved off it,
  as an earlier layout did, VoiceOver still read them. A key cap never gives
  way — cut down it reads as "…" — so only the words beside it are shortened.
- The first key lines up with the status bar's first icon below it: the line
  starts 4pt further left than the status bar, by the hint's own hover padding.
- A key a click types warms under the pointer and flashes in the accent when
  clicked. A key shown but never typed — man's sections, ssh's escapes — has
  no fill and a dashed edge, so which is which is plain before hovering.
- The program's name sits at the end of the line, as plain text with a small
  chevron, at the status bar's size, and is the button that opens the rest in a
  popover; ⌥⌘/ (Help → Keys for the Program in Front) does the same. At the
  start, in a capsule, it took room the hints needed and stood out more than a
  label should. For a program with no keys listed that the Cheatsheet has a
  page for, it opens that page instead.
- The popover is as tall as its list, up to 400pt, opens with its search
  field focused, and Return there types the first key found. Its legend shows
  only the modifiers the list uses — never ⌘, which no program here is sent.
- At a prompt the shell's keys can be switched off (Settings → Appearance →
  Status → Shell keys at a prompt). The line stays, empty, so the terminal
  keeps its size.
- ⌃, ⌥, ⇧ and ⌘ are each drawn in a shade of their own: the text's colour at
  full strength for Control, then a step dimmer for Option, Shift and Command
  (white to a darker grey on a dark theme, black to grey on a light one), so
  which modifier a key needs reads at a glance without colour standing out.
  The popover opens with a legend. Colours were tried first and stood out too
  much against the rest of the window.

Considered and not chosen: inside the status bar (too little room beside the
system figures, and it would hide the directory while a program runs), inside
the composer (it floats over the bottom lines of the terminal, where nano and
Vim draw their own status, and it is often folded away), and a hold-⌘ overlay
(no footprint, but hard to discover).

## Knowing what is in front (`ActiveProgram`)

Worked out from what the session already has, with no timer:

1. **On this Mac, the kernel.** A terminal has one foreground process group; the
   kernel keeps its id in every process on the terminal (`e_tpgid`, what
   `ps -o tpgid` prints), so asking about the shell is enough.
   `ForegroundProcess` reads it with `sysctl`, lists the group's members
   (`KERN_PROC_PGRP`) and names them with `proc_name`. The shell's own group is
   a prompt. A member counts as well as the leader, so `git log` (git, with less
   in its group) is the pager and `git commit` the editor it opens. This is how
   Terminal.app names its tabs, and it needs nothing from the shell.
   - **A shell leading the group** is read two ways. Alone, it is a shell typed
     at the prompt, at a prompt of its own: an interactive shell gives each
     command a group of its own. With others beside it, it is running a
     script, whose commands share its group — and macOS's `man` is a shell
     script, so a manual page is a group of sh, mandoc and less. For that case
     the leader's arguments are read (`KERN_PROCARGS2`): `/bin/sh /usr/bin/man
     ls` names the script, man. Without them, a listed program in the group
     (less) is used. The arguments are read once per job.
   - **An interpreter's arguments** are read the same way: `python3` and
     `node` alone, or with `-i`, are their prompts; with a script, `-m` or
     `-e`, they run a program, which has no keys listed.
   - **tmux** runs each pane on a terminal of its own, so from outside the
     program in front is only ever tmux. Its server is asked (`TmuxQuery`,
     `tmux display-message -c <this terminal's tty>`, with the client's own
     binary and `-L`/`-S`) what its current pane runs and which prefix is set
     — at most once a second, off the main thread. The pane's program is shown
     with tmux's keys beside it, and the prefix replaces ⌃B throughout.
     screen's escape key comes from `~/.screenrc`; what runs inside screen
     cannot be asked for.
   - **A shell the kernel cannot see into** — `sudo -i` (sudo runs it on a
     terminal of its own), `docker exec -it`, `kubectl exec -it`, `vagrant
     ssh`, mosh — is decided once, by the line that started it, when its group
     comes to the front, and kept while it stays there: a line typed into that
     shell soon takes the starting line's place. A remote one is treated as ssh
     is; a root one as a shell on this Mac.
   - **`git add -p`** and the other patch modes are git reading the terminal
     itself, told apart by the line that started it.
   - **The leader's parent** is read too: a man built on mandoc puts its pager
     in a process group of its own and hands it the terminal, so the group in
     front is less alone, and only its parent says it is man.
2. **Past `sudo`**, whose child can run on a terminal of its own, the command
   line typed at the prompt names the program.
3. **Over ssh** the kernel only ever sees `ssh`. A full-screen program switches
   the terminal to its alternate screen, so while that is showing, the program
   is the one the last command line named, or failing that the one the title
   names at either end ("notes.txt (~) - VIM"). Otherwise it is the far end's
   prompt. A program that does not use the alternate screen is not found there.
4. **At a prompt**, once a command's name is typed and followed by a space, the
   strip shows its flags or subcommands from `CommandSpecs`. The composer's
   input counts too, while it has the keyboard and is a shell's — not while it
   is the assistant's. Not over ssh or in a container: `CommandSpecs` is
   macOS's tools, and GNU `sed -i` is not macOS's.
   The line comes from the keys while they spell it out. Once Tab or ↑ has
   changed it where the keys cannot follow, it is read off the screen, from
   where the line began (the cursor's place as its first key was pressed) to
   the cursor — and taken only if it still starts with what was typed before,
   so a screen scrolled by a list of completions is not read as the line.

It is asked again on the signals that mark a change: a repaint, and once more
half a second after the drawing settles; return, and 0.3 s after it, for a
program that prints nothing at first; the shell integration's marks; a title;
the shell exiting; and focus arriving. The look after the drawing settles is
not optional: the engine passes on at most one repaint in each quarter second
and drops the others rather than holding the last, so a page drawn whole just
after the echo of return — man, less — and then left still would otherwise
never be looked at again. Only the focused session is kept up to date, and nothing at all
while the strip is off. Each refresh is a few `sysctl` calls; a leader's arguments
are read once per job, tmux is asked at most once a second, and the answer is
published only when it changes.

### What a typed word may do

The line buffer behind this is what was typed, and some of what is typed is a
password. So a typed word is only ever used once it matches a program the
catalog lists or a command `CommandSpecs` knows; an unknown program is named by
the kernel, never by what was typed. Locally the line is kept only while a shell
was in front as return was pressed, so the password typed at sudo's prompt is
never kept. Nothing typed is written anywhere.

Inside a shell somewhere else — ssh typed here, a container's, sudo's root
shell — the kernel can only say ssh, docker or sudo is in front, so what this
Mac can still see decides whether a line is kept: not one read with echo off,
not one typed into a full-screen program. For a while after #137 such lines
were not kept at all, and a program started on the far end of a local `ssh`
was found only by its title.

## The keys (`ProgramKeyCatalog`)

`EditorKeyCatalog` already listed Vim, nano, Emacs and micro for the Keyboard
Shortcuts window. It is now `ProgramKeyCatalog`, with Helix, less, man, tmux,
screen, top, htop, the Python, Node and Ruby prompts, psql, mysql, sqlite3,
fzf, lazygit, `git add -p`, ssh's escapes and the shell's line editing added, each from that
program's own documentation for its default keys. Each entry gained a short
label for the strip (nano's own: Write Out, Where Is), its place in the strip,
and what a click types. btop's and superfile's keys are not written again: they
are `ShortcutCatalog`'s, checked against the versions the app bundles, and the
Keyboard Shortcuts window keeps showing them under Inside btop and Inside
superfile.

## A click types the keys (`ProgramKeySend`)

Control, Option as Meta (esc and the key), Shift and a letter, esc, space, tab,
and text as written. Not arrows, page or function keys, whose bytes depend on
modes the program sets, nor anything with ⌘.

- **A return at the end is left off**, so you see what was typed and press
  return to go ahead. A return anywhere else means nothing is typed: ssh's
  escapes start with one, and it would run whatever was half typed on the line.
- **Vim's keys start with esc**, so a click in insert mode does not type `:w`
  into the file.
- **A key that needs your own words** types only the part before them: `/` for
  a search, `:e ` for a file.
- **Before typing, what is in front is asked again**, and nothing is typed if it
  is no longer what the strip showed: keys meant for Vim must not land at the
  shell it has just quit to. The terminal then takes the keyboard back.

## Checked off a Mac

The catalog, the key sending and the resolver are Foundation only and run in
`scripts/input-logic-check`: what each kind of cap sends, that no key the strip
offers to click types nothing, that no click runs two words together, and how
each case above resolves. The kernel reading and the view are AppKit and
SwiftUI, checked by the app build.
