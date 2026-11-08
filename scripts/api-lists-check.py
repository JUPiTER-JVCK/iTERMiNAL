#!/usr/bin/env python3
"""Checks that the scripting API's own lists say what the code does:

- `EventBus.allEvents`, which `subscribe` replies with as `available`, holds
  every event name the app publishes with `APIEvent("…")`, and nothing it
  never publishes;
- `APIRouter.commands`, which `help` replies with, holds every command a
  `switch request.command` answers (the router's, and the server's own for
  `subscribe` and `unsubscribe`), and nothing none of them answers;
- the README's command table (under "## Scripting API") names every command
  in `commands` and nothing else. It may shorten a run in one namespace, as in
  `browser.open` / `newTab`: a name with no dot after " / " takes the
  namespace of the name before it;
- the README's event table (under "### Event stream") names every event in
  `allEvents`, each written out in full, and nothing else.

    python3 scripts/api-lists-check.py

Five events and `browser.newTab` were missing from those lists before this
check existed; both lists are written by hand, far from the code they describe.

The Swift is read with a small lexer rather than a pattern, so a name in a
comment or inside a string does not count, and neither does a `case` of a
switch nested inside one of the router's cases. What it cannot see, it refuses
rather than passes: an `APIEvent(` whose name is not a string literal, a
`case` in a command switch that is not one, or a list that is not an array of
literals. It does not understand Swift regex literals (`/…/`): a quote or a
brace inside one would throw it off.

Standard library only, so CI runs it on the macOS runner as it is.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources")
API = os.path.join(SOURCES, "iTERMiNAL", "API")

failures = 0
checks = 0


def check(condition, message):
    global failures, checks
    checks += 1
    if not condition:
        failures += 1
        print("FAIL  " + message)


class LexError(Exception):
    pass


def lex(source, i=0, line=1, nested=False):
    """Tokens of Swift source, as (kind, value, line): "id" for a word, "str" for
    a string literal (value None when it has escapes or interpolation, so it
    cannot be a name), "p" for any other single character. Comments are dropped.

    With nested, lexes the inside of a string interpolation and stops at its
    closing parenthesis; returns (tokens, index after it, line)."""
    tokens = []
    n = len(source)
    parens = 0
    while i < n:
        c = source[i]
        if c == "\n":
            line += 1
            i += 1
        elif c.isspace():
            i += 1
        elif source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
        elif source.startswith("/*", i):
            depth = 0
            while True:
                if i >= n:
                    raise LexError("line %d: a comment that does not end" % line)
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                    if depth == 0:
                        break
                else:
                    line += source[i] == "\n"
                    i += 1
        elif c == '"' or (c == "#" and re.match(r'#+"', source[i:i + 16])):
            opening = re.match(r'(#*)("""|")', source[i:])
            start = line
            value, i, line = read_string(source, i + len(opening.group(0)), opening.group(1), opening.group(2), line)
            tokens.append(("str", value, start))
        elif c.isalpha() or c == "_":
            word = re.match(r"\w+", source[i:]).group(0)
            tokens.append(("id", word, line))
            i += len(word)
        else:
            if nested:
                if c == "(":
                    parens += 1
                elif c == ")":
                    if parens == 0:
                        return tokens, i + 1, line
                    parens -= 1
            tokens.append(("p", c, line))
            i += 1
    if nested:
        raise LexError("line %d: a string interpolation that does not end" % line)
    return tokens


def read_string(source, i, hashes, quote, line):
    """Reads a string literal's body from just after its opening delimiter."""
    close = quote + hashes
    escape = "\\" + hashes
    plain = True
    body = []
    start = line
    while True:
        if i >= len(source):
            raise LexError("line %d: a string that does not end" % start)
        if source.startswith(close, i):
            return ("".join(body) if plain else None), i + len(close), line
        if source.startswith(escape, i):
            plain = False
            i += len(escape)
            if source.startswith("(", i):
                _, i, line = lex(source, i + 1, line, nested=True)
            else:
                line += source[i] == "\n"
                i += 1
            continue
        if source[i] == "\n":
            if quote == '"':
                raise LexError("line %d: a string that does not end" % start)
            line += 1
        body.append(source[i])
        i += 1


def is_p(token, char):
    return token[0] == "p" and token[1] == char


def published_events(tokens):
    """(name, line) for each `APIEvent("name"`, and the lines of any APIEvent( whose name is not a literal."""
    found, unreadable = [], []
    for k in range(len(tokens) - 2):
        if tokens[k][:2] == ("id", "APIEvent") and is_p(tokens[k + 1], "("):
            name = tokens[k + 2]
            if name[0] == "str" and name[1]:
                found.append((name[1], name[2]))
            else:
                unreadable.append(tokens[k][2])
    return found, unreadable


