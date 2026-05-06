---
name: flow42-cli
description: |
  Reference for the flow42 CLI: every verb, every flag, every output shape.
  Invoke this skill whenever you're about to run a `flow42 <command>` and
  you want to be sure of the syntax — record, play (start / current / next /
  pause / resume / wait / end / show / list / log), do (click / type / press /
  hotkey / scroll / hover / drag / long-press / window / app-switch / focus /
  navigate), stop, snapshot, tree, state, find, inspect, element-at, read,
  annotate, wait, flows, view, chrome-launch, install. Both native and
  `--target browser`. Also fire when handed a recording — every step's
  `meta.yaml` carries a `replicate` field whose value is a CLI invocation
  that drops directly into a shell, no reconstruction needed.
---

## Architecture in one paragraph

Every command is `flow42 <verb>` and prints **one JSON line** on stdout. `--target` defaults to `native`; pass `--target browser` (or simply supply `--locator` / `--tab`, which infers it) to route to a Chrome attached via `flow42 chrome-launch`. The vocabulary is the same on both sides — the same `--query` / `--locator` / `--text` / `--key` / `--direction` flags work, the same JSON shape comes back. Failures emit `{success: false, error, suggestion?}`. Every result is one line; pipe through `jq` if you want it pretty.

## What lives where (verb categories)

This catches the most common mistake — assuming everything is under `do`. It isn't.

- **Lifecycle (sessions):** `record` (capture a flow); `play` (execute one — `start | current | next | pause | resume | wait | end | show | list | log`); `stop` (universal end). Singleton invariant: only one session active at a time.
- **`flow42 do <verb>`** — INPUT actions only. Gated: requires an active driving play. The verbs are exactly: `click`, `type`, `press`, `hotkey`, `scroll`, `hover`, `long-press`, `drag`, `window`, `app-switch`, `focus`, `navigate`. Nothing else.
- **Top-level verbs (NOT under `do`)** — discovery: `state`, `tree`, `find`, `inspect`, `element-at`, `read`, `snapshot`, `annotate`. Synchronization: `wait`. Setup: `setup`, `doctor`, `status`, `install`, `install-skills`, `chrome-launch`, `native-host`. Reading flows: `flows`, `view`.

**Common syntax mistakes — DO NOT write these:**

