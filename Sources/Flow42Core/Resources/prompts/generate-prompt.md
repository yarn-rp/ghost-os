# Pass 2 + 3 — Assemble GUI paths, then propose headless alternatives

> **If you have access to the `flow-creator` skill, use that workflow instead — it supersedes this prompt.** This file is the no-skill-runtime fallback that gets seeded into every recording's `.agent/` directory.

You're picking up where Pass 1 left off. `flow.yaml` exists with the phases array drafted but no `paths` blocks yet. Your job in this prompt is to fill those in — first the canonical GUI replay derived from the recording, then a small set of cheaper headless alternatives.

## Inputs you may read in this pass

```
<flow-dir>/
  flow.yaml                  # ← READ + REWRITE. Pass 1 wrote the phases.
  events.jsonl               # ← READ. The lightweight step index.
  steps/
    NNNN-action_type/        # ← READ each step's meta.yaml when you
      meta.yaml              #   need full detail (replicate, element,
      screenshot.jpg         #   coordinates, AX subtree, etc).
      annotated.jpg
  audio/narration.txt        # if present
```

You can open step folders now. Pass 1 deliberately stayed out so it could focus on boundaries; Pass 2 needs the rich detail.

**Always use absolute paths** when reading or writing any file.

## Pass 2 — Assemble the GUI path

For each phase in `flow.yaml`:

1. Walk the events.jsonl lines that fall in this phase's step range.
2. For each line, open `<flow-dir>/<step_dir>/meta.yaml` to get the full step detail.
3. Build a `gui` path: the recording, **lightly trimmed of obvious noise**.

The GUI path is the recording. Keep it faithful. Strip only:

- A typo + immediate backspace (e.g. typed "helo", backspaced, retyped "hello"). The merged step in events.jsonl already coalesced these — they show as one step. But if the user typed something then deleted the whole thing and retyped, that's two events; drop the first.
- An immediate undo (Cmd+Z right after a click that visibly hit the wrong target).
- An aborted misclick (a click followed within a fraction of a second by a click on a different element, with no narration justifying both).

**Don't reorder. Don't reinterpret. Don't merge unrelated steps.** The GUI path is what the user actually did.

For each step in the phase, write a step entry into the phase's `paths` array:

```yaml
paths:
  - kind: gui
    description: "<one-line: what does this whole GUI sequence accomplish?>"
    steps:
      - step: "0007"                                # zero-padded, matches steps/NNNN-…
        text: "<one-line: what is this step doing?>"
        replicate: "<copy verbatim from steps/NNNN/meta.yaml>"
        screenshot: "steps/0007-click/annotated.jpg" # use annotated when it exists,
                                                    # else screenshot.jpg, else region.png
                                                    # for highlight steps.
```

The `replicate` field in each step's meta.yaml is the canonical UI-replay command. Drop it in verbatim — don't reconstruct from coords.

## Pass 3 — Propose headless alternatives

For each phase, propose one or more cheaper paths that complete the **whole phase** with as few commands as possible — typically one. Order easiest + fewest deps first:

1. **`shell`** — a single shell line that achieves the postcondition. `open -b com.apple.mail`, `pbcopy < /tmp/x`, `osascript -e '...'` if it's truly a one-liner.
2. **`osascript`** — when AppleScript is the natural automation. Multi-line is fine — use a `command: |` literal block scalar.
3. **`mcp`** — when an MCP server (Calendar MCP, Notion MCP, Reminders MCP) can do the whole phase in one tool call.
4. **`cli`** — a known CLI tool: `gh`, `brew`, `defaults`, app-specific binaries.

**Coarse, not granular.** A non-GUI path replaces the entire GUI sequence inside a phase. If a candidate alternative can only handle part of the phase, the **phase boundary is wrong** — go back to Pass 1 and split or merge phases. Don't shoehorn a partial path.

**Self-contained.** No mid-path handoffs to the GUI. If the agent's chosen alternative fails at runtime, it falls back to the *next whole path* in the list, never into the middle of one.

For each alternative, write:

```yaml
  - kind: <shell|osascript|mcp|cli>
    description: "<one line: why this works headless, what trade-off if any>"
    command: |
      <the actual command or script>
```

If you can't find a plausible headless path for a phase, leave only the GUI path. That's fine — the agent will fall back to UI replay. Don't invent a fake alternative.

## Final flow.yaml shape

After Pass 2 + 3, `flow.yaml` should look like:

```yaml
schema_version: 2
name: send-status-email-to-team
task_description: "Send a daily status email to the team alias"
recorded_at: 2026-05-01T14:21:33Z
duration_seconds: 184

phases:
  - name: open_email_app
    intent: "Bring Mail to the foreground."
    precondition: "Nothing in particular."
    postcondition: "Mail is frontmost."
    paths:
      - kind: gui
        description: "Click Mail in the Dock."
        steps:
          - step: "0001"
            text: "Click Mail in the Dock."
            replicate: "flow42 act click --x 1340 --y 1490 --button left"
            screenshot: steps/0001-click/annotated.jpg
      - kind: shell
        description: "Open Mail by bundle id."
        command: open -b com.apple.mail
      - kind: osascript
        description: "Activate Mail via AppleScript (Automation permission required)."
        command: |
          tell application "Mail" to activate

  - name: compose_message
    intent: "Open a new message addressed to the team alias."
    precondition: "Mail is frontmost."
    postcondition: "A compose window is open with To: team@web42.io."
    paths:
      - kind: gui
        description: "Cmd+N, type the alias, tab out."
        steps:
          - step: "0007"
            text: "New message."
            replicate: "flow42 act hotkey --modifiers cmd --key n"
            screenshot: steps/0007-hotkey/screenshot.jpg
          - step: "0008"
            text: "Address it to the team alias."
            replicate: "flow42 act type --text 'team@web42.io'"
            screenshot: steps/0008-typeText/screenshot.jpg
      - kind: osascript
        description: "Compose end-to-end via AppleScript — replaces the GUI sequence above."
        command: |
          tell application "Mail"
            set newMsg to make new outgoing message with properties {visible:true}
            tell newMsg to make new to recipient at end of to recipients with properties {address:"team@web42.io"}
          end tell
```

## When you're done

After both Pass 2 (GUI paths) and Pass 3 (alternatives) have written into `flow.yaml`, end your last message with **exactly** this line on its own:

> Done — flow.yaml is ready. Render it with `flow42 view <flow-dir>`.

The user can then run `flow42 view <flow-dir>` for the human-readable markdown, or `flow42 view <flow-dir> --path osascript > replay.scpt` to get a runnable script of just the headless paths.

## Hard rules

- **Don't generate parameter placeholders during Pass 2.** The recording is faithful — recorded values stay literal. Parameter substitution is a future concern (Pass 4, not in scope here).
- **No `audience:` flags. No `id:` keys. No structured pre/postconditions.** The schema is deliberately minimal; resist adding fields.
- The first `paths` entry MUST be `kind: gui`. Order matters: cheapest runnable path wins, but the GUI is always there as ground truth.
- **Use absolute paths** for every file read or write.
- If during Pass 3 you discover that no headless alternative can complete the whole phase end-to-end, **flag it** — the phase boundary may be wrong and you should propose a re-split to the user before continuing.
