---
name: flow42-cli
description: |
  Reference for the flow42 CLI: every verb, every flag, every output shape.
  Invoke this skill whenever you're about to run a `flow42 <command>` and
  you want to be sure of the syntax — record, act (click / type / press /
  hotkey / scroll / hover / drag / long-press / window / app-switch /
  focus / navigate), snapshot, tree, state, find, inspect, element-at,
  read, annotate, wait, flows, chrome-launch, install. Both native and
  `--target browser`. Also fire when handed a `flow.json` recording —
  every action carries a `replicate` field whose value is a CLI
  invocation that drops directly into a shell, no reconstruction needed.
---

## Architecture in one paragraph

Every command is `flow42 <verb>` and prints **one JSON line** on stdout. `--target` defaults to `native`; pass `--target browser` (or simply supply `--locator` / `--tab`, which infers it) to route to a Chrome attached via `flow42 chrome-launch`. The vocabulary is the same on both sides — the same `--query` / `--locator` / `--text` / `--key` / `--direction` flags work, the same JSON shape comes back. Failures emit `{success: false, error, suggestion?}`. Every result is one line; pipe through `jq` if you want it pretty.

## What lives where (verb categories)

This catches the most common mistake — assuming everything is under `act`. It isn't.

- **`flow42 act <verb>`** — INPUT actions only. The verbs are exactly: `click`, `type`, `press`, `hotkey`, `scroll`, `hover`, `long-press`, `drag`, `window`, `app-switch`, `focus`, `navigate`. Nothing else.
- **Top-level verbs (NOT under `act`)** — discovery: `state`, `tree`, `find`, `inspect`, `element-at`, `read`, `snapshot`, `annotate`. Synchronization: `wait`. Recording: `record`, `flows`. Setup: `setup`, `doctor`, `status`, `install`, `install-skills`, `chrome-launch`, `native-host`.

**Common syntax mistakes — DO NOT write these:**

