# Design: the Cheatsheet page

Status: **implemented**. This is the design record, and the record of how the search
was measured, including what did not work, so a later change to the ranking starts
from what was learned and not from the same mistake.

## Goal

An interactive command reference under the rail's `···` menu, in the spirit of navi
and Dash: pick a program, see its flags and the commands people reach for; type, and
the list narrows the way fzf's does; ask in words — "undo my last commit" — and find
the command whose text shares none of them.

## Content: three layers, one page per program

1. **Flags** are not written here. The composer already keeps flags and subcommands for
   33 tools in `CommandSpecs` for Tab completion; the page reads that table, so a flag is
   written down once. A test requires every tool in it to have a page.
2. **Recipes written for the app** (`CheatsheetCuratedData.swift`): 48 programs and 467
   recipes, for the BSD versions of the tools macOS ships (`sed -i ''`, `du -d 1`,
   `tail -r`). One line per field — `?` what it does, `$` the command, `~` other words to
   find it by — because a command can contain ` | ` and so cannot sit in a pipe-separated
   line as `CommandSpecs`' do. Parsed at first use and checked in CI like `CommandSpecs`:
   no program or command twice, no description over 90 characters or ending in a full
   stop, no `{{` without its `}}`.
3. **tldr-pages** (CC BY 4.0), English `common` and `osx`: 3,556 programs and 22,567
   examples after the conversion in `scripts/tldr-convert.py`. Pinned by SHA-256 in
   `scripts/tools.env`, fetched by `scripts/fetch-tldr.sh`, never in git. The licence
   asks for credit and for changes to be marked, so the notice is bundled, each page
   names the source, each example carries a badge, and the changes are listed at the top
   of the converter. Where both sources have a program, the page written for the app
   wins and tldr's examples follow it, under a heading, without any command already
   there.

A subcommand's own page (`git-reset`) is filed under its program as a section. The
page's *title* decides, not its file name: `git-reset` is titled "git reset", while
`ssh-keygen` is titled `ssh-keygen` and stays a program of its own.

## Search

One field, two ways of reading it. **Auto** chooses (`CheatQuery.looksLikeSentence`):
one word, or anything with a flag, path or variable in it, is letters; three words or
more is a sentence; two words are a sentence when one of them is a word sentences are
made of ("kill port") and letters when neither is ("docker ps"). A command's own name
does not count towards that — `ps`, `rm`, `du` and `ls` are in the families of words for
what they do, and "docker ps" was being read as a sentence until a check caught it.

### Letters

`FuzzyMatcher`, the command palette's, over "name description command" read as one line,
so "git undo" finds `git reset` under "Undo". It does not copy `CommandHistoryIndex`'s
`[Character]` per entry: 22,951 examples at about 115 characters, twice over, at 16
bytes a character, is about 80 MB. Each example is instead kept as lower-case UTF-8 in
one shared buffer, a plain scan rules most out, and only the survivors are matched
properly. One letter narrows programs by name and no more (it is in most examples, which
says nothing). A newer search cancels an older one through a token checked every 256
examples, so a run of keystrokes costs one search.

### Words

`CheatNaturalIndex`: every example is a small document — the program's name (weight 3),
tags (2) and summary (1); the description (2); the words written to find it by (2); and
the command (1) — scored by BM25. On top of that:

- a word's family counts as the word at half weight (`CheatSynonyms`: delete ~ remove,
  undo ~ reset, big ~ large);
- a word nothing contains is looked for one letter away;
- a document with more of the question's words is worth more than one with a single
  word very well (the share, to the power 1.5);
- **a page written for the app counts 1.6 times**. This is the one that matters. At
  1.0 the first answer to "delete a directory" was a cloud-storage tool's command,
  and hit@1 on the 40 questions below fell from 38 to 26;
- what is true of the *program* — its name, tags, summary — counts towards a match but
  not towards a document's length. Otherwise a well-tagged page has every one of its
  examples held against it for being long. Fixing that, and indexing the summary
  (`mkdir` is "Make folders"), took hit@1 from 36 to 38 of 40.

