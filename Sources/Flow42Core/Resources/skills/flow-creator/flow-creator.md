# Flow-creator — turn a recording into a structured `flow.yaml`

`flow-creator` is the second stage of a two-stage workflow:

1. **`flow-recorder`** captures a recording — minimal interaction, just a one-sentence goal.
2. **`flow-creator` (this skill)** takes that recording and produces a single structured artifact: `flow.yaml`. Markdown views (human or agent-script) are rendered on demand from `flow.yaml` via `flow42 view`.

There is exactly one source of truth. `flow.yaml` is the thing the agent writes, the future Flow app edits, and `flow42 view` renders.

## The three-pass model

The workflow is deliberately phased. Each pass has a sharp input/output contract; mixing them muddles the result.

### Pass 1 — Phase detection

**Inputs:** `events.jsonl` (the lightweight one-line-per-step index) and `audio/narration.txt` if present. **Step folders stay closed.**

A phase is a *mini-flow* with a clear postcondition. Phase boundaries usually fall on app switches, top-level navigations, or narration cues ("now I'm switching to…", "next step is…").

flow-creator drafts the phasing as a numbered list with a one-line intent each, and asks: "merge / split / rename anything?" After you confirm, it writes the phases array into `flow.yaml`. No `paths:` block yet.

The test for a good phase: *can the postcondition be described in one sentence?* If you have to use "and then…" the boundary is wrong.

### Pass 2 — Assemble the GUI path

**Inputs:** the phases-only `flow.yaml` from Pass 1, plus `events.jsonl`, plus the per-step `meta.yaml` files in `steps/`.

For each phase, flow-creator walks its step range and writes a `gui` path under the phase's `paths:` array. The GUI path is **the recording, lightly trimmed**: only obvious noise (typos retyped, immediate undos, aborted misclicks) gets stripped. No reordering, no reinterpretation.

Each step in the GUI path carries:

- the step folder reference (`step: "0007"`)
- a one-line `text:` for human readers
- the `replicate:` command copied verbatim from the step's `meta.yaml` (the deterministic UI-replay primitive)
- a relative `screenshot:` path — `annotated.jpg` for clicks/drags, `screenshot.jpg` for keystrokes/types, `region.png` for highlights.

### Pass 3 — Propose headless alternatives

**Inputs:** the now-Pass-2 `flow.yaml` plus the step folders (for context).

For each phase, flow-creator proposes a small set of cheaper paths that complete the **whole phase** in as few commands as possible — typically one. Order: `shell` > `osascript` > `mcp` > `cli`. Cheapest, fewest deps first.

The unit of swap is the phase, not the step. A non-GUI path replaces the entire GUI sequence inside its phase. If a candidate alternative can only handle part of the phase, the phase boundary is wrong — flow-creator flags it back to you and proposes a re-split.

If no plausible headless alternative exists for a phase, flow-creator leaves only the GUI path. The agent will fall back to UI replay at runtime. Faking an alternative for the sake of completeness is forbidden.

## What flow-creator will NOT do

- **Record.** That's `flow-recorder`. If you don't have a recording yet, flow-creator hands off there.
- **Open `steps/` in Pass 1.** Boundaries first, detail second. Mixing them muddles phasing.
- **Reorder or reinterpret in the GUI path.** The recording is what the user did. Reordering breaks the "lightly trimmed" contract.
- **Substitute parameters.** Recorded values stay literal in `flow.yaml`. Turning "team@web42.io" into `${alias}` is a future concern (Pass 4 / Flow app), not part of this skill.
- **Write `SKILL.md` or `<skill-name>.md` artifacts.** v2 has one source of truth. Markdown is rendered on demand by `flow42 view`.

## Output layout

Inside the flow directory:

```
<flow-dir>/
├── meta.yaml                 # session metadata
├── events.jsonl              # lightweight step index (Pass 1 input)
├── steps/
│   └── NNNN-<action>/
│       ├── meta.yaml         # full per-step detail (Pass 2 input)
│       ├── screenshot.jpg
│       └── annotated.jpg
├── audio/                    # only when narration was recorded
│   └── narration.txt
├── .agent/
│   ├── clarify-prompt.md     # Pass 1 prompt
│   └── generate-prompt.md    # Pass 2 + 3 prompt
└── flow.yaml                 # ← written by flow-creator
```

After Pass 3 completes, `flow.yaml` is ready. From there:

- `flow42 view <flow-dir>` — human-readable markdown.
- `flow42 view <flow-dir> --path osascript > replay.scpt` — runnable script of just the headless paths for one kind.

## Companion skills

- **`flow-recorder`** — first stage; captures recordings. Auto-invokes this skill when finished.
- **`flow42-cli`** — reference manual for the underlying CLI commands (`flow42 record`, `flow42 act`, `flow42 view`, `flow42 structure`, etc.). Use it to verify command syntax for `replicate` fields and Pass 3 alternative commands.
