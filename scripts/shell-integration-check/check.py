#!/usr/bin/env python3
"""Run iTERMiNAL's zsh shell-integration files in a real zsh and check what they do.

The file is one small .zshenv that iTERMiNAL points ZDOTDIR at. It has to add the
hooks that report each command's start and exit status, put ZDOTDIR back at once, and
load the person's own .zshenv, so that zsh reads everything else of theirs in its
usual order from where it really is. It runs inside someone's shell, so a mistake is
not a failed test, it is a broken terminal. Hence this runs it in a real zsh on a real
pseudo-terminal instead of trusting the text.

Usage:
    check.py <directory holding .zshenv>
    check.py --from-swift <ShellIntegration.swift>

The second form lifts the same text out of the Swift source, for a machine with no
Swift toolchain. CI uses the first, with the file the Swift code itself wrote.

Exits non-zero, printing what happened, if any check fails.
"""
import fcntl
import os
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

ZSH = shutil.which("zsh") or "/bin/zsh"
MARK = re.compile(rb"\x1b\]633;([^\x07\x1b]*)\x07")
TIMEOUT = 20


def extract_from_swift(swift: Path, into: Path) -> None:
    """Writes the wrapper file out of the raw string in the Swift source."""
    source = swift.read_text()
    names = {"zshEnvScript": ".zshenv"}
    for symbol, filename in names.items():
        found = re.search(r'private let ' + symbol + r' = #"""\n(.*?)\n"""#', source, re.S)
        if not found:
            sys.exit(f"could not find {symbol} in {swift}")
        (into / filename).write_text(found.group(1) + "\n")


