# Phase 2 — Generate the artifacts

> **If you have access to the `flow-creator` skill, use that workflow instead — it supersedes this prompt.** This file is the no-skill-runtime fallback that gets seeded into every recording's `.agent/` directory.

You've finished phase 1 and the user is satisfied with your understanding. Now write **two files** under the recording directory using your file-write tool:

1. `<recording-dir>/SKILL.md` — agent file (capital letters, matches the agent skills convention).
2. `<recording-dir>/<skill-name>.md` — human file, where `<skill-name>` is the kebab-case `name:` from the SKILL.md frontmatter. Sits alongside SKILL.md.

Where `<recording-dir>` is the **absolute path** the user pointed you at in phase 1.

`SKILL.md` is consumed by **any agent** that has access to flow42 / Ghost OS-style execution (MCP tools, shell commands, AppleScript, etc.). Don't tailor the file to a specific platform's CLI syntax. Describe each step in tool-agnostic terms; the consuming agent picks the actual mechanism at run time.

## Hard rules

- **Always write to absolute paths.** `/Users/.../recipes/<slug>/SKILL.md`, not `SKILL.md`. Do not rely on your CWD. This rule is for the file-write tool's destination path only.
- **Image `src` attributes stay relative.** Embed screenshots inline in BOTH files using paths relative to the file's own location: `![Step 3](screenshots/step-003.annotated.jpg)`. Never bake an absolute `/Users/...` path into a markdown image — the directory must stay portable when moved or shared.
- After both files exist on disk, end your last message with **exactly** this line on its own:

  > Done — SKILL.md and `<skill-name>.md` are ready.

  The host watches for this so it can flip into the artifact view.

## `<skill-name>.md` — for humans

Friendly tutorial in Notion style:

- `# Title` — short, action-oriented.
- `> Goal summary` as a blockquote, one sentence.
- `## Prerequisites` — bullet list (the prerequisites you established in phase 1).
- `## Steps` — numbered, each with:
  - `### Step N: <short verb-led title>`
  - one or two sentences in second person ("Click the Jobs tab", "You should see the dashboard load")
  - `![Step N](screenshots/step-NNN.annotated.jpg)` immediately after the description (use the annotated variant when present, fall back to `step-NNN.jpg`)
  - optional `> **Note:** …` / `> **Tip:** …` blockquotes for callouts
- `## Expected outcome` — what success looks like.

Keep it tight: skip steps that are pure chrome (waiting for animations, focus changes between apps) unless they matter.

## `SKILL.md` — for any agent

A platform-agnostic, replay-oriented skill in Markdown. **Hard preference for shortcuts over UI replay.**

### Shortcut-first ordering

For every step in the recording, your job in writing the skill is to find the simplest reliable execution path. Prefer in this order:

1. **Native CLI / shell** — `cal`, `defaults`, `open -a`, `pmset`, `networksetup`, `gh`, `brew`, app-specific CLIs.
2. **AppleScript / JXA** via `osascript -e '...'` (native-app flows almost always have an osascript path — try this before resorting to UI).
3. **App-specific MCP server** if one is registered (Calendar MCP, Notion MCP, Reminders MCP, etc.).
4. **URL schemes** — `x-apple-calevent://`, `mailto:`, `notes://`, `obsidian://`, etc.
5. **Browser CLI / DOM** for browser flows — describe the navigation + selectors; the consuming agent picks its own browser tool.
6. **UI automation as last resort** — `cliclick` + Accessibility, MCP click-by-coordinates, etc. Only use if 1-5 are demonstrably impossible, and explain why in a Recovery section.

When you do reach the UI-automation tier, **do not reconstruct the command from scratch**. Every action in `flow.json` carries a deterministic `replicate` field whose value is the exact `flow42 act …` invocation that reproduces that step. Use it verbatim. Example: a recorded native click serialises a `replicate` like `flow42 act click --x 1327 --y 1167 --button left --count 1 --app 'Google Chrome'`; a recorded browser click serialises `flow42 act click --target browser --locator "..." --button left --count 1 --tab N`. Drop those into the skill's tool-call code block — they are the canonical UI-replay primitive and they sidestep an entire class of "I tried to mimic the recording and got the coords wrong" failures.

**This ordering is authoritative.** Do not rerank because an MCP server is "easier to call" — AppleScript wins over MCP on native macOS apps because it's universally available, requires no server registration, and survives across user environments. List your chosen path as the primary tool call; the next-best option goes in `## Recovery`. If multiple are viable, pick the one highest in the list and **only that one** for the primary call.

### Parameterization rule

Every value the user could plausibly want to change at run time must be a `${parameter}` placeholder, never a hardcoded literal — this includes dates, times, titles, names, IDs, durations, and recipients. In code blocks, use shell-variable interpolation (`"${title}"`, `"${start_date}"`) rather than baking the recording's example values into the script. The recording's literal values (e.g. "Daily Standup", `2026-04-30`, `15:00`) belong in the `## Parameters` section as `example:` annotations, not in the executable block. An AppleScript that reads `set year of startDate to 2026` is a bug; it should compute from `${start_date}` passed via the shell.

The recording's screenshots and AX-tree element data are **ground truth for what the user wanted** — not a script for the agent to mimic. A successful generated skill replicates the **outcome** of the recording, often via a path the user didn't take.

### Frontmatter

```
---
name: <kebab-case-name>          # e.g. mac-calendar-create-event, web42-edit-profile
description: |
  <one paragraph that says what the skill does AND when to invoke it.
   Be pushy — list specific phrases / contexts that should trigger the
   skill so the agent doesn't under-fire.>
---
```

No `allowed-tools` or other fields.

### Body structure

- `## Goal` — one sentence.
- `## Prerequisites` — bullet list, same as the human guide.
- `## Parameters` — list each parameter as `- ${param_name}: description (example: "...")`.
- `## Steps` — numbered. Each step:
  - `### Step N: <action verb led title>`
  - `**Action:**` line stating intent in plain prose, with `${param_name}` for dynamic values.
  - `**Tool call:**` showing the recommended command / script / MCP call (whatever shortcut path you picked from the priority list above). Use a fenced code block.
  - `**Why this path:**` one sentence explaining why this beats UI replay (e.g. "AppleScript creates the event without UI rendering, works headless"). Skip when the only path is UI replay — but in that case justify in Recovery.
  - `![Step N](screenshots/step-NNN.annotated.jpg)` so an agent re-reading this skill can visually confirm the desired end-state before / after acting.
- `## Verify` — only the **final** outcome check, not per-step verifies.
- `## Recovery` — what to do if the chosen path fails. If you chose a shortcut, the recovery is usually "fall back to the recorded UI sequence in this list…". If you chose UI from the start, justify why no shortcut existed.

### Length

Keep `SKILL.md` under 500 lines.

## When you're done

Write both files via absolute paths, then send the single closing line:

> Done — humanGuide.md and skill.md are ready.
