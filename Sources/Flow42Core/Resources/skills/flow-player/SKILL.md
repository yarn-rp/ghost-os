---
name: flow-player
description: |
  Execute a previously-recorded, flow42-structured flow on behalf of the
  user, OR guide a user through one step by step. Invoke when the user
  says "run this flow", "play the <name> flow", "execute my dev-server
  login", "walk me through this flow", "use the flow at <path> to do X",
  or hands off after `flow-creator` finishes a dry-run intent. The skill
  owns the canonical play loop (start → current → advance → pause-on-stuck
  → wait → resume → end), the "never read flow.yaml during execution"
  rule, and the user-facing handoff when the agent gets stuck. It does
  NOT cover recording (see `flow-recorder`) or structuring a recording
  (see `flow-creator`).
---

## Goal

Given a flow that already has a `flow.yaml`, **play it end-to-end** by working through phases one at a time, using the cheapest available path per phase, and handing back to the user with a clear reason when stuck. The play is logged to `<flow-dir>/plays/<id>/log.jsonl` so the user can review what happened afterwards.

You're either:

- **Driving** — the default. The agent clicks and types via `flow42 do *`. Orange edge glow + "🤖 \<agent\> is driving" pill on screen.
- **Watching** — the user is performing the steps; you're observing. Cyan edge glow. Useful for guided how-to / training UX, or as the state you flip into when paused.

The play state machine is enforced by the CLI:

- `flow42 do *` is **gated** behind an active driving play. Without one, every action fails with a JSON error pointing at `flow42 play`. The skill teaches you to open the play first; never use `--force`.
- Singleton invariant: only one session (recording OR play) at a time. `flow42 play` while a recording is active fails — `flow42 stop` first.

## When to invoke

Trigger phrases:
- "run this flow"
- "play the \<flow-name\> flow"
- "execute the recorded flow at \<dir\>"
- "let me \<X\> using my recorded flow"
- "walk me through this flow" / "guide me through \<flow-name\>" → start in **watching** mode
- (auto) handed off from `flow-creator` Pass 5 dry-run

If the user wants to record something new, defer to `flow-recorder`. If they want to structure a recording into `flow.yaml`, defer to `flow-creator`. This skill assumes the flow is already structured.

## The canonical loop

This is the entire workflow. The CLI is shaped to make any other pattern awkward; deviating leads to false failures and out-of-sync UI.

```python
flow42_play(flow_dir, by="claude", label=task_description)
# (use --watch instead of by= if the user wants to drive themselves)

while True:
    current = flow42_play_current()                       # phase + paths + params
    if current.done:
        break

    phase = current.phase
    success = try_paths(phase, current.params)            # cheapest first

    if success:
        flow42_play_next()
    else:
        # 2–3 failed attempts on this phase — DO NOT declare failure.
        # Hand off to the user with a concrete description.
        flow42_play_pause(reason=concise_diagnosis_of_what_is_stuck)
        result = flow42_play_wait()                       # blocks until Resume / Stop
        if result.state == "ended":
            break
        # state == "driving" — user resolved it. Loop re-calls play_current
        # and re-attempts the phase from the current state.

flow42_play_end(reason="completed")
```

### Per-phase: trying paths cheapest-first

Every phase carries a `paths:` list. The first is **always** `kind: gui` (the recorded ground truth). Subsequent entries — `shell`, `osascript`, `mcp`, `cli` — are headless alternatives the agent prefers because they cost fewer tokens and have fewer moving parts.

- Try paths in the order they appear (cheapest first).
- For a `gui` path: replay each step's `replicate` command (these are `flow42 do <verb> ...` invocations — the gate passes naturally because you opened a driving play). Insert `flow42 wait` between steps where the recorded action depends on a UI transition.
- For a non-`gui` path: just execute the `command`.
- If a path errors, try the next one. The GUI path is the floor.
- **Verify the postcondition** after the phase if it can be checked cheaply. A path that "succeeded" but didn't move state forward is a path that failed — pause and ask.

