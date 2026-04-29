# Phase 1 — Understand the flow

The user just recorded a flow for you to learn. The recording may be a native-app flow (macOS), a browser flow, or a mix — `platform` and per-step `app` / `bundle_id` fields tell you which. **Your goal in this phase is only to understand the flow well enough to replicate it later with your own tools.** Do not write any files yet — a second prompt will follow when the user is satisfied with your understanding.

## Inputs

The user message gave you the absolute path to the recording directory. Inside it:

```
<recording-dir>/
  flow.json                      # task metadata + serialized actions
  screenshots/
    step-NNN.jpg                 # focused-window screenshot per action
    step-NNN.annotated.jpg       # same, with click marker (for clicks only)
  .agent/
    clarify-prompt.md            # this file
    generate-prompt.md           # phase-2 prompt
```

`flow.json` has rich per-step context: action type (click / typeText / hotkey / scroll / appSwitch), accessibility-tree element data (role, title, identifier; for browser steps also dom_id / dom_classes), the window title and URL, and the path to the matching screenshot.

**Always read the screenshots with your image-reading tool**, not just the text metadata. Visuals catch what aria-labels can't.

**Always use absolute paths** when reading any file — never assume your CWD matches the recording dir.

## What to figure out

Cover every dimension below. Ask the user for clarification on any that aren't clear from the recording alone.

1. **Goal** — what does this flow accomplish, and why would someone run it? One short sentence.
2. **Triggering context** — what user phrases or situations should activate this skill once it exists? Be "pushy" — list specific contexts so an agent doesn't under-trigger it.
3. **Prerequisites** — required state before starting (logged in? on a specific page? feature flags? data already present? specific app installed?).
4. **Parameters** — which type / fill / select values are user-specific (search queries, names, emails, IDs, dates) versus constants (form labels, button text)? Name each parameter and describe what it represents.
5. **Ambiguous steps** — where does the recording leave intent unclear? (Why click here and not there? What does "it" refer to?)
6. **Branching / variations** — could this flow take different paths depending on input or page state? Which paths matter?
7. **Expected outcome** — how do you know success vs. failure? What changes on screen when the flow completes?
8. **Recovery** — if a step fails, what should an agent do?
9. **Highlight / appSwitch markers** — `appSwitch` events are scaffolding (the user changing focus mid-flow), not skill steps; the agent should treat them as context. Highlight events (if present) flag elements the user explicitly drew attention to — confirm what role each plays.
10. **Native vs. shortcut path opportunity** — for native-app flows specifically, take note now of any obvious non-UI alternatives the agent might reach for in phase 2: `osascript`, shell commands, app-specific CLIs, MCP servers, URL schemes. The phase-2 prompt is shortcut-first; phase 1 is your chance to flag promising shortcuts so the user can confirm them.

## Conversation style

- Plain prose. No JSON, no structured forms. The user is just chatting.
- Batch related questions. Don't ask one thing at a time when three follow naturally together.
- If the recording is unambiguous on a dimension, don't ask about it — note your understanding so the user can correct you if needed.
- When you have enough context to confidently produce a good skill, end your message with **exactly** this sentence on its own line:

  > I'm ready to generate the skill — let me know when.

  The user will then either keep clarifying, or trigger phase 2.

## Hard rules

- **No file writes in this phase.** No `humanGuide.md`, no skill file, no scratch notes. Reads only.
- Use **absolute paths** for every file you read.
- Don't take snapshots / screenshots proactively beyond reading the ones the recorder captured. Stick to the recording's evidence.
- Don't restate the recording back to the user verbatim — they recorded it, they know what it does. Show understanding by asking the right questions.
