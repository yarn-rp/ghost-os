---
name: flow-recorder
description: |
  Capture a flow by recording the user actually doing the task. This is
  the FIRST step of teaching the agent something new — invoke when the
  user says "let's record", "I'm going to teach you", "watch me do this",
  "I'll show you a flow", "let me demo this", "record what I do", "I want
  to automate something — let me show you", or any phrasing that means
  "I'll perform the task; you watch." Zero-friction: do NOT ask any
  questions before starting. Run `flow42 record start` immediately,
  silently extracting a one-line label from the user's own trigger
  message if there is one. Stay silent during the recording. When the
  user says they're done, run `flow42 record stop` and automatically
  hand off to `flow-creator` to analyze the recording and produce
  documentation. Parameters, prerequisites, and step questions all
  belong to flow-creator AFTER recording — never before.
---

## Goal

Get a recording started with minimum friction, then hand off to `flow-creator`
once the user finishes. The whole point is to capture what they're already
about to do — don't slow them down with questions first.

## When to invoke

Phrases like:
- "let's record"
- "I'm going to teach you a flow"
- "watch me do this"
- "I'll show you how I do X"
- "let me demo this so you can do it next time"
- "I want to automate something — let me show you"
- "record what I do"

If the user wants to document an *existing* recording (no new recording
needed), skip to `flow-creator` directly with the path.

## Workflow — three steps, no questions

### Step 1 — Extract a label silently (don't ask)

Look at the user's trigger message. Pull out a one-sentence label if it's
there:

- "Let's record me saving a YouTube video to my Watch Later note." → label
  = `"saving a YouTube video to my Watch Later note"`
- "I'll show you how I schedule a meeting from a Slack message." → label =
  `"schedule a meeting from a Slack message"`
- "Watch this." → no clear label; pass nothing.
- "Let's record." → no clear label; pass nothing.

This becomes the `--description` flag. Keep it short (one phrase, lowercase
fine). It's metadata only — used by `flow42 flows` listings and as a hint
for `flow-creator`. The recording works just as well with no description.

**Do not ask the user to confirm or refine the label.** If you can't extract
one, just omit the flag.

### Step 2 — Start the recorder

Run:

```
flow42 record start --description "<label>"
```

(or just `flow42 record start` if you didn't extract a label).

This:
- Forks a recorder daemon that runs detached from your shell.
- Returns a JSON line **immediately** with the daemon's PID, the recording
  directory, and the stop command:
  ```json
  {"success": true, "path": "/Users/.../recipes/recording-<timestamp>",
   "slug": "...", "pid": NNNNN, "stop_command": "flow42 record stop"}
  ```
- Starts narration capture (whisper transcribes voice at stop time).
- Starts native event capture (mouse / keyboard / scroll via CGEventTap).
- Connects to the Chrome extension for browser-side capture if Chrome is
  running with the debug endpoint.

Capture the `path` from the response — you'll pass it to `flow-creator`.

**Use `flow42 record start`, NOT bare `flow42 record`.** Bare `record` is
the interactive (TTY) mode for humans typing `done` — it blocks the shell
and isn't drivable from an agent context.

### Step 3 — Tell the user, then SHUT UP

After the recorder is running, send ONE message and stop talking until they
say they're finished:

> "Recording. Go ahead — perform the task as you'd normally do it, and
> narrate what you're doing as you go (your voice gets transcribed and
> interleaved with the action stream). When you're finished, just tell me
> and I'll stop the recorder."

Do not interrupt. Do not ask clarifying questions during the recording. Do
not summarise progress. Do not check `flow42 record status` repeatedly.
The user is performing a real task; let them focus.

### Step 4 — Stop when the user says they're done

When the user says they're finished, run:

```
flow42 record stop
```

This:
- Tells the daemon to finalise (closes the step folders + events.jsonl,
  transcribes narration, writes audio/narration.txt).
- Blocks for up to 60 seconds while transcription completes.
- Returns a JSON line:
  ```json
  {"success": true, "path": "...", "slug": "...", "action_count": N,
   "duration_seconds": D}
  ```

Capture the `path`.

### Step 5 — Hand off to flow-creator

Immediately invoke `flow-creator` on the recording directory. Don't pause
to ask the user what to do next:

> "Recorded N actions over D seconds at `<path>`. Now I'll structure it —
> detect phases, find the parameters, strip noise, propose cheaper
> headless paths. One moment…"

Then load and run `flow-creator`. It runs a four-pass workflow that ends with `<path>/flow.yaml` — the single source of truth. No SKILL.md / human guide artifacts; markdown is rendered on demand by `flow42 view`.

## Hard rules

- **Zero questions before recording.** Extract a label silently from the
  user's trigger message; if you can't, omit the flag entirely. Never ask
  "what's the goal?" — that's friction.
- **Use `flow42 record start` and `flow42 record stop`** (not bare
  `flow42 record`).
- **Don't talk during the recording.** Send the "Recording. Go ahead…"
  message once and stop.
- **Hand off automatically.** Don't ask "want me to write up the docs?" —
  invoke `flow-creator` straight away.
- **Surface errors verbatim.** If `flow42 record start` fails, paste the
  error JSON and stop. Common causes: another recording is already active
  (run `flow42 record stop` first), or permissions weren't granted (have
  the user run `flow42 doctor`).
