---
name: flow-creator
description: |
  Turn a flow42 recording into a structured `flow.yaml`. Workflow: orient
  yourself and ask the user for any missing context (Pass 0), then four
  production passes — detect phases, detect params, strip noise + assemble
  GUI paths, propose cheaper headless alternatives — and finally offer a
  dry-run to verify the flow actually replays. Invoke when handed a
  recording dir
  (auto-handed-off by `flow-recorder` after `flow42 record stop`, or
  manually with phrases like "structure this recording", "make a
  flow.yaml from `<dir>`", "process the recording at `<path>`"). The
  skill expects the canonical layout — events.jsonl + steps/ — to already
  exist. No SKILL.md / human guide files are written: those are rendered
  on demand by `flow42 view` from the single source of truth that is
  flow.yaml.
---

## Post-record auto-invocation

You may be invoked **immediately after** `flow42 record stop` returns. The
main app (Flow42App) wires the menu's Stop button to a chat session that
fires this skill against the freshly-captured recording dir. When that
happens:

- The recording dir is fresh: `events.jsonl` + `steps/` exist; **no
  `flow.yaml` yet** — your job IS to write the first one.
- The user is in chat, ready to answer Pass 0 questions.
- The chat surface lives in Flow42's floating panel (the same one
  "Run autonomously" uses); the user can see your messages there. The
  Flow42App window shows the recording metadata + a status indicator
  while you work.
- Don't try to read a non-existent flow.yaml during orientation — read
  events.jsonl, the latest step's meta.yaml, and any audio/narration.txt
  instead.
- Once you've written flow.yaml, the user's main-app window will
  surface a "Open the structured flow" CTA — you don't need to do
  anything special; just save the file at `<flow-dir>/flow.yaml`.

## Goal

Given a recording directory, produce one file: `<flow-dir>/flow.yaml` — the
structured source of truth. Phases, parameters, GUI path per phase, headless
alternatives where genuinely cheaper. Read by `flow42 view` for human / agent
rendering, and by future tooling for editing and replay.

We do NOT produce SKILL.md or `<skill-name>.md` artifacts. Markdown views are
rendered on demand from `flow.yaml` via `flow42 view`. One source, two
presentations.

## When to invoke

Trigger phrases:
- (auto) "Recording captured at `<path>` — now structure it" — handed off from `flow-recorder`.
- "structure this recording"
- "make a flow.yaml from `<recording-dir>`"
- "process the recording at `<path>`"

If the user wants to record something new, defer to `flow-recorder`.

## Orchestration: lean on Claude Code's strengths

This skill is built to run inside Claude Code. Three native capabilities you should use explicitly:

1. **TodoWrite at the start.** Before reading anything, lay down a visible plan: Pass 0 (orient + clarify) → Pass 1 (phases) → Pass 2 (params) → Pass 3 (strip + assemble) → Pass 4 (alternatives) → final dry-run offer. The user sees progress; you stay oriented.

2. **Subagent fan-out for per-phase work (Task tool, `general-purpose` agent, Sonnet).** Pass 1 is global and sequential — you do it alone. Passes 2, 3, and 4 are *embarrassingly parallel by phase*. After Pass 1 produces N phases, spawn N subagents in **a single message with N parallel tool calls** — never in a loop. Each subagent:
   - Gets a self-contained brief (phase definition + relevant inputs + the schema rules).
   - Returns a strict YAML fragment plus an `escalations:` list of decisions to ask the user.
   - **Never talks to the user.** Never writes to disk.
   - Subagent briefs are templated below in each pass section — paste them verbatim.

   You (the orchestrator) own: user clarifications, cross-phase consolidation (deduping params, resolving naming conflicts), partial writes to `flow.yaml`.

3. **Plain Write for committing partials.** Each pass ends by writing the updated `flow.yaml` with `Write` (full rewrite is fine — the file is small). Keep the on-disk representation in sync with your working state so an interruption mid-pass leaves a coherent partial that can be resumed by re-invoking the skill.

## flow.yaml schema

Top-level fields:

```yaml
name: <slug-style-name>
task_description: "<one-line summary of what this flow accomplishes>"
recorded_at: <ISO 8601 timestamp from meta.yaml>
duration_seconds: <int from meta.yaml>

params:
  - name: <snake_case_name>
    description: "<one line: what does this input represent?>"
    type: string | int | bool | path | url
    example: "<the literal value used in this recording>"

phases:
  - name: <snake_case_name>
    intent: "<one sentence: what does this phase accomplish?>"
    precondition: "<state required before this phase starts>"
    postcondition: "<state guaranteed after this phase finishes>"
    note: |                                # optional, see below
      <up to ~3-4 sentences of phase-level guidance>
    paths:
      - kind: gui                          # ALWAYS first
        description: "<one line: what the user did, in human terms>"
        steps:
          - step: "0001"                   # quoted four-digit step folder index
            text: |                        # one line OR short paragraph
              <human-readable description; may use ${param}>
            replicate: "<flow42 do ... command from step's meta.yaml; may use ${param}>"
            screenshot: steps/0001-click/annotated.jpg

      - kind: shell | osascript | mcp | cli   # alternatives, optional
        description: "<one line: why this works headless>"
        command: |
          <one or two lines that complete the WHOLE phase; may use ${param}>
```

### Notes on each field

- **`params`** is a top-level list of named inputs the flow needs to be re-run with different values. Detected in Pass 2 from typed text, URLs visited, file names chosen. Each param has `name`, `description`, `type`, and `example` (the literal value observed in this recording — *not* a default). References inside phases use `${name}` syntax.

- **`name`** at the phase level (not `id`). Humans read it; references are by name.

- **`intent` / `precondition` / `postcondition`** are free-form prose. They orient agent and human; they don't drive a state matcher. They *can* reference `${param}` so they stay accurate when the flow re-runs with different values.

- **`paths`** is ordered. The first one is *always* the GUI path. Subsequent paths are headless mini-flow swaps. Order encodes preference; no `default:` or `audience:` flag.

- **A `gui` path** is the only kind with `steps`. Each step references the canonical `steps/NNNN-*/` folder, carries:
  - `step:` — the four-digit folder index, **quoted** (`"0007"`) so YAML treats it as a string.
  - `text:` — the step's human-readable description. Usually one line; may grow to a short paragraph when the step has brittleness warnings, alternate-name hints, or autocomplete-handling guidance worth carrying. Uses `${param}` substitution where applicable.
  - `replicate:` — copy verbatim from the step's `meta.yaml`, then substitute `${param}` for any param value embedded in flags (e.g. `--text 'team@web42.io'` → `--text '${alias}'`).
  - `screenshot:` — relative path under the flow dir. Prefer `annotated.jpg`, fall back to `screenshot.jpg` for keystrokes/types/hotkeys, fall back to `region.png` for highlight steps.

- **A non-`gui` path** is a single `command` plus a one-line `description`. It must complete the *entire* phase mini-flow on its own. May use `${param}` substitution.

### `note:` — phase-level guidance, optional