| Wrong | Right |
|---|---|
| `flow42 act wait` | `flow42 wait` |
| `flow42 act find` | `flow42 find` |
| `flow42 act snapshot` | `flow42 snapshot` |
| `flow42 act tree` | `flow42 tree` |
| `flow42 act inspect` | `flow42 inspect` |
| `flow42 act state` | `flow42 state` |
| `flow42 act read` | `flow42 read` |
| `flow42 context` | `flow42 tree` (no `context` verb exists; `tree` is the equivalent of Ghost OS's `ghost_context`) |
| `flow42 act element-at` | `flow42 element-at` |
| `flow42 act annotate` | `flow42 annotate` |
| `flow42 act mode` | `flow42 mode` (menu-app coordination — top-level, not under `act`) |
| `flow42 act annotations` | `flow42 annotations` (top-level; do not confuse with `flow42 annotate`) |

When in doubt about a command's exact form, check the tables below or run `flow42 --help` / `flow42 <verb> --help`.

## Discovery

| Command | Returns | Common use |
|---|---|---|
| `flow42 state [--app NAME] [--target browser]` | `{apps: [{pid, name, bundle_id, active, windows}]}` | "Is X running? what windows?" |
| `flow42 tree [--app NAME] [--target browser] [--output PATH]` | full hierarchy of frontmost (or named) app/page | initial orientation |
| `flow42 find --query Q --role R --dom-id ID --dom-class C --identifier I [--depth N] [--app NAME] [--target browser]` | `{elements: [{role, name, position, size, identifier, …}], total_matches}` | locate a named element |
| `flow42 inspect --query Q \| --dom-id ID [--role R] [--app NAME] [--target browser]` | full metadata for one element: role, position, frame, identifier, computed_name, parent_role, focused, enabled, actionable | confirm one element before acting on it |
| `flow42 element-at --x N --y N [--target browser]` | element at the pixel | convert a screenshot coord into something to act on |
| `flow42 read [--query Q] [--depth N] [--app NAME] [--target browser]` | `{content: STR, item_count: N}` | get text from an app or subtree |
| `flow42 snapshot [--app NAME] [--output PATH] [--target browser]` | JSON+base64 image, or raw bytes if `--output` | visual disambiguation |
| `flow42 annotate [--app NAME] [--roles a,b] [--max-labels N] [--output PATH] [--target browser]` | numbered overlay screenshot + label map | "click number 3" workflows |

### Examples

```bash
# Frontmost app's full hierarchy
flow42 tree

# Find any element matching "Save" in Notes
flow42 find --query "Save" --app Notes

# Full metadata for one element
flow42 inspect --query "Today" --app Calendar

# What's at this pixel?
flow42 element-at --x 1327 --y 1167

# Browser side: full DOM/AX tree of the active page
flow42 tree --target browser

# Same call against a specific tab index
flow42 tree --target browser --tab 0

# Image of the current Chrome page, written to disk
flow42 snapshot --target browser --output /tmp/page.jpg
```

## Action

| Command | Effect |
|---|---|
| `flow42 act click --x N --y N` or `--query Q [--role R]` or `--dom-id ID` `[--button left|right|middle] [--count N] [--app NAME]` | click |
| `flow42 act type --text T [--into FIELD] [--dom-id ID] [--clear] [--app NAME]` | type into focused field |
| `flow42 act press --key K [--modifiers cmd,shift,…] [--app NAME]` | single key |
| `flow42 act hotkey --keys cmd,shift,t [--app NAME]` | combo |
| `flow42 act scroll --direction up\|down\|left\|right [--amount N] [--x N --y N] [--app NAME]` | scroll |
| `flow42 act hover --x N --y N` or `--query Q` `[--app NAME]` | hover |
| `flow42 act long-press --x N --y N --duration S [--button left|right] [--app NAME]` | press-and-hold |
| `flow42 act drag --to-x N --to-y N [--from-x N --from-y N \| --query Q] [--duration S] [--hold-duration S] [--app NAME]` | drag |
| `flow42 act window --action list\|minimize\|maximize\|close\|move\|resize --app NAME [--window-title T] [--x N --y N --width W --height H]` | window management |
| `flow42 act app-switch --to BUNDLE_ID_OR_NAME` | bring app to front |
| `flow42 act focus --app NAME` | focus app |
| `flow42 act navigate --url URL [--tab N]` | browser-only |

Every `act` verb accepts `--target browser` (or infers it from `--locator` / `--tab`) and routes to the attached browser session. Browser uses Playwright-style locator strings: `getByRole('role', { name: 'name' })`, `getByText('text')`, `locator('css')`, `getByLabel(...)`, `getByPlaceholder(...)`, `getByTestId(...)`.

### Examples

```bash
# Native click by coordinates
flow42 act click --x 100 --y 200 --button left --count 1 --app Calendar

# Native click by AX query
flow42 act click --query "Today" --app Calendar

# Type into a specific field by name (focuses first)
flow42 act type --text "Standup" --into "Title" --app Calendar

# Cmd+Shift+T hotkey in the frontmost app
flow42 act hotkey --keys cmd,shift,t

# Drag from one point to another natively
flow42 act drag --from-x 100 --from-y 200 --to-x 300 --to-y 200

# Browser click by Playwright locator
flow42 act click --target browser --locator "getByRole('button', { name: 'Save' })"

# Browser type by locator
flow42 act type --target browser --locator "getByPlaceholder('Search')" --text "find me"

# Browser navigation
flow42 act navigate --url https://example.com
```

## Synchronization

```
flow42 wait --condition X --value V [--timeout 10] [--interval 0.25] [--app NAME] [--locator L] [--target browser]
```

Conditions: `urlContains | urlEquals | urlChanged | titleContains | titleEquals | titleChanged | elementExists | elementGone`.

Insert between any two action commands that depend on UI transitions; flat sleeps are flaky.

```bash
# Wait for the page title to contain "Order placed"
flow42 wait --condition titleContains --value "Order placed" --timeout 10 --target browser

# Wait for a button to appear, then click it
flow42 wait --condition elementExists --locator "getByRole('button', { name: 'Continue' })" --target browser
flow42 act click --target browser --locator "getByRole('button', { name: 'Continue' })"
```

## Recording

Two modes — pick based on whether you have a TTY.

**Background daemon (agent-friendly, recommended):**
```
flow42 record start [--description D]   # forks daemon, returns JSON immediately
flow42 record status                     # is anything recording right now?
flow42 record stop                       # signals daemon, blocks for finalise (~1-30s), prints final stats
flow42 flows [--json]                    # list past recordings
flow42 structure <flow-dir>              # prepare a recording for the agent's three-pass flow
flow42 view <flow-dir> [--path KIND]     # render flow.yaml to markdown (or a runnable script)
```

`start` returns a JSON line with `path`, `slug`, `pid`, and `stop_command`. `stop` blocks while whisper transcribes narration, then closes out the v2 layout (`steps/`, `events.jsonl`) and prints the action count.

**Interactive (human at a real terminal):**
```
flow42 record [--description D]   # blocks the terminal; type `done` to stop
```

In both modes: narration is captured via the mic and transcribed at stop-time. Recordings land in `~/.flow42/flows/<slug>/` with the v2 layout (`steps/NNNN-action_type/{meta.yaml, screenshot.jpg, annotated.jpg}` per step plus a top-level `events.jsonl` index). A legacy `flow.json` is also tee'd alongside for the menu timeline; that goes away in Phase C. After recording, run `flow42 structure <flow-dir>` and let the agent (Claude Code or the future Flow app) author `flow.yaml` via the three-pass flow-creator skill.

## The `replicate` field

Every step's `meta.yaml` (under `steps/NNNN-action_type/`) carries:
- `replicate`: a POSIX-shell-safe command string.
- `replicate_argv`: an argv array that bypasses shell quoting entirely.

```jsonc
{
  "action_type": "click",
  "x": 1327, "y": 1167.25,
  "app": "Google Chrome",
  // …
  "replicate": "flow42 act click --x 1327 --y 1167.25 --button left --count 1 --app 'Google Chrome'",
  "replicate_argv": ["act", "click", "--x", "1327", "--y", "1167.25", "--button", "left", "--count", "1", "--app", "Google Chrome"]
}
```

Use the string for human reading and shell pipelines; use the argv array for direct exec without `/bin/sh`. Both reproduce the captured action verbatim.

## Output shape contract

- Success: `{success: true, …command-specific keys}`.
- Failure: `{success: false, error: STR, suggestion?: STR}`.
- One JSON line per call.
- Process exit code: 0 on success, non-zero on failure.

## Browser specifics

- `flow42 chrome-launch` once per machine. Quits any running Chrome (asks first) and starts it with the local debug endpoint enabled, using your normal profile dir. After this, every `--target browser` invocation works.
- Locator strings come straight from the recorder's emit (`getByRole`, `getByText`, `locator('css')` etc.).
- Multiple tabs: pass `--tab N` (currently zero-indexed across all attached pages); omit to target the most recently active page.
- Same JSON shape as native — code on top doesn't care which side ran.

## Mode & annotations (menu-bar app)

When the Flow42 menu bar app is running, two CLI surfaces coordinate with it:

### `flow42 mode`

Single source of truth at `~/.flow42/state.json`. The menu app watches this file and renders a screen-edge glow accordingly. Three modes exist; that's the entire vocabulary:

- `idle` — no glow
- `recording` — magenta glow (set automatically by `flow42 record start` / cleared by `flow42 record stop`; you don't need to touch it during recording)
- `autonomous` — orange glow (set by an agent before it starts driving the screen, cleared when it's done)

| Command | Effect |
|---|---|
| `flow42 mode get` | Print current state as one JSON line |
| `flow42 mode set autonomous --label "running mac-notes-save"` | Light up the orange edge glow + status icon while you act on the screen |
| `flow42 mode set idle` | Clear the glow (revert to no-glow) |

**Always** wrap autonomous-driving sequences in a set-autonomous / set-idle pair. The user sees a visible signal while the screen is being clicked at; without it the activity is invisible to them.

### `flow42 annotations`

Annotations are user-pinned visual context: the user presses Cmd+Shift+A, drags a region (rectangle or circle/lasso), optionally types a note, and saves. The bundle that lands on disk has `meta.json` (rect + note + app/window context), `region.png` (screenshot of the region), and `ax.json` (accessibility-tree subtree under the region).

| Command | Returns |
|---|---|
| `flow42 annotations list [--json]` | Newest-first ids; `--json` includes full meta for each |
| `flow42 annotations show <id\|latest> [--output PATH]` | meta + base64-encoded region.png (or write raw bytes to `--output`) |
| `flow42 annotations clear [--older-than 7d]` | Bulk delete (older-than accepts `Ns / Nm / Nh / Nd` or raw seconds) |

When the user mentions "this thing here on screen" without telling you what it is, call `flow42 annotations show latest` first — they likely captured an annotation that names it.

## Setup commands

| Command | What it does |
|---|---|
| `flow42 setup` | Interactive first-run wizard (permissions). |
| `flow42 setup-browser` | **One-shot browser stack wizard.** Launches Chrome on the dedicated profile, auto-loads the extension, registers the native-messaging manifest with the deterministic extension ID, verifies the round-trip. Use this instead of running `chrome-launch` + `install` separately. Pass `--force` to quit any existing Chrome non-interactively. |
| `flow42 doctor` | Diagnostic health check. The Chrome/extension stack is **optional** — if it's not configured, doctor reports `[info]`, not `[FAIL]`. Recording and native-target actions work without it. |
| `flow42 status` | Quick line-summary: version + permission flags. |
| `flow42 install --extension-id ID` | Register the native-messaging manifest manually. **Usually unnecessary** — `setup-browser` does this with the right ID. |
| `flow42 install-skills [--target DIR] [--update]` | Drop `flow42-cli`, `flow-recorder`, `flow-creator` skills into `~/.claude/skills/`. |
| `flow42 chrome-launch [--port 9222] [--user-data-dir PATH] [--load-extension PATH]` | Lower-level: start Chrome with the debug endpoint and (by default) auto-load the unpacked extension from the repo's `dist/`. `setup-browser` calls this internally. |
| `flow42 native-host` | Run as the Chrome native-messaging host. Chrome invokes this; you don't. |
| `flow42 version` | Print version. |