### Per-phase failure: pause, don't fail

After 2–3 failed attempts in a phase, **pause the play** with a one-line user-facing reason. Do NOT call `flow42 play end`. The user can see the reason in the floating window and either resolve the blocker (then click Resume) or stop the flow themselves.

Good pause reasons read like a teammate's Slack message:

> `flow42 play pause --reason "Couldn't find the GitHub button. Please click 'Continue with GitHub' so I can pick up after you sign in."`

> `flow42 play pause --reason "The compose window's To: field locator returned nothing — looks like Mail's UI rotated. Please click into the To: field manually so I can continue typing."`

> `flow42 play pause --reason "Stuck waiting for the dev server to come up at http://localhost:3000. Maybe it didn't start? `npm run dev` in the project root and click Resume when it's ready."`

Bad pause reasons read like an exception:

> ❌ "Locator getByPlaceholder('To') failed."
> ❌ "step 0008 returned success=false."
> ❌ "AX query returned no element."

Translate to plain language. The user might be a developer or might not — write for the latter.

## On-screen presence

When you `flow42 play <flow-dir>` (state = driving):

- The screen edges glow **orange**.
- A top-of-screen pill appears: "🤖 \<your name\> is driving — \<label\>" with a Stop button.
- The system cursor gets a soft glow ring + your name badge.
- A floating window appears bottom-right showing the current flow / phase / step + a Pause button.

When you `flow42 play pause` (state flips to watching):

- The edge glow turns **cyan**.
- The pill + cursor companion fade.
- The floating window swaps to show your pause `reason:` prominently with Resume / Stop buttons.

When you `flow42 play resume` (or the user clicks Resume):

- Back to orange. `flow42 play wait` returns. Loop re-runs `flow42 play current`.

The user never has to read JSON to know what's happening. Your job is keeping the on-screen state honest by always going through the CLI's lifecycle verbs.

## Hard rules

- **Open a play before any `flow42 do *` call.** The gate is enforced; calls without a play fail with a JSON error. Never use `--force` to bypass — that's a human-debugging escape hatch the agent doesn't need.
- **`flow42 play current` is the only phase source during a play.** Never read `<flow-dir>/flow.yaml` directly — that's how agents lose track of which phase is active and disagree with the on-screen panel about what's happening.
- **Pause on stuck, don't fail.** After 2–3 path attempts in a phase, pause with a clear human-readable reason. The user's role is to unblock; pausing surfaces the blocker. Calling `flow42 play end --reason agent_stopped` is a last resort, not a default.
- **Verify postconditions when cheap.** After a path "succeeds," if the phase has a `postcondition` you can check via `flow42 state` / `flow42 find` / `flow42 wait`, do it. Pause if the state didn't actually change.
- **Use absolute paths everywhere** for the flow dir.
- **End the play explicitly** with `flow42 play end --reason completed` when done. The CLI doesn't auto-end; leaving a play open leaves the user's screen glowing.
- **Browser activation** — never propose `open -a "Google Chrome"` / `osascript … to activate` as a way to bring Chrome to front. Those activate the user's *personal* Chrome (no CDP, no extension); flow42's browser actions need the dedicated profile started by `flow42 chrome-launch`. If a phase's `precondition` requires Chrome and it isn't running, run `flow42 chrome-launch` (idempotent — brings the existing flow42 Chrome to front, or starts it).

## Companion skills

- **`flow-recorder`** — captures recordings. Defer here when the user wants to record something new.
- **`flow-creator`** — structures a recording into `flow.yaml`. Defer here when handed a recording dir without a flow.yaml.
- **`flow42-cli`** — pure CLI reference. Look up exact verb syntax, flag names, output shapes. This skill (`flow-player`) tells you *what* to call and *when*; the CLI skill tells you *how*.