`note:` is an optional free-form field on **phases only** (not on individual steps — step-level guidance lives inside the step's `text:` instead, which can grow from one line to a short paragraph as needed). Up to ~3–4 sentences. Use it sparingly — only when clearly needed — to capture phase-wide context the structured `intent:` / `precondition:` / `postcondition:` can't express.

**Voice: write notes like a tutorial someone left for the next person who has to do this.** Same voice as `text:`. Direct, prescriptive, second-person or imperative.

> *"Make sure Mail opens with the yan@web42.io account active, not the personal one. Sometimes Mail comes up on the wrong account after a restart — switch via the sidebar before moving on."*

NOT *"The user mentioned in narration that…"* and NOT *"It was observed that…"*. The reader (human or future agent) should be able to act on a note without translating it. If you find yourself narrating what the recording showed, drop it.

Good things to capture in a phase-level note:
- Account / state preconditions too coarse for the structured `precondition:`.
- Phase-wide behavior differences across runs ("the sidebar is collapsed by default on first open — expand it before starting").
- Recovery hints if a typical failure mode is known.

Step-level brittleness or behavior differences (rotating class names, autocomplete handling, alternative element names) go inside the **step's `text:` field** — written in the same direct voice. Don't add a separate `note:` to steps.

Empty / missing `note:` is the common case. We'd rather have a phase with no note than a phase with a note that just paraphrases `intent:`.

### What makes a good alternative path

- **Coarse, not granular.** Replaces the whole phase. If a swap can only handle part of the phase, the phase boundary is wrong — fix the phase, not the path.
- **Self-contained.** No mid-path handoffs to the GUI.
- **Cheapest first.** A 2-line shell command beats a 5-line osascript beats a multi-call MCP sequence beats GUI replay.
- **Genuinely cheaper or skip.** If an alternative is the same length and complexity as the GUI sequence, *don't add it*. Empty alternatives lists are fine — many phases just don't have a cheap headless equivalent and the GUI path is the right answer.

### Common alternative-path mistakes — read this before Pass 4

A few headless commands look obvious but break the replay invariants. Don't propose them. The replacement is always either the right flow42 verb or no alternative at all (keep the GUI path).

- **Chrome activation.** ❌ `open -a "Google Chrome"`, `open -b com.google.Chrome`, `osascript -e 'tell app "Google Chrome" to activate'`. These bring the user's *personal* Chrome to front (whichever instance the OS considers default), not the dedicated flow42 profile that `flow42 do --target browser` attaches to via CDP. The user's personal Chrome has no debug endpoint and no flow42 extension — every downstream browser action will fail. ✅ Use `flow42 chrome-launch` instead. It's idempotent: if the dedicated Chrome is already running on the right profile, Chrome itself dedupes and the call just brings the existing window to front. If it's not running, it starts it with `--remote-debugging-port=9222`, the right `--user-data-dir`, and the extension auto-loaded.

- **Chrome navigation to a known URL.** ❌ `open -a "Google Chrome" https://example.com`. Same problem — opens the wrong Chrome. ✅ `flow42 do navigate --url https://example.com` (already wired through the flow42-attached Chrome).

- **App activation in general.** Native app activation via `open -a "<App>"` is fine for non-browser apps (Mail, Calendar, Notes, etc.) — there's only one of each, no profile ambiguity. The Chrome rule is specific to Chrome.

- **Anything that requires the flow42 extension's DOM sidecar** (Playwright-style locators, DOM IDs, etc.). The extension only loads in the dedicated profile. If the alternative would lose locator-based addressing, keep the GUI path.

When in doubt for a Chrome-touching phase, **leave the alternatives empty**. The GUI path is reliable; a wrong "alternative" is worse than no alternative because the agent will pick it first by virtue of being cheaper.

## Workflow — Pass 0 + four passes

The workflow is deliberately phased. Each pass has a sharp input/output contract; mixing them muddles the result. Commit a partial `flow.yaml` to disk after each pass.

Before any of the four production passes, run **Pass 0 — Orient and clarify**. Skipping it is the most common reason a recording ends up structured wrong: the agent guesses the recording's intent from clicks alone, builds plausible-looking phases, and only later realises half of what it captured was incidental.

### Pass 0 — Orient and clarify (orchestrator only, sequential)

**Inputs:** `<flow-dir>/meta.yaml` (especially `task_description`, `apps`, `urls`), `<flow-dir>/events.jsonl` (skim — count by `app`, look at the first/last few lines and any narration entries), `<flow-dir>/audio/narration.txt` (read in full if it exists; it's usually short).

**Pass 0 is comprehension only.** You are confirming you understood what the user was trying to do. You are NOT deciding what to strip, what's noise, or which steps to drop — that's Pass 3's job. You are NOT drafting phases — that's Pass 1. The single output of this pass is *certainty about the flow's intent*.

If after skimming you can confidently describe the goal in one sentence and nothing about the captured activity confuses you, **say so and move on**. No questions are needed. The bar for asking is "I genuinely don't understand what's going on" — not "I want to confirm every detail."

When you DO have something confusing, ask only about that. Good question shapes:

- **Goal paraphrase, when `task_description` is empty / vague / doesn't match the events.** *"I see Mail, then Chrome, then Calendar. My read: you were sending an email then scheduling a follow-up. Is that the goal, or is one of these incidental?"*
- **Multi-app sessions where the role of one app is unclear.** *"What's the role of Cursor here? Was the code you wrote part of the task, or were you just checking something while the dev server started?"*
- **Implicit goals that aren't obvious from clicks alone.** *"The recording ends right after you click 'Continue with GitHub'. Was the goal to land logged in, or to start the OAuth flow and stop there?"*
- **Anything genuinely ambiguous.** A long pause with no narration, an app you don't recognise, a URL pattern you can't interpret — ask.

**Do NOT ask about:**
- Whether to drop misclicks, undo+retypes, or abandoned attempts. *(Pass 3.)*
- Whether typed values should be parameters. *(Pass 2.)*
- Whether to merge / split phases. *(Pass 1.)*
- Whether headless alternatives should be added. *(Pass 4.)*

**Batch the questions.** If you have any, send them all in a single message, numbered, so the user answers in one go. If you don't have any, skip the round trip and move directly to Pass 1.

After the user responds (or if you skipped because everything was clear), write a short scratch summary into a TodoWrite item ("Orientation: dev-server start + Chrome login. Cursor is incidental.") so the rest of the workflow stays anchored to the same understanding.

End the pass with:

> Got it. Drafting phases now (Pass 1).

### Pass 1 — Phase detection (orchestrator only, sequential)

Phasing is global by nature — boundaries depend on the whole timeline — so do this pass alone. No subagents.

**Inputs:** `<flow-dir>/events.jsonl`, `<flow-dir>/audio/narration.txt` (if present), `<flow-dir>/meta.yaml`. **Do NOT open `steps/`** — phases first, detail later.

`events.jsonl` is one line per step, lightweight: `idx`, `step_dir`, `action_type`, `app`, `summary`, optional `target` and `url`, `timestamp_ms`, `source`. That's the entire vocabulary you need at this pass.

A phase is a mini-flow with a clear postcondition. Three signals tend to mark a boundary:

1. **App / URL transitions** — a line followed by lines with a different `app` is almost always a phase boundary.
2. **Narration cues** — "now I'm going to…", "switching to…", "next step…", "okay, let's…".
3. **Long pauses without action** — a 10+ second gap between events with no narration.

Coarse beats granular. The test: *can I describe this phase's postcondition in one sentence?* If yes, the boundary is right. If you have to say "and then…" the boundary is wrong.

Show your draft phasing back to the user as a numbered list and **ask** in plain chat before writing anything:

> "I see three phases:
> 1. **Capture YouTube URL** (Chrome) — open the video, copy the URL.
> 2. **Append to Watch Later note** (Notes) — switch app, find the right note, paste.
> 3. **Create the calendar reminder** (Calendar) — switch app, new event, set title and date.
>
> Merge / split / rename anything?"

Once the user confirms, write `<flow-dir>/flow.yaml` with `name`, `task_description`, `recorded_at`, `duration_seconds`, and the `phases:` array filled in with `name`/`intent`/`precondition`/`postcondition` — but **no `paths:` blocks and no `params:` block yet**.

If the narration for a phase contains something a future re-runner needs to know that doesn't fit the structured fields, capture it as a phase-level `note:` here — written as direct guidance ("Make sure …", "Watch out for …"), not as a transcript of what the user said. Empty / missing `note:` is the common case.

End the pass with:

> Phases drafted. Running Pass 2 in parallel (one subagent per phase) to detect parameters.

### Pass 2 — Param detection (parallel by phase, then consolidate)

**Inputs:** the partial `flow.yaml` from Pass 1, plus the step folders' `meta.yaml`.

**Fan-out:** spawn one subagent per phase **in a single message with N parallel Task tool calls**. Subagent brief template (paste into each Task call's prompt, swapping in the phase-specific data):

> You are analysing one phase of a flow42 recording for parameter detection. Do not ask the user anything; do not write to disk; return only YAML.
>
> **Phase:** `<phase_name>` — `<intent>`
> **Step range:** `<idx_start>`–`<idx_end>` in `<flow-dir>/steps/`
> **Events.jsonl lines for this phase:**
> ```jsonl
> <paste the lines>
> ```
>
> Walk each step's `<flow-dir>/steps/NNNN-*/meta.yaml`. Look for **inputs** — values the user *chose* rather than *navigated to*:
> - Typed text in `typeText` / `keyPress` events.
> - Specific URLs in browser navigation events.
> - File names selected in dialogs.
> - Custom values entered into form fields.
>
> For each candidate, classify:
> - **Param:** future re-runs would obviously want to vary this (recipient address, subject, file name, query string).
> - **Literal:** structural constant of the task (Dock icon target, known menu item, hotkey).
> - **Ambiguous:** could be either — escalate.
>
> Return:
> ```yaml
> params:
>   - name: <snake_case proposal>
>     description: "<one line>"
>     type: string | int | bool | path | url
>     example: "<observed value>"
>     seen_at: ["0007", "0010"]            # step indices where the value appears
>
> escalations:
>   - "<one-line question for the user>"
> ```
>
> Be conservative — when in doubt, escalate.

**Consolidate (orchestrator):**
1. Merge subagent results into a single `params:` list. **Dedup across phases** — if `team@web42.io` shows up in phases 2 and 3, it becomes one `alias` param referenced from both, not two separate params.
2. Resolve naming conflicts (two phases independently propose `email` → pick the better fit or ask the user).
3. Batch all subagent escalations into a single user-facing chat message:

   > "A few values I want to confirm as parameters:
   > 1. `team@web42.io` — is this a parameter (varies per run) or a fixed alias for this flow?
   > 2. `Daily status — May 1` — parameter, or a fixed format?"

4. Apply the user's answers, commit the `params:` block to `flow.yaml`, and **rewrite the existing `intent:` / `precondition:` / `postcondition:` prose** in each phase to use `${name}` references where applicable.

End-of-pass: `flow.yaml` has `params:` populated and phase prose rewritten with `${param}` references. Still no `paths:` blocks.

> Params confirmed. Running Pass 3 in parallel to strip noise and assemble GUI paths.

### Pass 3 — Strip noise + assemble GUI path (parallel by phase)

**Inputs:** the partial `flow.yaml` from Pass 2 (with `params:`), `events.jsonl`, and `steps/`.

These two operations live in one pass because they're tightly coupled — you can't translate a step into a `gui` entry while also deciding whether to include it without doing both at once.

**Fan-out:** spawn one subagent per phase in a single parallel batch. Subagent brief template:

> You are assembling the GUI path for one phase of a flow42 recording. Do not ask the user anything; do not write to disk; return only YAML.
>
> **Phase:** `<phase_name>` — `<intent>`
> **Step range:** `<idx_start>`–`<idx_end>`
> **Params (with their observed values):**
> ```yaml
> <paste the params: block; subagent uses ${name} substitution where it sees these values>
> ```
>
> For each step in the range, open `<flow-dir>/steps/NNNN-*/meta.yaml`. Apply the **strip rules** below:
> - Typo + immediate full-text deletion + retype → drop the typo + delete steps, keep only the final retype.
> - Immediate undo (Cmd+Z) right after a misclick → drop both the misclick and the undo.
> - Aborted misclick — a click followed within ~500 ms by a click on a different element, no narration justifying both → drop the first click.
> - **Don't strip aggressively.** When in doubt, keep the step. Marginal cases go in `escalations:`.
>
> For each surviving step, emit:
> - `step:` — four-digit folder index, **quoted**.
> - `text:` — one line in second person, with `${param}` substitution where the recorded value was a param. **Expand to a short paragraph** (2–4 sentences) when the step has narration callouts, AX subtree quirks, autocomplete-handling guidance, rotating class names, or alternate element names worth carrying. Use direct, prescriptive voice ("Type the raw address — don't rely on contact autocomplete.") not transcript voice ("The user typed…"). **Don't add a separate `note:` field on steps — `text:` is where step-level guidance lives.**
> - `replicate:` — copy verbatim from the step's `meta.yaml` `replicate` field, then substitute `${param}` for any param values embedded in flags.
> - `screenshot:` — relative path. Prefer `annotated.jpg`, fall back to `screenshot.jpg`, fall back to `region.png`.
>
> Return:
> ```yaml
> phase: <phase_name>
> path:
>   kind: gui
>   description: "<one-line summary of the phase's GUI sequence>"
>   steps:
>     - step: "<idx>"
>       text: |
>         <one line or short paragraph>
>       replicate: "<flow42 do ... command>"
>       screenshot: <relative-path>
>
> escalations:
>   - "Step 0011 looks like a misclick on the wrong field, then 0012 was the right one. Drop 0011?"
> ```

**Consolidate (orchestrator):**
1. Merge each subagent's `path` into the right phase under `paths: [<gui-path>]`.
2. Batch all strip-decision escalations into a single user-facing chat message; apply the answers.
3. Verify each step's `replicate:` looks well-formed against the `flow42-cli` skill — if a subagent produced something off-spec, fix it (the `replicate` field in step `meta.yaml` is authoritative, so subagent output should match).
4. Commit `flow.yaml`.

End-of-pass: every phase has `paths: [{ kind: gui, ... }]`. No alternatives yet.

> GUI paths assembled. Running Pass 4 in parallel to find headless alternatives.

### Pass 4 — Propose headless alternatives (parallel by phase, only when genuinely cheaper)

**Inputs:** the `flow.yaml` from Pass 3 + step folders.

**Fan-out:** spawn one subagent per phase in a single parallel batch. Subagent brief template:

> You are proposing headless alternatives for one phase of a flow42 recording. Do not ask the user anything; do not write to disk; return only YAML.
>
> **Phase:** `<phase_name>`
> **Intent:** `<intent>`
> **Postcondition:** `<postcondition>`
> **Existing GUI path (for reference — N steps):**
> ```yaml
> <paste the GUI path>
> ```
> **Params:**
> ```yaml
> <paste the params: block>
> ```
>
> Propose at most one or two headless alternatives that satisfy the postcondition end-to-end. Order: `shell` > `osascript` > `mcp` > `cli`.
>
> **Skip the phase entirely if no candidate is genuinely cheaper than the GUI sequence.** If the alternative is the same length and complexity as the GUI sequence, don't add it. Empty alternatives are fine — `paths: []`.
>
> **The unit is the phase, not the step.** A non-GUI path replaces the entire GUI sequence. If a candidate alternative can only handle part of the phase, the phase boundary is wrong — flag it in `escalations:` rather than shoehorning a partial path.
>
> **Self-contained.** No mid-path handoffs to the GUI.
>
> Use `${param}` substitution where the GUI path used it.
>
> Verify any `flow42 ...` command syntax against the `flow42-cli` skill before emitting it.
>
> **Browser activation gotcha:** if this phase opens / focuses Chrome, do NOT propose `open -a "Google Chrome"`, `open -b com.google.Chrome`, or `osascript -e 'tell app "Google Chrome" to activate'`. Those activate the user's personal Chrome, which has no CDP endpoint and no flow42 extension — every downstream browser action fails. Use `flow42 chrome-launch` (idempotent — brings the existing flow42 Chrome to front, or launches it with the right `--user-data-dir` + extension if missing). Same rule for Chrome navigation: use `flow42 do navigate --url <URL>` not `open -a "Google Chrome" <URL>`. For non-browser apps (Mail, Calendar, Notes, etc.), `open -a "<App>"` is fine — the Chrome rule is Chrome-specific. When in doubt for a Chrome-touching phase, **return an empty alternatives list** — the GUI path is reliable; a wrong alternative is worse than none.
>
> Return:
> ```yaml
> phase: <phase_name>
> alternatives:                            # may be empty
>   - kind: shell | osascript | mcp | cli
>     description: "<one-line why this works headless>"
>     command: |
>       <one or two lines that complete the WHOLE phase>
>
> escalations:
>   - "Phase 3's osascript needs Calendar Automation permission (one-time prompt). Note this trade-off?"
> ```

**Consolidate (orchestrator):**
1. Append each subagent's alternatives to the corresponding phase's `paths:`, after the existing `gui` entry. Phases with empty alternatives stay GUI-only.
2. Batch all trade-off escalations into a single user-facing summary:

   > "Two trade-offs to confirm:
   > 1. Phase 3's `osascript` alternative needs Calendar Automation permission (one-time prompt). Use it?
   > 2. Phase 5's `shell` alternative only works if Spotlight indexing is enabled — keep GUI as the floor either way."

3. Apply the user's answers and commit `flow.yaml`.

End of Pass 4: every phase has at least the GUI path, plus headless alternatives where genuinely cheaper. Move to Pass 5 — **don't declare done yet**.

> Headless alternatives done. Offering a dry-run to verify the flow actually replays.

### Pass 5 — Dry-run verification (orchestrator + user; opt-in)

A flow.yaml that *looks* right and a flow.yaml that *replays* are two different things. Steps with stale coordinates, Chrome tab IDs that don't exist, locators that no longer match, missing accessibility permissions, or shifted UI all surface only when something tries to execute. Pass 5 catches that before the user trusts the flow.

**Ask the user first.** Dry-running clicks the screen and types into apps, so it requires explicit consent and the user's hands off the keyboard:

> "flow.yaml is written. Want me to dry-run it to verify it actually replays? I'll execute each phase end-to-end (preferring the cheapest path per phase, falling back to GUI replay if the headless alternative fails). You'll need to keep your hands off the keyboard for ~Ns."

If the user declines, end the workflow with the "Done — render with flow42 view" message.

If the user accepts, **invoke the `flow-player` skill** with the flow dir. That skill owns the canonical play loop (start → current → next → pause-on-stuck → wait → resume → end), the per-phase path-fallback rules, the on-screen presence, and the user-facing handoff. It will run the dry-run and report the result. Don't carry the loop's logic here — flow-player is the single source of truth for execution.

When flow-player returns:

- **If completed:** report success and end the workflow.

  > "Dry-run passed end-to-end. flow.yaml is verified. Full trace at `<flow-dir>/plays/<play-id>/log.jsonl`."

- **If the user stopped mid-flow** (clicked Stop in the floating window): the user has feedback to give about what broke. Ask what they'd like fixed in `flow.yaml` — a phase boundary, a wrong locator, a missing param. If the fix is local (a step's `replicate`, a phase's `intent`), patch `flow.yaml` directly. If it's a structural issue (a whole phase needs rerecording), suggest re-recording that phase.

- **If the play crashed** (process died): show the user the path to `<flow-dir>/plays/<play-id>/log.jsonl` and offer to look at the last few events with them.

End the workflow with:

> Done — flow.yaml is ready and verified. Render it with `flow42 view <flow-dir>`.

The user can now run:

- `flow42 view <flow-dir>` — human-readable markdown.
- `flow42 view <flow-dir> --path osascript > replay.scpt` — runnable script of just the headless paths.

## Hard rules

- **Read events.jsonl** — that's the canonical step index.
- **Don't open `steps/` in Pass 1.** Boundaries first; detail second.
- **The first path in every phase MUST be `kind: gui`.** Order encodes preference: cheapest runnable wins, but the GUI path is always there as ground truth.
- **During Pass 5 (a play), never read `flow.yaml` directly.** `flow42 play current` is the only phase source. This guarantees the agent and the on-screen panel agree on which phase is active. Reading flow.yaml ahead of `play next` is also how agents accidentally over-plan and lose track of the current state.
- **On persistent failure within a phase, pause the play with a clear reason — do not declare the flow failed.** The user's role is to unblock; pausing surfaces the blocker in the floating window so they can fix it and click Resume. Calling `flow42 play end --reason agent_stopped` is a last resort, not a default.
- **`params:` is mandatory output** when the recording has any user-typed inputs. Don't ship a `flow.yaml` whose phases reference literal `team@web42.io` instead of `${alias}` — that's a transcript, not a flow.
- **Verify every `flow42 …` command** against the `flow42-cli` skill. Step `replicate` fields are authoritative (recorder-generated); Pass 4 alternatives need extra care since you're authoring those.
- **No SKILL.md, no `<name>.md`, no human-guide files.** One source of truth: `flow.yaml`. Markdown views render on demand via `flow42 view`.
- **Use absolute paths** for every file read or write.
- **Commit partials.** Write `flow.yaml` after each pass. A crash mid-process should leave a useful partial that the user can resume from by re-invoking the skill.
- **Subagents never talk to the user; subagents never write to disk.** They return YAML fragments + escalations. The orchestrator owns user chat and `Write` tool calls.
- **Spawn subagents in a single parallel batch per pass**, not in a loop. One message with N Task tool calls.

## Companion skills

- **`flow-recorder`** — captures recordings. Auto-hands-off to this skill when recording finishes.
- **`flow42-cli`** — reference manual for the underlying CLI. Use it when verifying command syntax for `replicate` fields and for Pass 4 alternative commands.