Stems are consistent on both sides of a match and need not be words: `file` and `files`
reach the same stem, as do `delete`, `deleting` and `deleted`. The first version mapped
`files` to `fil` and `file` to `file`, so a question with one never found a recipe with
the other; a check that family by family is one word now fails if that comes back.

## Asking the assistant

Optional, explicit, never on a keystroke, and shaped like the app's other ways of
sending anything (`AIExtractionRequest`): a Foundation-only request object whose
`preview` *is* the payload, shown on a sheet that names the host. It sends the typed
question (masked with `SecretRedactor`, cut at 300 characters) and the 40 commands the
offline search found closest, one line each. Nothing from the terminal. The model is
asked to choose among them, not to write one; the reply is read as a JSON array of
numbers, a number not on the list is dropped, numbers are never scraped out of prose, and
the picks shown are the lines that were on the list, not text the model wrote. Whether an
assistant is configured is looked up when the button is pressed, because
`isConfigured` reads the Keychain.

## How the search was measured

The first prototype, a few queries by eye, was encouraging and misleading: it got the
canonical answer for "undo last commit" and ranked obscure tools first for "delete a
directory". So the search was measured, on the real merged library.

Three sets of questions, each with the programs that would be a right answer, written
before looking at the results of the next:

| Set | Questions | What it is for |
|---|---|---|
| tuning | 40 | what the weights were swept against |
| held-out | 25 | written after, to see whether a change generalised |
| fresh | 20 | written before the held-out set's misses were fixed |

Results, as "right program first / in the top three":

| | tuning | held-out | fresh |
|---|---|---|---|
| first measurement | 36/40, 37/40 | 20/25, 23/25 | 15/20, 16/20 |
| after the structural fixes above | 38/40, 38/40 | | |
| after synonym families and two recipes the misses showed, and the stemmer fix | 39/40, 40/40 | 21/25, 25/25 | 17/20, 17/20 |

The honest figure is the first measurement on the two sets that were not tuned on:
35 of 45 first (78%) and 39 of 45 in the top three (87%). After the fixes the sets are
no longer unseen, so the later columns say what the fixes did, not how it will do.

**What did not work, and was not adopted.** Raising the synonym weight from 0.5 to 0.7,
and the summary weight from 1 to 2, each lifted the tuning set's top-three from 38 to
40. Both made the held-out set *worse* (first-place 20 to 18). They fitted the 40
questions. They were left out. Every other parameter — field weights, BM25's `k1` and
`b`, the coverage exponent — was flat across its range, which is a robust place to be.
A synonym for "backup" aimed at one question made it worse and was reverted.

**The misses that remain** are mostly defensible: `csvtool` for "extract a column from a
csv", `gtop` and `bpytop` for "monitor cpu usage", and `rsync` for "make a backup copy of
a file". The ones that were wrong were data and vocabulary — no family tying "see" to
"show", no generic `chmod` recipe — and were fixed there.

CI keeps a floor under this: 20 questions against the pages written for the app, and 16
plain ones against the real tldr-pages data (`--check-cheatsheets`), each requiring the
right program *first*. Those 16 were chosen from questions that already ranked right;
they stop a regression, they do not prove quality.

## Cost

Release build, Linux x86_64, Swift 6.0.3, the full 22,951-example library — not measured
on a Mac. Reading and decoding `tldr.json` takes about 70 ms, merging 30–50 ms, and
building both indices about 450 ms; all of it runs off the main thread on first use, and
the page works with the 48 programs written for the app until it is done. A search by
meaning takes 0–3 ms. A search by letters takes about 4 ms for one letter (names only),
25–90 ms for longer queries and 180–220 ms for two to four letters, which most examples
pass the plain scan for; a newer keystroke cancels it.

## Known limits, and the Manual section

The examples are a set of *common* ones, not a reference. 2,242 of tldr-pages' 3,556
programs have five or fewer, so a tool with many subcommands can look nearly empty:
`ipconfig` showed two results (`getiflist` and `getifaddr`) while its own usage text lists
thirteen subcommands. The list of flags and subcommands on a page comes from
`CommandSpecs`, the table the composer completes from, and it had 33 tools.

