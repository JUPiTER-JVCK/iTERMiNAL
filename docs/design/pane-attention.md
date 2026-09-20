# Design: pane attention notifications (OSC 9 / 777)

Status: design only — not implemented yet.

## Goal

When a background pane asks for attention (bell, OSC 9, OSC 777), surface that
in the UI and on the event bus — without spamming the user or waking every
plugin subscriber on ordinary scrollback paint.

## What exists today

- Sidebar already has an "unread / activity" visual language (blue dots for
  live background sessions; section headers can show an unread indicator).
- `TerminalEngine` exposes debounced `onActivity` for "the terminal repainted,"
  which feeds `session.activity` on `EventBus` (intentionally cheap and
  frequent).
- `EventBus.allEvents` lists session/tab/pane/browser/dock/composer events;
  there is no `session.attention` (or equivalent) yet.
- Roadmap wording: "Pane attention notifications (OSC 9/777) via the event
  bus."

Ordinary `session.activity` is the wrong signal for attention: it fires on
repaint. Attention is discrete and intentional (bell / OSC).

## Approach

### 1. Engine signal

Extend `TerminalEngine` (and `SwiftTermEngine`) with an attention callback,
separate from `onActivity`:

```swift
var onAttention: ((TerminalAttention) -> Void)? { get set }

enum TerminalAttention: Equatable {
    case bell
    case osc9(message: String)
    case osc777(title: String?, body: String?)
}
```

Parse in the SwiftTerm path where OSC / bell are already handled (or can be
hooked). Keep parsing behind the engine so a future libghostty backend can emit
the same enum without UI changes.

### 2. Session + store state

On `onAttention`:

- Mark the owning `TerminalSession` / pane with `needsAttention = true`
  (and optionally stash last message / kind / timestamp).
- Clear `needsAttention` when that pane (or its tab) becomes focused, or when
  the user explicitly dismisses.
- Drive sidebar / tab chrome from that flag (dot, bold title, or badge) —
  reuse existing unread styling where it already exists.

### 3. Event bus

Publish a new event, e.g. `session.attention`:

```jsonc
{
  "event": "session.attention",
  "data": {
    "session": "…",
    "kind": "bell" | "osc9" | "osc777",
    "title": "…",
    "body": "…",
    "focused": false
  }
}
```

Add it to `EventBus.allEvents`. Do **not** overload `session.activity`.

### 4. User-facing notifications (optional, gated)

Settings → Notifications (or under Terminal):

- Off / In-app only / In-app + system notification
- System notifications only when the app is inactive or the pane is unfocused
- Respect Focus / Do Not Disturb via normal `UNUserNotificationCenter` behavior
- Never send the full recent scrollback in a notification body — title/body
  from OSC only, truncated

Default: in-app only (sidebar/tab indicator). System banners opt-in.

### 5. Deduping

Coalesce rapid bells (e.g. one attention mark per session per ~1s). OSC 9/777
with identical text within that window update the timestamp rather than
stacking indicators.

## Implementation order

1. `TerminalAttention` + `onAttention` on the protocol; implement in
   `SwiftTermEngine`.
2. Session/store flags + clear-on-focus; sidebar/tab UI.
3. `session.attention` on `EventBus` + README event table.
4. Optional system notifications + Settings toggles.
5. Manual tests: `printf '\\a'`, OSC 9, OSC 777 from a background pane while
   another pane is focused.

## Out of scope for v1

- Forwarding attention over SSH/mosh beyond what the remote already encodes
- Custom notification sounds per profile
- Attention for browser panes (separate signal if ever needed)
- Changing the meaning or rate of `session.activity`
