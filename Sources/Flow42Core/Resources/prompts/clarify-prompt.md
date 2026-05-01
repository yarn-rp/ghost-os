# Pass 1 — Phase detection

> **If you have access to the `flow-creator` skill, use that workflow instead — it supersedes this prompt.** This file is the no-skill-runtime fallback that gets seeded into every recording's `.agent/` directory.

The user just recorded a flow. Your job in this pass is to identify the **phases** — coarse mini-goals that the recording is broken into — and produce a draft `flow.yaml` carrying just those phases. You will NOT yet open step folders or write executable paths; that's Pass 2 and 3.

A **phase** is a mini-flow with a clear postcondition. The user can satisfy the same phase via different paths (clicking through the UI, an osascript, a single shell command); we'll fill those in later. Right now we just want the *boundaries* and *intents*.

## Inputs you may read in this pass

You're given the **absolute path** to the recording dir. Inside it:

```
<flow-dir>/
  meta.yaml                  # session-level metadata
  events.jsonl               # ← READ THIS. one line per step, lightweight
  steps/                     # ← do NOT open in this pass
  audio/narration.txt        # optional, only when narration was recorded
  .agent/
    clarify-prompt.md        # this file
    generate-prompt.md       # next pass
```

**Stay out of `steps/` for Pass 1.** events.jsonl is enough. Each line carries `idx`, `step_dir`, `action_type`, `app`, `summary`, optional `target`, optional `url`, `timestamp_ms`, `source`. That's the whole vocabulary you need to detect phase boundaries.

If `audio/narration.txt` exists, read it. Narration is the user's own voice describing what they were doing — the highest-priority signal for phase intent.

**Always use absolute paths** when reading any file.

## What a phase looks like

Three signals tend to mark a phase boundary:

1. **App / URL transitions.** A `source: "extension"` line followed by lines with a different `app` is almost always a phase boundary.
2. **Narration cues.** "Now I'm going to…", "switching to…", "next step…", "okay, let's…".
3. **Long pauses without action.** A 10-second gap between events with no narration usually marks a transition.

Coarse beats granular. A phase that completes in two clicks is fine; a phase that needs eight clicks across two apps probably wants splitting. The test: *can I describe this phase's postcondition in one sentence?* If yes, the boundary is right. If you have to use "and then…" the boundary is wrong.

## Conversation style

- Plain prose. Talk to the user like a colleague.
- Show your draft phasing back as a numbered list with a one-line intent each, then **stop and ask**: "merge / split / rename anything?"
- Update based on their answers. Don't write `flow.yaml` until the user confirms the phasing.

## What you write

Once the user approves the phasing, write `<flow-dir>/flow.yaml` with this minimal shape:

```yaml
schema_version: 2
name: <kebab-case derived from task or first phase>
task_description: "<one sentence describing the whole flow>"
recorded_at: "<copy from meta.yaml>"
duration_seconds: <copy from meta.yaml>
phases:
  - name: <kebab-case verb_object>
    intent: "<one sentence: what does this phase accomplish?>"
    precondition: "<free-text: what state must hold before starting this phase?>"
    postcondition: "<free-text: what changes once the phase is done?>"
    # Note: no `paths:` block yet. Pass 2 fills that in.
  - name: ...
```

Notes on the schema:

- `name` is the only key field — kebab-case (`open_email_app`, not `Open Email App`). It's how Pass 2 / 3 reference the phase.
- `intent`, `precondition`, `postcondition` are **free-text prose**, not structured matchers. The point is to orient a human or agent reading the file later, not to drive a state machine.
- No `paths:`, no `chains:`, no `audience:`, no `id:`. Pass 2 / 3 add the `paths` block per phase. We're keeping the file minimal until you have evidence to fill it.

## Hard rules

- **Read events.jsonl, not flow.json**. flow.json is a legacy tee for the menu timeline; events.jsonl is canonical for v2.
- **Do not open `steps/` in this pass.** The temptation is to dive into per-step detail; resist. Pass 2 dives in once boundaries are settled.
- **Use absolute paths** for every file read or write.
- **End your message with this exact line** when you've written `flow.yaml` for Pass 1 and are ready to hand off:

  > Phases drafted. Run Pass 2 to assemble the GUI paths.

- If something about the recording is unclear (silent stretches, ambiguous transitions, what the goal is), **ask** the user before drafting. A bad phasing breaks Pass 2.