Two things were done about it, because the Cheatsheet is for macOS and may draw on the
original documentation as well as tldr-pages:

- **More tables.** 21 tools were added to `CommandSpecs` (54 in all): `ipconfig`, `ifconfig`,
  `networksetup`, `scutil`, `route`, `arp`, `netstat`, `traceroute`, `pmset`, `launchctl`,
  `mdutil`, `softwareupdate`, `tmutil`, `hdiutil`, `plutil`, `xattr`, `say`, `screencapture`,
  `sips`, `diskutil` and `caffeinate`. Each was written from Apple's published manual page
  and then checked mechanically: a throwaway script fetched every page and required each
  flag and subcommand to appear in it, strictly (a single-letter flag has to be a real
  option term, a subcommand a term of the page). It rejected six on its first run; three
  were false alarms from its own matching (`pmset -b`, `launchctl unload` and `hdiutil
  -noverify` are documented in forms like `[ -a | -b | -c | -u ]`, `load | unload` and
  `-[no]verify`), and three were real and were removed because Apple's page does not
  document them (`scutil --nwi`, `softwareupdate --history`, `tmutil status`). The one
  name kept that the page lacks is `ipconfig getiflist`, which the tool prints in its own
  usage and tldr-pages uses. These tools also gained flag and subcommand completion in the
  composer, since it reads the same table.
- **The Manual section.** For every other program, the page can show the original manual
  page installed on the Mac itself: the SYNOPSIS (for a tool with subcommands, that lists
  them all) and its COMMANDS and OPTIONS, or its DESCRIPTION when the page keeps its flags
  there. It is read when the section is opened, not when a program is chosen, so moving
  down the list starts nothing. `ManPage` cleans and cuts the text (`man` writes bold and
  underline as a letter, a backspace and the letter again, which mandoc was run here to
  confirm); `ManPageReader` takes the way of running `man` as a function, so the failure
  cases are tried without a Mac.

Why `man`, and not the program's own `--help`: asking a program for its usage runs the
program, and some tools do things when run with no arguments. `man` reads a file. The name
passed to it is checked first (letters, digits and `. _ + -`, not starting with a dash or a
dot, so it can be taken for neither a flag nor a path), and the process is given four seconds
and `ProcessRunner`'s cap on how much it may say.

A real `man` taught one thing the fixtures could not. This container's, with no pages
installed, prints a notice about a "minimized" system **and exits zero**, which the first
version showed as the program's manual. A page is now told by its headings (every one has a
NAME, a SYNOPSIS or a DESCRIPTION), not by what `man` says about its absence, and that exact
output is a regression test.

Not known without a Mac: how the text looks on a real macOS (width, how bold comes out), and
whether Homebrew's manual pages are found from an app's `PATH`. `PATH` is extended with
`/opt/homebrew/bin` and `/usr/local/bin` for `man`, which finds a command's pages from the
folders on the path. If they are not found, the section says there is no page and **Open in
terminal** still works with the terminal's own environment.

## Not done

navi's fill-in prompts for `{{placeholders}}`; cheats of your own; Linux, Windows and
non-English tldr pages; a menu command or a keyboard shortcut (the page is on the rail
and in the command palette); on-device embeddings; a bump for programs that are
installed on this Mac. The last is the likeliest next step — the page-written-for-the-app
prior is a blunt stand-in for "the tools this person has" — and `CommandResolver` already
knows which names resolve.

## Re-tuning

The harness is nothing more than the Foundation-only files in `Sources/iTERMiNAL/Cheatsheet`
compiled with a `main.swift` that loads `tldr.json` (from `scripts/fetch-tldr.sh`), builds
`CheatIndex` over `CheatLibrary.merging`, and runs a list of questions through
`searchNatural`. Keep three sets. Never adopt a change that lifts the set it was tuned
on without lifting one it was not.
