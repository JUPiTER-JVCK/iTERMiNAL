# Design: `@ai` assistant

Status: **implemented** (PR #23). Kept as the design record; see
*What shipped differently* at the end.

## Goal

Make `@ai …` actually answer in the composer, with a pluggable provider,
without rewriting the floating composer UI.

## What exists today

`AssistantService` is a one-method seam: `isConfigured` plus
`complete(prompt:context:) async throws -> String`. Context today is only
`workingDirectory` and `recentOutput`. `NullAssistantService` always reports
unconfigured and throws `notConfigured`.

The composer already intercepts `@ai` in `ComposerBar.send()`: if the line
starts with `@ai` (case-insensitive), it clears the field and shows a banner
— “The AI assistant isn't configured yet…” — instead of sending to the
composer shell. It never calls `complete` yet.

Secrets already have a pattern via `KeychainStore` (same service used for the
local API token); those never go in UserDefaults, workspace state, or
export/import.

## Architecture

Keep the protocol; grow it carefully.

```
AssistantService
├── NullAssistantService          // default, unconfigured
├── OpenAICompatibleAssistant     // OpenAI / compatible base URL
└── (later) LocalModelAssistant   // Ollama etc.
```

Add a thin `AssistantServiceProvider` (mirror the Sync engine picker idea) so
Settings chooses the active service and the composer only talks to
`AssistantService`.

### Extend `AssistantContext` for v1 (still optional fields)

- `workingDirectory` — focused session cwd (already planned)
- `recentOutput` — last N lines from focused pane or composer transcript
- `gitBranch` — from `TerminalSession.gitBranch` when present
- `workspaceName` — current workspace
- `selection` — optional; leave nil in v1 unless there’s already a selection API

Do not send scrollback wholesale. Cap `recentOutput` (e.g. last ~4–8 KB) and
strip ANSI for the model.

### Return type

Today `complete` returns a bare `String`. For v1 that’s enough if the composer
appends the reply into its own transcript (or a dedicated assistant bubble
above the input). Prefer showing the reply in the composer UI rather than
injecting into a random terminal pane — the composer already owns its shell
and must not type secrets into background PTYs by default.

Optional later: `AssistantReply` with `text` + optional
`suggestedCommands: [String]` the user can click to run. Keep that out of v1
unless it’s cheap.

## Composer behavior

1. User submits `@ai explain this error` (strip the `@ai` / `@ai:` prefix
   once).
2. If `!isConfigured`: keep today’s banner, but point at Settings → AI.
3. If configured: show a short “Thinking…” state; call `complete`; render the
   reply in the composer UI; keep the prompt in composer history as `@ai …`
   so arrow-key recall works.
4. Cancel: if the user submits again or clears, cancel the in-flight `Task`.
5. Never auto-run model-suggested shell commands. Display only; user chooses
   what enters a PTY.

## Provider: OpenAI-compatible first

One implementation covering OpenAI and anything with the same chat-completions
shape (Groq, local proxies, Azure-compatible, etc.):

- Settings: provider preset (OpenAI / Custom base URL), model id, API key
- API key in `KeychainStore` under a dedicated account (e.g.
  `assistant.apiKey`) — never in preferences plist or Sync archives
- Base URL + model name can live in `AppSettings` (non-secret)
- `isConfigured` = non-empty keychain key

System prompt should state: you are helping inside a macOS terminal app;
prefer concise, actionable answers; when suggesting commands, mark them
clearly and do not claim they were executed.

**Local models (v1.1):** same OpenAI-compatible client pointed at
`http://127.0.0.1:11434/v1` (Ollama) with no key or a dummy key — don’t build
a separate protocol for that.

## Settings UX

New **Settings → AI** section (cleaner than burying under Security):

- Enable assistant (or just “configured when key present”)
- Provider / Base URL / Model
- API key field (write-only to keychain; show “Key saved” / Clear)
- Context toggles: include cwd, include recent output, include git branch
- Short privacy note: prompts and context go to the configured endpoint;
  secrets and full scrollback are not included by default

Security panel stays focused on the scripting API token.

## Privacy and safety

- Opt-in: no network calls until configured
- Keychain only for keys; exclude from `PreferencesArchive` / Sync (same rule
  as API token)
- Context allowlist, not “send the whole app state”
- No tool-calling into `iterminalctl` or `terminal.send` in v1 — that becomes
  a footgun for prompt injection from untrusted terminal output
- ATS stays on; if custom HTTP base URLs are allowed for local models,
  document the exception the way the browser pane documents plain-http preview

## Implementation order

1. Wire `ComposerBar.send()` to actually call `AssistantService.complete` with
   a built `AssistantContext`; replace the static banner with success/error UI.
2. `OpenAICompatibleAssistant` + keychain-backed settings + Settings → AI.
3. Cap and sanitize context; unit-test “encoded prefs never contain the key.”
4. Cancelable `Task`; basic streaming later if desired (non-streaming is fine
   for v1).
5. README: how to point at OpenAI or a local OpenAI-compatible server.

## Out of scope for v1

Agentic tool use (driving panes/browser via the scripting API), multi-turn chat
threads with persistence, image/vision, multiple named assistants, and anything
that auto-executes shell from model output.

## What shipped differently

**Recent output is off by default.** The context list above reads as though
every field travels; `recentOutput` is the one that uploads the visible screen
to a third party, and the screen may be showing `cat .env`. Nothing downstream
redacts secrets — "strip ANSI for the model" is a formatting step, not a
safety one — so it is opt-in, and the Settings copy says so plainly rather
than claiming secrets are excluded.

**`workspaceName` has its own switch.** It shipped sent unconditionally, which
contradicted the Settings caption promising only the listed fields travel.
Workspace names routinely name a client or an internal project.

**The cap is 6,000 characters**, at the lower end of the "~4–8 KB" suggested
here, and applied to what is on screen rather than to scrollback.

One caution for anyone extending this: the ANSI stripper is a regex built in a
Swift *raw* string, so the escape reaches ICU untouched and must be written
`\x{001B}`, not `\u{001B}`. Written the other way the pattern silently fails
to compile, `try?` yields nil, and the sanitiser returns its input unchanged —
which is indistinguishable from working until you look at what was actually
sent.