def string_array(tokens, name):
    """The literals of `let <name> … = [ "a", "b", … ]`, or None if that is not what it is."""
    for k in range(len(tokens) - 1):
        if tokens[k][:2] == ("id", "let") and tokens[k + 1][:2] == ("id", name):
            j = k + 2
            while j < len(tokens) and not is_p(tokens[j], "="):
                j += 1
            if j + 1 >= len(tokens) or not is_p(tokens[j + 1], "["):
                return None
            values = []
            for token in tokens[j + 2:]:
                if is_p(token, "]"):
                    return values
                if token[0] == "str" and token[1]:
                    values.append(token[1])
                elif not is_p(token, ","):
                    return None
            return None
    return None


# A `case` after these opens a pattern in a condition, not a label of the switch.
CONDITION = {("id", "if"), ("id", "guard"), ("id", "while"), ("id", "for"), ("p", ",")}


def command_switches(tokens):
    """For each `switch request.command { … }`: the names its own case labels match,
    and the lines of any of its labels that are not string literals."""
    switches = []
    for k in range(len(tokens) - 4):
        head = [t[:2] for t in tokens[k:k + 5]]
        if head != [("id", "switch"), ("id", "request"), ("p", "."), ("id", "command"), ("p", "{")]:
            continue
        names, unreadable = [], []
        depth = 1
        j = k + 5
        while j < len(tokens) and depth > 0:
            token = tokens[j]
            if is_p(token, "{"):
                depth += 1
            elif is_p(token, "}"):
                depth -= 1
            elif depth == 1 and token[:2] == ("id", "case") and tokens[j - 1][:2] not in CONDITION:
                j += 1
                while True:
                    item = tokens[j] if j < len(tokens) else ("p", "", token[2])
                    if item[0] == "str" and item[1]:
                        names.append(item[1])
                    else:
                        unreadable.append(token[2])
                        break
                    if j + 1 < len(tokens) and is_p(tokens[j + 1], ","):
                        j += 2
                    elif j + 1 < len(tokens) and is_p(tokens[j + 1], ":"):
                        j += 1
                        break
                    else:
                        unreadable.append(token[2])
                        break
            j += 1
        switches.append((names, unreadable))
    return switches


def first_cells(text, heading, header):
    """The first column of the first table under `heading` (before the next
    heading) whose header cell is `header`; None if there is no such table."""
    lines = text.split("\n")
    try:
        start = lines.index(heading)
    except ValueError:
        return None
    cells = None
    for row in lines[start + 1:]:
        if row.startswith("#"):
            break
        if not row.startswith("|"):
            if cells is not None:
                break
            continue
        cell = row.split("|")[1].strip()
        if cells is None:
            if cell != header:
                return None
            cells = []
        elif not set(cell) <= set("-: "):
            cells.append(cell)
    return cells


def readme_events(text):
    """The names in the first column of the table under "### Event stream"."""
    cells = first_cells(text, "### Event stream", "Event")
    if cells is None:
        return None
    return [name for cell in cells for name in re.findall(r"`([^`]+)`", cell)]


def readme_commands(text):
    """The commands in the first column of the table under "## Scripting API".

    That table shortens a run of commands in one namespace: in "`browser.open` /
    `newTab`", a name with no dot that follows " / " shares the namespace of the
    name before it. Names separated any other way are taken as written."""
    cells = first_cells(text, "## Scripting API", "Command")
    if cells is None:
        return None
    names = []
    for cell in cells:
        parts = re.split(r"`([^`]+)`", cell)
        previous = ""
        for index in range(1, len(parts), 2):
            name = parts[index]
            if "." not in name and parts[index - 1].strip() == "/" and "." in previous:
                name = previous.rsplit(".", 1)[0] + "." + name
            names.append(name)
            previous = name
    return names


def duplicates(values):
    return sorted({value for value in values if values.count(value) > 1})


# The lexer and the readers, on sources made up to catch what a pattern would get wrong.
sample = r'''
struct APIEvent { let name: String }
// APIEvent("in.a.comment")
/* nested /* APIEvent("in.a.nested.comment") */ still a comment */
let braces = #"{"ok":false}"# + "}" + """
  a "quoted" APIEvent("in.a.string") {
  """
let event = APIEvent("real.one", ["x": "\(f("}"))"])
publish(APIEvent("real.two"))
publish(APIEvent(name))
static let allEvents = ["real.one", "real.two",]
func handle() {
    switch request.command {
    case "a":
        if case .x = y { }
        switch request.string("kind") ?? "terminal" {
        case "nested": break
        default: break
        }
    case "b", "c":
        done { switch result { case .success: ok() } }
    case let other where other.hasPrefix("p."):
        break
    default:
        fail("Unknown \"\(request.command)\" {")
    }
}
'''
try:
    tokens = lex(sample)
    events, unreadable = published_events(tokens)
    check([name for name, _ in events] == ["real.one", "real.two"],
          "only APIEvent names in code count, not ones in comments or strings (%s)" % events)
    check(len(unreadable) == 1, "an APIEvent whose name is not a literal is reported, not skipped")
    check(string_array(tokens, "allEvents") == ["real.one", "real.two"], "an array of literals is read, a trailing comma and all")
    switches = command_switches(tokens)
    check(len(switches) == 1, "one command switch is found, and the nested one is not taken for another")
    names, unreadable = switches[0] if switches else ([], [])
    check(names == ["a", "b", "c"], "its own labels are read, a nested switch's and an `if case` are not (%s)" % names)
    check(len(unreadable) == 1, "a label that is not a string literal is reported, not skipped")