class Session:
    """One interactive zsh on a pty, driven by writing lines and watching for marks."""

    def __init__(self, env, login=False):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 200, 0, 0))
        self.buffer = bytearray()
        self.master = master
        self.proc = subprocess.Popen(
            [ZSH, "-il" if login else "-i"],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            start_new_session=True,
            preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
            close_fds=True,
        )
        os.close(slave)

    def pump(self, until, what):
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            if until():
                return
            ready, _, _ = select.select([self.master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    if until():
                        return
                    break
                self.buffer.extend(chunk)
        raise TimeoutError(f"timed out waiting for {what}; output so far: {bytes(self.buffer)!r}")

    def marks(self):
        return [m.group(1).decode() for m in MARK.finditer(bytes(self.buffer))]

    def wait_for_marks(self, letter, count):
        self.pump(lambda: self.marks().count(letter) >= count, f"{count} x '{letter}' mark")

    def send(self, line):
        os.write(self.master, line.encode() + b"\n")

    def sync(self):
        """Waits for the shell to be reading input, with a token the echo cannot contain."""
        self.send("print SYNC$((6*7))")
        self.pump(lambda: b"SYNC42" in self.buffer, "the shell to answer")

    def finish(self):
        try:
            self.send("exit")
            self.pump(lambda: self.proc.poll() is not None, "the shell to exit")
        except TimeoutError:
            pass
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        os.close(self.master)


def base_env(home: Path, extra=None):
    env = {
        "HOME": str(home),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TERM": "dumb",
        "LANG": os.environ.get("LANG", "en_US.UTF-8"),
        "USER": os.environ.get("USER", "tester"),
        "SHELL": ZSH,
    }
    env.update(extra or {})
    return env


def trace_line(file, home_relative="$HOME/trace"):
    return f'print -r -- "{file} ZDOTDIR=${{ZDOTDIR-<unset>}}" >> "{home_relative}"\n'


QUIET = "PROMPT='READY> '; PROMPT_EOL_MARK=''\n"
PROBE = ('print -r -- "PROBE ZDOTDIR=${ZDOTDIR-<unset>} ORIG=${ITERMINAL_ZDOTDIR_ORIG-<unset>} '
         'HOOKS=${(j:,:)precmd_functions} PREEXEC=${(j:,:)preexec_functions} '
         'HISTFILE=${HISTFILE-<unset>} EXPORTED=$(env | grep -c \'^ZDOTDIR=\')"')
PROBE_OUT = re.compile(
    rb"PROBE ZDOTDIR=(?P<zdotdir>[^\s$]\S*) ORIG=(?P<orig>\S+) HOOKS=(?P<hooks>\S*) "
    rb"PREEXEC=(?P<preexec>\S*) HISTFILE=(?P<histfile>\S+) EXPORTED=(?P<exported>\d)"
)

# What Apple's /etc/zshrc does, in the one place a test can put it: before anything else
# of theirs, it points the history file at ${ZDOTDIR:-$HOME}. If ZDOTDIR were still the
# wrapper's folder at that point, every tab's history would land there instead of in
# their own.
SYSTEM_RC = 'HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history\n'


def cycle(code):
    return ["C", f"D;{code}", "A"]


failures = []


def check(condition, message, session=None):
    if condition:
        print(f"  ok    {message}")
    else:
        print(f"  FAIL  {message}")
        failures.append(message)
        if session is not None:
            print(f"        output: {bytes(session.buffer)!r}")


def run_commands(session, commands, expected_prompts):
    """Sends commands and waits until the prompt has come back for each one."""
    for command in commands:
        session.send(command)
        expected_prompts += 1
        session.wait_for_marks("A", expected_prompts)
    time.sleep(0.2)
    return expected_prompts


def probe_of(session):
    found = PROBE_OUT.search(bytes(session.buffer))
    return {k: v.decode() for k, v in found.groupdict().items()} if found else None


def scenario_plain(wrapper: Path, login: bool):
    name = "login shell" if login else "interactive shell"
    print(f"\n{name}, no ZDOTDIR of the person's own")
    home = Path(tempfile.mkdtemp(prefix="itm-zsh-"))
    try:
        (home / ".zshenv").write_text(trace_line("zshenv"))
        (home / ".zprofile").write_text(trace_line("zprofile"))
        (home / ".zshrc").write_text(SYSTEM_RC + trace_line("zshrc") + QUIET)
        (home / ".zlogin").write_text(trace_line("zlogin"))
        session = Session(base_env(home, {"ZDOTDIR": str(wrapper)}), login=login)
        try:
            session.wait_for_marks("A", 1)
            commands = ["true", "false", "sh -c 'exit 42'", "", "echo hi", PROBE]
            run_commands(session, commands, 1)
            expected = ["A"] + cycle(0) + cycle(1) + cycle(42) + ["A"] + cycle(0) + cycle(0)
            check(session.marks() == expected, f"marks are A, then C / D;status / A for each command: {session.marks()}", session)
            trace = (home / "trace").read_text().splitlines()
            wanted = ["zshenv ZDOTDIR=<unset>"]
            if login:
                wanted.append("zprofile ZDOTDIR=<unset>")
            wanted.append("zshrc ZDOTDIR=<unset>")
            if login:
                wanted.append("zlogin ZDOTDIR=<unset>")
            check(trace == wanted, f"their startup files ran in zsh's order, each seeing no ZDOTDIR: {trace}")
            probe = probe_of(session)
            check(probe is not None, "the probe command answered", session)
            if probe:
                check(probe["zdotdir"] == "<unset>" and probe["exported"] == "0",
                      f"ZDOTDIR is unset again afterwards (exported copies: {probe['exported']})")
                check(probe["orig"] == "<unset>", "the hand-over variable is gone")
                check(probe["hooks"].split(",").count("__iterminal_precmd") == 1 and probe["hooks"].startswith("__iterminal_precmd"),
                      f"the precmd hook is installed once, first: {probe['hooks']}")
                check(probe["preexec"].split(",").count("__iterminal_preexec") == 1, f"the preexec hook is installed once: {probe['preexec']}")
                check(probe["histfile"] == f"{home}/.zsh_history",
                      f"anything reading ZDOTDIR after .zshenv (as Apple's /etc/zshrc does for the history file) sees theirs: {probe['histfile']}")
            start = bytes(session.buffer).split(b"\x1b]633;A\x07")[0]
            noise = [w for w in (b"command not found", b"no such file", b"parse error", b"bad ", b"zsh:") if w in start.lower()]
            check(not noise, f"nothing but the mark was printed before the first prompt: {start!r}")
        finally:
            session.finish()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_callers_zdotdir(wrapper: Path):
    print("\nthe person had ZDOTDIR set before iTERMiNAL started zsh")
    home = Path(tempfile.mkdtemp(prefix="itm-zsh-"))
    try:
        real = home / "zd"
        real.mkdir()
        (real / ".zshenv").write_text(trace_line("zshenv"))
        (real / ".zshrc").write_text(SYSTEM_RC + trace_line("zshrc") + QUIET)
        (home / ".zshrc").write_text('echo WRONG >> "$HOME/trace"\n' + QUIET)
        env = base_env(home, {"ZDOTDIR": str(wrapper), "ITERMINAL_ZDOTDIR_ORIG": str(real)})
        session = Session(env)
        try:
            session.wait_for_marks("A", 1)
            run_commands(session, [PROBE], 1)
            trace = (home / "trace").read_text().splitlines()
            check(trace == [f"zshenv ZDOTDIR={real}", f"zshrc ZDOTDIR={real}"],
                  f"their files ran from their ZDOTDIR, and saw it: {trace}")
            check("WRONG" not in "\n".join(trace), "the .zshrc in the home folder was not read instead")
            probe = probe_of(session)
            check(probe is not None, "the probe command answered", session)
            if probe:
                check(probe["zdotdir"] == str(real), f"ZDOTDIR is theirs: {probe['zdotdir']}")
                check(probe["exported"] == "1", "and is exported, as it came in")
                check(probe["orig"] == "<unset>", "the hand-over variable is gone")
                check(probe["histfile"] == f"{real}/.zsh_history", f"and a reader after .zshenv sees it: {probe['histfile']}")
            check(session.marks()[:1] == ["A"] and "D;0" in session.marks(), f"marks still arrive: {session.marks()}")
        finally:
            session.finish()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_moved_by_zshenv(wrapper: Path):
    print("\ntheir own .zshenv moves ZDOTDIR (dotfiles under ~/.config)")
    home = Path(tempfile.mkdtemp(prefix="itm-zsh-"))
    try:
        config = home / ".config" / "zsh"
        config.mkdir(parents=True)
        (home / ".zshenv").write_text('export ZDOTDIR="$HOME/.config/zsh"\n')
        (config / ".zshrc").write_text(SYSTEM_RC + trace_line("zshrc") + QUIET)
        (home / ".zshrc").write_text('echo WRONG >> "$HOME/trace"\n' + QUIET)
        session = Session(base_env(home, {"ZDOTDIR": str(wrapper)}))
        try:
            session.wait_for_marks("A", 1)
            run_commands(session, [PROBE], 1)
            trace = (home / "trace").read_text().splitlines() if (home / "trace").exists() else []
            check(trace == [f"zshrc ZDOTDIR={config}"], f"the .zshrc they moved is the one that ran: {trace}")
            probe = probe_of(session)
            check(probe is not None and probe["zdotdir"] == str(config),
                  f"ZDOTDIR ends as they set it: {probe['zdotdir'] if probe else None}", session)
            check(probe is not None and probe["histfile"] == f"{config}/.zsh_history", "and so does anything that reads it later")
        finally:
            session.finish()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_status_survives_their_hooks(wrapper: Path):
    print("\ntheir own precmd function and hook run commands that fail")
    home = Path(tempfile.mkdtemp(prefix="itm-zsh-"))
    try:
        (home / ".zshrc").write_text(
            QUIET + "precmd() { false }\nuserhook() { false }\nprecmd_functions+=(userhook)\n"
        )
        session = Session(base_env(home, {"ZDOTDIR": str(wrapper)}))
        try:
            session.wait_for_marks("A", 1)
            run_commands(session, ["sh -c 'exit 7'"], 1)
            check(session.marks() == ["A"] + cycle(7), f"the status reported is the command's own: {session.marks()}", session)
        finally:
            session.finish()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_system_files(wrapper: Path):
    print("\nthe system's own startup files run, with nothing of the person's to help")
    home = Path(tempfile.mkdtemp(prefix="itm-zsh-"))
    try:
        (home / ".zshrc").write_text(QUIET)
        session = Session(base_env(home, {"ZDOTDIR": str(wrapper)}), login=True)
        try:
            session.wait_for_marks("A", 1)
            run_commands(session, [PROBE], 1)
            probe = probe_of(session)
            check(probe is not None, "the probe command answered", session)
            if probe:
                # Where a system file such as /etc/zshrc puts the history file, if it
                # sets one at all, is up to the system. What matters is that it was
                # never sent to the wrapper's folder.
                check(str(wrapper) not in probe["histfile"], f"the history file is not in the wrapper's folder: {probe['histfile']}")
                check(probe["zdotdir"] == "<unset>", "and ZDOTDIR is theirs here too")
        finally:
            session.finish()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_hostile_options(wrapper: Path):
    print("\ntheir .zshrc sets options that change how scripts behave")
    home = Path(tempfile.mkdtemp(prefix="itm-zsh-"))
    try:
        (home / ".zshrc").write_text(QUIET + "setopt NO_UNSET KSH_ARRAYS SH_WORD_SPLIT NO_GLOB NO_BARE_GLOB_QUAL\n")
        session = Session(base_env(home, {"ZDOTDIR": str(wrapper)}))
        try:
            session.wait_for_marks("A", 1)
            run_commands(session, ["false", "true"], 1)
            check(session.marks() == ["A"] + cycle(1) + cycle(0), f"marks and statuses are right: {session.marks()}", session)
        finally:
            session.finish()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_hostile_options_in_zshenv(wrapper: Path):
    print("\ntheir .zshenv sets those options (login shell)")
    home = Path(tempfile.mkdtemp(prefix="itm-zsh-"))
    try:
        (home / ".zshenv").write_text(trace_line("zshenv") + "setopt NO_UNSET KSH_ARRAYS SH_WORD_SPLIT NO_GLOB\n")
        (home / ".zprofile").write_text(trace_line("zprofile"))
        (home / ".zshrc").write_text(trace_line("zshrc") + QUIET)
        session = Session(base_env(home, {"ZDOTDIR": str(wrapper)}), login=True)
        try:
            session.wait_for_marks("A", 1)
            run_commands(session, ["false"], 1)
            check(session.marks() == ["A"] + cycle(1), f"marks and statuses are right: {session.marks()}", session)
            trace = (home / "trace").read_text().splitlines()
            check([t.split()[0] for t in trace] == ["zshenv", "zprofile", "zshrc"], f"and every one of their files still ran, in order: {trace}")
        finally:
            session.finish()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_not_interactive(wrapper: Path):
    print("\na non-interactive zsh that inherits the wrapper's ZDOTDIR")
    home = Path(tempfile.mkdtemp(prefix="itm-zsh-"))
    try:
        (home / ".zshenv").write_text(trace_line("zshenv"))
        env = base_env(home, {"ZDOTDIR": str(wrapper)})
        out = subprocess.run([ZSH, "-c", 'print -r -- "ran ZDOTDIR=${ZDOTDIR-<unset>} hooks=${#precmd_functions}"'],
                             env=env, capture_output=True, timeout=30)
        text = out.stdout.decode()
        check("\x1b]633" not in text and "hooks=0" in text, f"it gets no hooks and prints no marks: {text!r}")
        check("ZDOTDIR=<unset>" in text, "and ZDOTDIR is handed back to it too")
        check((home / "trace").read_text().splitlines() == ["zshenv ZDOTDIR=<unset>"], "and their .zshenv still ran, as it would have")
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_control_without_wrapper():
    print("\ncontrol: the same shell started without the wrapper")
    home = Path(tempfile.mkdtemp(prefix="itm-zsh-"))
    try:
        (home / ".zshrc").write_text(trace_line("zshrc") + QUIET)
        session = Session(base_env(home))
        try:
            session.sync()
            session.send("false")
            session.send("print AFTER$((6*7))")
            session.pump(lambda: b"AFTER42" in session.buffer, "the shell to answer")
            check(session.marks() == [], f"no marks at all without the wrapper: {session.marks()}", session)
            trace = (home / "trace").read_text().splitlines()
            check(trace == ["zshrc ZDOTDIR=<unset>"], f"and their .zshrc ran as it always did: {trace}")
        finally:
            session.finish()
    finally:
        shutil.rmtree(home, ignore_errors=True)


def main() -> int:
    args = sys.argv[1:]
    cleanup = None
    if len(args) == 2 and args[0] == "--from-swift":
        wrapper = Path(tempfile.mkdtemp(prefix="itm-wrapper-"))
        cleanup = wrapper
        extract_from_swift(Path(args[1]), wrapper)
    elif len(args) == 1:
        wrapper = Path(args[0]).resolve()
    else:
        print(__doc__)
        return 2
    try:
        missing = [n for n in (".zshenv",) if not (wrapper / n).is_file()]
        if missing:
            print(f"missing from {wrapper}: {', '.join(missing)}")
            return 2
        print(f"zsh: {subprocess.run([ZSH, '--version'], capture_output=True, text=True).stdout.strip()}")
        print(f"wrapper file: {wrapper / '.zshenv'}")
        scenario_plain(wrapper, login=False)
        scenario_plain(wrapper, login=True)
        scenario_callers_zdotdir(wrapper)
        scenario_moved_by_zshenv(wrapper)
        scenario_status_survives_their_hooks(wrapper)
        scenario_system_files(wrapper)
        scenario_hostile_options(wrapper)
        scenario_hostile_options_in_zshenv(wrapper)
        scenario_not_interactive(wrapper)
        scenario_control_without_wrapper()
    except TimeoutError as error:
        print(f"\nFAIL  {error}")
        return 1
    finally:
        if cleanup:
            shutil.rmtree(cleanup, ignore_errors=True)
    print()
    if failures:
        print(f"{len(failures)} check(s) failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("all shell-integration checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