| Wrong | Right |
|---|---|
| `flow42 do wait` | `flow42 wait` |
| `flow42 do find` | `flow42 find` |
| `flow42 do snapshot` | `flow42 snapshot` |
| `flow42 do tree` | `flow42 tree` |
| `flow42 do inspect` | `flow42 inspect` |
| `flow42 do state` | `flow42 state` |
| `flow42 do read` | `flow42 read` |
| `flow42 context` | `flow42 tree` (no `context` verb exists; `tree` is the equivalent of Ghost OS's `ghost_context`) |
| `flow42 do element-at` | `flow42 element-at` |
| `flow42 do annotate` | `flow42 annotate` |
| `flow42 act <verb>` | `flow42 do <verb>` (the `act` namespace was renamed to `do`; old recordings have stale `replicate` strings) |
| `flow42 mode set <X>` | gone — use `flow42 record start/stop`, `flow42 play …`, `flow42 stop` |
| `flow42 do annotations` | `flow42 annotations` (top-level; do not confuse with `flow42 annotate`) |

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
| `flow42 do click --x N --y N` or `--query Q [--role R]` or `--dom-id ID` `[--button left|right|middle] [--count N] [--app NAME]` | click |
| `flow42 do type --text T [--into FIELD] [--dom-id ID] [--clear] [--app NAME]` | type into focused field |
| `flow42 do press --key K [--modifiers cmd,shift,…] [--app NAME]` | single key |
| `flow42 do hotkey --keys cmd,shift,t [--app NAME]` | combo |
| `flow42 do scroll --direction up\|down\|left\|right [--amount N] [--x N --y N] [--app NAME]` | scroll |
| `flow42 do hover --x N --y N` or `--query Q` `[--app NAME]` | hover |
| `flow42 do long-press --x N --y N --duration S [--button left|right] [--app NAME]` | press-and-hold |
| `flow42 do drag --to-x N --to-y N [--from-x N --from-y N \| --query Q] [--duration S] [--hold-duration S] [--app NAME]` | drag |
| `flow42 do window --action list\|minimize\|maximize\|close\|move\|resize --app NAME [--window-title T] [--x N --y N --width W --height H]` | window management |
| `flow42 do app-switch --to BUNDLE_ID_OR_NAME` | bring app to front |
| `flow42 do focus --app NAME` | focus app |
| `flow42 do navigate --url URL [--tab N]` | browser-only |

Every `act` verb accepts `--target browser` (or infers it from `--locator` / `--tab`) and routes to the attached browser session. Browser uses Playwright-style locator strings: `getByRole('role', { name: 'name' })`, `getByText('text')`, `locator('css')`, `getByLabel(...)`, `getByPlaceholder(...)`, `getByTestId(...)`.

### Examples

```bash
# Native click by coordinates
flow42 do click --x 100 --y 200 --button left --count 1 --app Calendar

# Native click by AX query
flow42 do click --query "Today" --app Calendar

# Type into a specific field by name (focuses first)
flow42 do type --text "Standup" --into "Title" --app Calendar

# Cmd+Shift+T hotkey in the frontmost app
flow42 do hotkey --keys cmd,shift,t

# Drag from one point to another natively
flow42 do drag --from-x 100 --from-y 200 --to-x 300 --to-y 200

# Browser click by Playwright locator
flow42 do click --target browser --locator "getByRole('button', { name: 'Save' })"

# Browser type by locator
flow42 do type --target browser --locator "getByPlaceholder('Search')" --text "find me"

# Browser navigation
flow42 do navigate --url https://example.com
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
flow42 do click --target browser --locator "getByRole('button', { name: 'Continue' })"
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

`start` returns a JSON line with `path`, `slug`, `pid`, and `stop_command`. `stop` blocks while whisper transcribes narration, then closes out the canonical layout (`steps/`, `events.jsonl`, top-level `meta.yaml`, optional `audio/`) and prints the action count.

**Interactive (human at a real terminal):**
```
flow42 record [--description D]   # blocks the terminal; type `done` to stop
```

In both modes: narration is captured via the mic and transcribed at stop-time. Recordings land in `~/.flow42/flows/<slug>/` with `steps/NNNN-action_type/{meta.yaml, screenshot.jpg, annotated.jpg}` per step plus a top-level `events.jsonl` index, top-level `meta.yaml`, and (when narration was on) `audio/narration.{wav,txt}`. After recording, invoke the `flow-creator` skill from Claude Code on the recording dir — it runs a four-pass workflow (detect phases → detect params → strip noise + assemble GUI paths → propose headless alternatives) and writes `flow.yaml`. Render the result with `flow42 view <flow-dir>`.

## Rendering a structured flow — `flow42 view`

Once the agent has written `flow.yaml` for a recording, render it back with:

```
flow42 view <flow-dir>                              # human-readable markdown
flow42 view <flow-dir> --path osascript             # runnable osascript across all phases
flow42 view <flow-dir> --path shell                 # runnable shell script
flow42 view <flow-dir> --output replay.md           # write to file instead of stdout
```

Default mode renders: `task_description` lead, params table, then each phase by name + intent (with `note:` as a 📝 callout if present), then the GUI path's `text` + screenshots inline, then headless alternatives in a collapsible `<details>` section.

`--path <kind>` mode emits a runnable script that strings together the chosen `kind` (e.g. `osascript`) across all phases. If a phase has no path of that kind, a comment in the output flags the gap rather than silently skipping. `${param}` placeholders are left intact in script mode — the runner substitutes at execute time.

No LLM at render time; the renderer is deterministic.

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
  "replicate": "flow42 do click --x 1327 --y 1167.25 --button left --count 1 --app 'Google Chrome'",
  "replicate_argv": ["act", "click", "--x", "1327", "--y", "1167.25", "--button", "left", "--count", "1", "--app", "Google Chrome"]
}
```

Use the string for human reading and shell pipelines; use the argv array for direct exec without `/bin/sh`. Both reproduce the captured action verbatim.

## Output shape contract

- Success: `{success: true, …command-specific keys}`.
- Failure: `{success: false, error: STR, suggestion?: STR}`.
- One JSON line per call.
- Process exit code: 0 on success, non-zero on failure.

### Verified actions — fail-hard semantics

`flow42 do` against `--target browser` runs **post-action verification** for click / type / navigate so a `success: true` actually means the action achieved something observable. When verification fails, the call returns `success: false` with a specific error. **Trust the success bit.**

- **`navigate`** — verifies `page.url()` after `goto`. If the host or pathname differs from the requested URL (silent SPA bounce, auth redirect to `/`, etc.) or the response status is ≥ 400, fails hard.
- **`type` (browser)** — reads back `inputValue()` (or `value` / `textContent` for non-`<input>` widgets) after `fill`. If it doesn't match the typed text, fails hard. Catches readonly fields, custom widgets that ignore `.fill()`, and React controlled components that reset.
- **`click` (browser)** — captures URL + document size + active-element signature before and after, then asserts at least one changed (or that the target element disappeared). If nothing changed, fails hard with `click dispatched but had no observable effect`. Catches overlay-intercepted clicks, inert elements, and React's trusted-event rejections.

Successful verified responses include `"verified": true` so calling code can spot the distinction:

```json
{"success":true,"method":"locator","verified":true,"url":"http://localhost:3000/login"}
```

Native-target actions (no `--target browser`) do **not** currently run post-action verification — the synthetic CGEvent path has no reliable read-back. For native actions, prefer `flow42 wait --condition <cond>` immediately after to confirm the expected state change.

## Browser specifics

- `flow42 chrome-launch` — launches the **dedicated flow42 Chrome profile** (`~/Library/Application Support/flow42-chrome/`) on `--remote-debugging-port=9222` with the flow42 extension auto-loaded. **Idempotent:** if the dedicated Chrome is already running on that profile, Chrome dedupes and the call just brings the existing window to front. Run this once per machine for the first launch (or via `flow42 setup-browser` for a guided wizard); after that, the runtime keeps the profile alive between sessions.
  - **The user's personal Chrome is untouched** — it lives in its own default profile and never gets a debug endpoint. `flow42 do --target browser` only ever attaches to the dedicated profile.
  - **Never use `open -a "Google Chrome"` / `open -b com.google.Chrome` / `osascript -e 'tell app "Google Chrome" to activate'`** as substitutes. Those activate whichever Chrome the OS considers default (typically the personal one), which has no CDP endpoint and no extension — every downstream browser action fails. Always go through `flow42 chrome-launch`.
  - For Chrome **navigation**, use `flow42 do navigate --url <URL>` rather than `open -a "Google Chrome" <URL>` — same reason.
- Locator strings come straight from the recorder's emit (`getByRole`, `getByText`, `locator('css')` etc.).
- Multiple tabs: pass `--tab N` (currently zero-indexed across all attached pages); omit to target the most recently active page.
- Same JSON shape as native — code on top doesn't care which side ran.

## Sessions: `flow42 record`, `flow42 play`, `flow42 stop`

State lives at `~/.flow42/state.json`. The menu app watches this file and renders a screen-edge glow accordingly. **Singleton invariant:** at most one session (recording OR play) is active at a time.

The four runtime states the menu app branches on:

- `idle` — no session, no glow
- `recording` — magenta glow (set by `flow42 record start`)
- `driving` — orange glow + agent-in-control pill + cursor companion + bottom-right floating window (set by `flow42 play`)
- `watching` — cyan glow + floating window (set by `flow42 play --watch` OR by `flow42 play pause` flipping a driving play)

### `flow42 record` — capture a flow (existing)

```
flow42 record start [--description X]    # opens a recording session
flow42 record stop                        # finalises (writes meta.yaml + steps/)
flow42 record status
flow42 flows                              # list past recordings
```

### `flow42 play` — execute a flow (NEW)

The execution surface. Open a play first, then issue `flow42 do *` calls inside it (see below). The agent's canonical loop (start → current → advance → pause-on-stuck → wait → resume → end) lives in the `flow-player` skill — invoke that skill when the user asks you to run a flow.

| Command | Effect |
|---|---|
| `flow42 play <flow-dir> [--watch] [--by <agent>] [--label "..."]` | Start a play. Default state: driving. `--watch` flips to user-driven. Returns the first phase + params. |
| `flow42 play current` | Print the current phase only — params resolved, paths in cheapest-first order. **The only phase source during a play.** Never read flow.yaml directly. |
| `flow42 play next` | Mark current phase complete, advance, return the new phase or `{done: true}`. |
| `flow42 play pause --reason "<one line>"` | Hand off to the user. Flips driving → watching. The reason surfaces in the floating window. |
| `flow42 play resume` | Flip back to driving. |
| `flow42 play wait [--timeout SECS]` | Block until the play is no longer paused (state == driving) or until it ends. Returns the new state. |
| `flow42 play end [--reason completed\|user_stopped\|agent_stopped]` | Close the active play. |
| `flow42 play show [<id>]` | Print play.yaml + log tail. |
| `flow42 play list <flow-dir>` | List plays (newest first). |
| `flow42 play log <event_type> [--key value ...]` | Append a custom event to the active play's log.jsonl. |

### `flow42 stop` — end whatever's active

```
flow42 stop
```

Idempotent. Ends a recording OR a play OR no-ops if idle. The floating window's Stop button and the top pill's Stop button both shell out to this.

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
