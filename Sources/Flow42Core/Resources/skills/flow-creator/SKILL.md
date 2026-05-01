---
name: flow-creator
description: |
  Turn a flow42 recording into a structured `flow.yaml` via a three-pass
  workflow: detect phases, assemble the GUI path faithfully, propose
  cheaper headless alternatives. Invoke when handed a recording dir
  (auto-handed-off by `flow-recorder` after `flow42 record stop`, or
  manually with phrases like "structure this recording", "make a
  flow.yaml from `<dir>`", "process the recording at `<path>`"). The
  skill expects v2 layout — events.jsonl + steps/ — to already exist.
  No SKILL.md / human guide files are written: those are rendered on
  demand by `flow42 view` from the single source of truth that is
  flow.yaml.
---

## Goal

Given a recording directory in v2 layout, produce one file:

- `<flow-dir>/flow.yaml` — the structured source of truth: phases, GUI path per phase, headless alternatives where possible. Read by `flow42 view` for human / agent rendering, and by the future Flow app for editing.

We do NOT produce SKILL.md or `<skill-name>.md` artifacts. Markdown views are rendered on demand from `flow.yaml` via `flow42 view`. One source, two presentations.

## When to invoke

Trigger phrases:
- (auto) "Recording captured at `<path>` — now structure it" — handed off from `flow-recorder`.
- "structure this recording"
- "make a flow.yaml from `<recording-dir>`"
- "process the recording at `<path>`"

If the user wants to record something new, defer to `flow-recorder`.

## Workflow — three passes

The v2 model is deliberately phased. Each pass has a sharp input/output contract; mixing them muddles the result.

### Pass 1 — Phase detection

**Inputs:** `events.jsonl`, `audio/narration.txt` (if present). **Do NOT open `steps/`.**

`events.jsonl` is one line per step, lightweight: `idx`, `step_dir`, `action_type`, `app`, `summary`, optional `target` and `url`, `timestamp_ms`, `source`. That's the entire vocabulary you need at this pass.

A phase is a mini-flow with a clear postcondition. Three signals tend to mark a boundary:

1. **App / URL transitions** — a line followed by lines with a different `app` is almost always a phase boundary.
2. **Narration cues** — "now I'm going to…", "switching to…", "next step…", "okay, let's…".
3. **Long pauses without action** — a 10+ second gap between events with no narration.

Coarse beats granular. The test: *can I describe this phase's postcondition in one sentence?* If yes, the boundary is right. If you have to use "and then…" the boundary is wrong.

Show your draft phasing back to the user as a numbered list and **ask** before writing anything:

> "I see three phases:
> 1. **Capture YouTube URL** (Chrome) — open the video, copy the URL.
> 2. **Append to Watch Later note** (Notes) — switch app, find the right note, paste.
> 3. **Create the calendar reminder** (Calendar) — switch app, new event, set title and date.
>
> Merge / split / rename anything?"

Once the user confirms, write `<flow-dir>/flow.yaml` with the phases array filled in but NO `paths` block yet. See `.agent/clarify-prompt.md` for the exact YAML shape.

End the pass with the line:

> Phases drafted. Run Pass 2 to assemble the GUI paths.

### Pass 2 — Assemble the GUI path

**Inputs:** `flow.yaml` (now has phases), `events.jsonl`, and `steps/` (open as needed).

For each phase: walk its events.jsonl lines, open each `<step_dir>/meta.yaml` for full detail, and write a `gui` path under the phase's `paths:` array.

The GUI path is the recording. **Lightly trimmed of obvious noise**, never reordered or reinterpreted. Strip only:

- A typo + immediate full-text deletion + retype.
- An immediate undo (Cmd+Z) right after a misclick.
- An aborted misclick — a click followed within a fraction of a second by a click on a different element, with no narration justifying both.

Each step gets:

- `step:` — the four-digit folder index (`"0007"`, quoted to keep YAML treating it as a string).
- `text:` — one line in second person, what this step does ("Click Mail in the Dock.").
- `replicate:` — copy verbatim from the step's `meta.yaml`. **Do not reconstruct from coords.**
- `screenshot:` — relative path under the flow dir. Prefer `annotated.jpg`, fall back to `screenshot.jpg` for keystrokes/types/hotkeys, fall back to `region.png` for highlight steps.

After all phases have a `gui` path filled in, end Pass 2 with:

> GUI paths assembled. Run Pass 3 to propose headless alternatives.

### Pass 3 — Propose headless alternatives

**Inputs:** the flow.yaml from Pass 2 + the step folders.

For each phase, propose a small set of paths that complete the **whole phase** with as few commands as possible — typically one. Order: `shell` > `osascript` > `mcp` > `cli`. Cheapest + fewest deps first.

**The unit is the phase, not the step.** A non-GUI path replaces the entire GUI sequence. If a candidate alternative can only handle part of the phase, the phase boundary is wrong — flag it back to the user and propose a re-split. Don't shoehorn a partial path.

**Self-contained.** No mid-path handoffs to the GUI. If runtime falls back, it falls back to the *next whole path* in the list, never into the middle of one.

Format per alternative:

```yaml
- kind: <shell|osascript|mcp|cli>
  description: "<one-line: why this works headless, what trade-off if any>"
  command: |
    <the actual command or script>
```

Show the user your proposed alternatives before writing them:

> "For Phase 3 (create calendar reminder), I see one good headless path: a single `osascript` that creates the event end-to-end. Trade-off: needs Automation permission for Calendar (one-time prompt the first time). Use it as the alternative? Or stick with GUI only?"

If you can't find a plausible headless path for a phase, say so honestly and leave only the GUI path. The agent will fall back to UI replay. Don't invent a fake alternative just to fill the slot.

After all alternatives are written, end Pass 3 with:

> Done — flow.yaml is ready. Render it with `flow42 view <flow-dir>`.

The user can now run:

- `flow42 view <flow-dir>` — human-readable markdown.
- `flow42 view <flow-dir> --path osascript > replay.scpt` — runnable script of just the headless paths.

## Hard rules

- **Read events.jsonl, not flow.json**. flow.json is a legacy tee for the menu timeline; events.jsonl is canonical for v2.
- **Don't open `steps/` in Pass 1.** Boundaries first; detail second. Mixing them muddles phasing.
- **The first path in every phase MUST be `kind: gui`.** Order encodes preference: cheapest runnable wins, but the GUI path is always there as ground truth.
- **Verify every `flow42 …` command in a step's `replicate` field against `flow42-cli`** before assuming it's right. The recorder generates these from the same code that runs the verbs, so they're authoritative — but if you're inventing a command (e.g. for a Pass 3 alternative), sanity-check syntax against the `flow42-cli` skill.
- **No SKILL.md, no `<name>.md`, no human-guide files.** v2 has one source of truth: `flow.yaml`. Markdown views render on demand via `flow42 view`. Don't write the legacy artifacts.
- **Use absolute paths** for every file read or write.
- **Don't substitute parameters during this skill's run.** The recording is faithful — recorded values stay literal in `flow.yaml`. Parameter substitution (turning "team@web42.io" into `${alias}`) is a future Pass 4 / app concern.

## Companion skills

- **`flow-recorder`** — captures recordings. Auto-hands-off to this skill when recording finishes.
- **`flow42-cli`** — reference manual for the underlying CLI. Use it when verifying command syntax for `replicate` fields and for Pass 3 alternative commands.