except LexError as error:
    check(False, "the made-up source lexes: %s" % error)
for broken in ['let s = "never ends', "/* never ends", 'let s = "\\(f(x"', 'let s = #"ends with a plain quote"']:
    try:
        lex(broken)
        check(False, "a source that does not end is refused: %r" % broken)
    except LexError:
        check(True, "")
check(readme_events("### Event stream\n\n| Event | Fires when |\n| --- | --- |\n| `a.b` / `a.c` | x `not.this` |\n| `d` | y |\n\nAfter.\n| `e` | z |")
      == ["a.b", "a.c", "d"], "the README table's first column is read, and nothing after the table")
check(readme_events("### Event stream\n\n| Name | x |\n| --- | --- |\n| `a.b` | y |") is None,
      "a table under the heading with another header is not taken for the event table")
commands_table = ("## Scripting API\n\n| Command | Parameters |\n| --- | --- |\n"
                  "| `help`, `ping`, `app.info` | — |\n| `browser.open` / `newTab` / `tab.list` | `url` |\n"
                  "| `subscribe` / `unsubscribe` | `events` |\n| `a.b`, `c` | — |\n\n### Next\n| `zzz` | — |")
check(readme_commands(commands_table) == ["help", "ping", "app.info", "browser.open", "browser.newTab", "tab.list",
                                          "subscribe", "unsubscribe", "a.b", "c"],
      "the README command table's short names are read in full, and only after ` / ` (%s)" % readme_commands(commands_table))


# The real thing.
def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def relative(path):
    return os.path.relpath(path, ROOT)


lexed = {}
for folder, _, names in os.walk(SOURCES):
    for name in sorted(names):
        if name.endswith(".swift"):
            path = os.path.join(folder, name)
            try:
                lexed[path] = lex(read(path))
            except LexError as error:
                check(False, "%s could not be read: %s" % (relative(path), error))

published = {}
handled = {}
for path, tokens in sorted(lexed.items()):
    events, unreadable = published_events(tokens)
    for name, line in events:
        published.setdefault(name, "%s:%d" % (relative(path), line))
    for line in unreadable:
        check(False, "%s:%d: APIEvent's name is not a string literal, so this check cannot see it" % (relative(path), line))
    for names, unreadable in command_switches(tokens):
        for name in names:
            handled.setdefault(name, relative(path))
        for line in unreadable:
            check(False, "%s:%d: a `case` of `switch request.command` that is not string literals" % (relative(path), line))

router = os.path.join(API, "APIRouter.swift")
check(bool(command_switches(lexed.get(router, []))), "%s has a `switch request.command`" % relative(router))
check(len(published) > 0, "events are published somewhere in Sources")

all_events = string_array(lexed.get(os.path.join(API, "EventBus.swift"), []), "allEvents")
check(all_events is not None, "EventBus.allEvents is an array of string literals")
all_events = all_events or []
for name in sorted(set(published) - set(all_events)):
    check(False, "%s publishes %s, which EventBus.allEvents does not list" % (published[name], name))
for name in sorted(set(all_events) - set(published)):
    check(False, "EventBus.allEvents lists %s, which nothing publishes" % name)
for name in duplicates(all_events):
    check(False, "EventBus.allEvents lists %s twice" % name)

commands = string_array(lexed.get(router, []), "commands")
check(commands is not None, "APIRouter.commands is an array of string literals")
commands = commands or []
for name in sorted(set(handled) - set(commands)):
    check(False, "%s answers %s, which APIRouter.commands (what `help` lists) does not" % (handled[name], name))
for name in sorted(set(commands) - set(handled)):
    check(False, "APIRouter.commands lists %s, which no `switch request.command` answers" % name)
for name in duplicates(commands):
    check(False, "APIRouter.commands lists %s twice" % name)

readme = read(os.path.join(ROOT, "README.md"))
documented = readme_commands(readme)
check(documented is not None, "README.md has a command table (header `Command`) under \"## Scripting API\"")
documented = documented or []
for name in sorted(set(commands) - set(documented)):
    check(False, "README.md's command table does not list %s" % name)
for name in sorted(set(documented) - set(commands)):
    check(False, "README.md's command table lists %s, which is not in APIRouter.commands" % name)

documented = readme_events(readme)
check(documented is not None, "README.md has an event table (header `Event`) under \"### Event stream\"")
documented = documented or []
for name in sorted(set(all_events) - set(documented)):
    check(False, "README.md's event table does not list %s" % name)
for name in sorted(set(documented) - set(all_events)):
    check(False, "README.md's event table lists %s, which is not in EventBus.allEvents (write each name in full)" % name)

print("%d/%d API list checks passed (%d events, %d commands)" % (checks - failures, checks, len(all_events), len(commands)))
sys.exit(0 if failures == 0 else 1)
