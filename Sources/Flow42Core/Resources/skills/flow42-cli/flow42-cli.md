# flow42 CLI — quick reference for humans

A pocket reference for the flow42 commands. Every call prints one JSON line on stdout.

## Discovery

| Command | What you get back |
|---|---|
| `flow42 state` | List of running apps + windows |
| `flow42 tree` | Full hierarchy of the frontmost app |
| `flow42 find --query "Save"` | Elements matching that name |
| `flow42 inspect --query "Today"` | Full metadata for one element |
| `flow42 element-at --x 1327 --y 1167` | What's at that pixel |
| `flow42 read` | Text content of the frontmost app |
| `flow42 snapshot --output /tmp/x.jpg` | Screenshot |
| `flow42 annotate --output /tmp/x.jpg` | Numbered-overlay screenshot + label map |

Add `--target browser` to any of those (or just `--locator` / `--tab`) to point at the attached Chrome instead.

## Actions

```bash
flow42 act click --x 100 --y 200 --app Calendar          # native, by coords
flow42 act click --query "Save" --app Notes              # native, by AX name
flow42 act type --text "Hello"                           # type into focus
flow42 act press --key Return                            # one key
flow42 act hotkey --keys cmd,shift,t                     # combo
flow42 act scroll --direction down --amount 3            # scroll

# Pointer dynamics
flow42 act hover --x 500 --y 400
flow42 act long-press --x 500 --y 400 --duration 1.5
flow42 act drag --from-x 100 --from-y 200 --to-x 400 --to-y 300

# Window management
flow42 act window --action minimize --app Calendar
flow42 act window --action move --app Notes --x 100 --y 100 --width 800 --height 600

# App focus / browser nav
flow42 act app-switch --to com.apple.Notes
flow42 act focus --app Calendar
flow42 act navigate --url https://example.com           # browser-only
```

Browser examples:
```bash
flow42 act click --target browser --locator "getByRole('button', { name: 'Save' })"
flow42 act type  --target browser --locator "getByPlaceholder('Search')" --text "find me"
```

## Wait

```bash
flow42 wait --condition titleContains --value "Saved" --timeout 10
flow42 wait --condition elementExists --locator "getByText('Done')" --target browser
```

Conditions: `urlContains`, `urlEquals`, `urlChanged`, `titleContains`, `titleEquals`, `titleChanged`, `elementExists`, `elementGone`.

## Recording

```bash
flow42 record --description "save URL to Notes"
flow42 flows                      # list recordings
flow42 flows --json
```

While recording, narrate aloud — your voice is transcribed and interleaved into the action stream.

## The `replicate` field

Every action saved to `flow.json` already includes the exact CLI invocation that reproduces it:

```json
"replicate": "flow42 act click --x 1327 --y 1167.25 --button left --count 1 --app 'Google Chrome'"
```

Copy-paste it into a shell. No translation needed.

## First-run setup

```bash
flow42 setup            # interactive wizard, do this once
flow42 doctor           # check everything is wired
flow42 chrome-launch    # one-time Chrome relaunch with debug endpoint
flow42 install-skills   # put flow42-cli + flow-creator into ~/.claude/skills/
```

## Output shape

Every command emits **one JSON line** on stdout:

- Success: `{"success": true, ...}` plus command-specific keys.
- Failure: `{"success": false, "error": "...", "suggestion": "..."}` and a non-zero exit code.

Pipe through `jq` for pretty printing.
