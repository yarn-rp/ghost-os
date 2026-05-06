# Flow-recorder — capture a task in real time

`flow-recorder` is the front of a two-stage workflow:

1. **flow-recorder** (this skill) — get the recording captured, no questions beyond a one-sentence goal.
2. **flow-creator** (next skill, auto-invoked) — analyze the recording and turn it into docs (`SKILL.md` + a human-readable companion).

The split exists because the right time to ask "what are the parameters?" or "what are the prerequisites?" is *after* the recording — once the agent can see what you actually copied, typed, switched between, and narrated. Asking upfront produces guesses; asking after produces evidence-backed proposals.

## What you do

1. Tell the agent you want to record. Phrases like "let's record", "I'll show you a flow", "watch me do this" trigger this skill. Mention what the task is in your trigger message if you want it labelled (e.g. *"let's record me saving a video to Notes"*) — the agent picks that up silently. If you don't, no big deal; flow-creator infers everything from the recording.
2. The agent runs `flow42 record start` immediately. **No questions.** The recorder runs as a backgrounded daemon; the start command returns immediately with the recording dir + the daemon's PID.
3. Perform the task **and narrate as you go**. Your voice is transcribed and interleaved with the click/keyboard/scroll/DOM events at stop time.
4. When you finish, just tell the agent. It runs `flow42 record stop`, which signals the daemon to finalise (write flow.json, transcribe narration, merge sources). Stop blocks until that's complete.
5. The agent automatically transitions into `flow-creator` and walks you through documenting what you just did.

## What the recorder captures

- Native mouse, keyboard, scroll events via macOS CGEventTap.
- Window screenshots before each click + keystroke.
- Your narration, transcribed via whisper at the end and interleaved by timestamp.
- Browser-side DOM events from the Chrome extension when Chrome is the focused app — clicks/types/keys with the actual DOM locator (`getByRole(...)`, `locator('css')`, etc.).
- A per-event `replicate` field — the exact `flow42 act ...` command that reproduces the action.

All of this lands in `~/.flow42/flows/recording-<timestamp>/`.

## What the recorder will NOT ask you

- "What are the parameters?" — flow-creator infers them from the recording.
- "What are the prerequisites?" — same.
- "What apps will be involved?" — captured automatically.
- "What are the steps?" — those ARE the recording.

If a skill is asking you these questions before you record, something's wrong — that's the older single-skill design. flow-recorder asks one question and gets out of the way.

## Tips for a clean recording

- **Narrate.** Even half-sentences help. "I'm copying this URL because I want to save it." flow-creator uses narration as the primary intent signal.
- **Don't fix typos by clicking around.** The accidental-event filter usually catches them, but a clean recording produces a cleaner skill.
- **Stay focused on the task.** If you switch apps to check email mid-flow, that gets recorded too. flow-creator will offer to strip it but better not to introduce noise.
- **Type `done`, don't Ctrl-C.** The recorder needs to flush narration transcription before exiting cleanly.

## When NOT to use this skill

- If you already have a recording and just want docs from it: invoke `flow-creator` directly on the recording dir.
- If you want to *execute* a previously-built skill: invoke that skill (or use the CLI commands directly via `flow42-cli`).
- If you want to test a single primitive: use `flow42-cli` and call `flow42 act ...` directly.

## Companion skills

- **`flow-creator`** — the second stage. Reads the recording, strips accidents, detects phases, proposes parameters/prerequisites informed by what was captured, and assembles the documentation. Auto-invoked when this skill finishes.
- **`flow42-cli`** — the reference manual for the underlying commands (`flow42 record`, `flow42 act`, `flow42 tree`, etc.). Both flow-recorder and flow-creator build on these.
