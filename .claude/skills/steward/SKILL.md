---
name: steward
description: How to drive an iTERMiNAL pull request to green with minimal owner involvement — this repo's conventions, its validation gate, its known traps, and the few things that still need human hands.
---

# Stewarding a PR on this repository

Read at CI and review events on a PR you opened or drive for its author. The
owner has asked for the flow to keep moving with little intervention, so the
default is **act, then report** — not ask, then wait.

## Be proactive within scope

Push fixes without checking in first for: any CI failure this PR caused, any
verified review-bot finding, any small local ask from a human reviewer, a
merge conflict against `main`, and any inaccuracy you find in your own diff.
Report what you did afterward in one message.

Check in first only when a change would alter what the app does beyond the
PR's stated scope, when two reasonable fixes lose different behaviour, or when
a human reviewer asks for something large.

Never widen a PR on your own initiative. A drive-by improvement that is not
what the failure or the comment needs belongs in its own change.

## This environment

- **No `gh` CLI, no direct GitHub API.** Use `mcp__github__*` tools. There is
  no tool here that can DELETE a release or a tag — say so plainly instead of
  attempting a workaround.
- **Linux container, macOS app.** You cannot build or run iTERMiNAL here. CI
  on `macos-15` is the only compiler. Never claim a Swift change compiles.
- `lipo` and `plutil` do not exist; `scripts/verify-bundle.py` reads the
  Mach-O fat header and Info.plist directly instead.

## The validation gate

CI takes about two and a half minutes and a red push costs a cycle and the
reviewers' trust. Before **every** push:

- **Workflow changes** — parse the YAML and syntax-check the shell it
  contains. Both, every time:

  ```sh
  python3 -c "
  import yaml
  d = yaml.safe_load(open('.github/workflows/build.yml'))
  pub = [s for s in d['jobs']['release']['steps'] if s.get('name')=='Publish'][0]
  open('/tmp/publish.sh','w').write(pub['run'])"
  bash -n /tmp/publish.sh
  ```

  A YAML file that parses can still hold shell that aborts at run time —
  particularly under `set -euo pipefail`, where a `grep` that matches nothing
  exits non-zero and kills the step. Prefer `awk`, or append `|| true`.

- **Shell logic with edge cases** — exercise it against real inputs in a
  throwaway git repo rather than reasoning about it. Selecting the previous
  `v*` tag was written wrong the first time and testing four tag shapes is
  what caught it.

- **Re-read your own diff adversarially** before pushing: what would make CI,
  or a reviewer, reject this?

## Traps specific to this repository

- **Immutable releases are enabled.** A tag name that has ever backed a
  published release is reserved permanently, and the reservation survives
  deleting both the release and the tag. `latest` is burned forever. Never
  design anything that reuses a tag; never "delete and recreate".
- **`run_number` is not unique.** It is workflow-scoped and unchanged on
  re-run. Build tags use `${GITHUB_RUN_ID}.${GITHUB_RUN_ATTEMPT}` because a
  tag collision is not a retryable failure — it burns that name for good.
- **Actions majors move independently**: `checkout@v5`, `upload-artifact@v6`,
  `download-artifact@v7`. Read each `action.yml` rather than bumping in step.
- **App Sandbox is off deliberately** (Hardened Runtime is on). A sandboxed
  terminal cannot reach `~/.ssh` or Homebrew. Do not "fix" this. Secrets live
  only in the Keychain — never in preferences, exports, logs, or the workspace
  archive.
- **Claims must match what the code guarantees.** Release notes, settings
  copy, and comments have all been caught asserting more than the check
  behind them proves. When you write a claim, ask what establishes it.

## After a release publishes

Verify contents, never presence — this project has shipped a Releases page
that looked current while the download was a week stale. Use the
`release-verify` agent, or `scripts/verify-bundle.py` directly. For a `v*`
tag, pass the expected version: the tag → `MARKETING_VERSION` override is the
one thing nothing else checks.

## Agents to hand work to

- `ci-triage` — a red run: root cause and the minimal patch, from the logs.
- `pr-review-triage` — several review comments: verified, classified.
- `release-verify` — a published release: assert the bundle, not the page.

## What still needs the owner

Do not attempt these, and do not imply they are handled:

- **Approving or merging.** Never, on any PR.
- **Marking a draft ready for review.**
- **Deleting a release or tag** — no capability exists in this session. Hand
  over the exact commands instead, and expect immutability to refuse them.

Keep a check-in scheduled until the PR is merged or closed. If nothing
changed, re-arm silently — do not narrate a quiet tick.
