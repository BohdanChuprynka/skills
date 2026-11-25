# blueprint

Turn a system, or one part of it, into a zoomable architecture map that an engineer can read in minutes. A Claude Code and Codex skill.

The agent reads the real code, writes a small data file, and builds one self-contained HTML page:

- **Zones that flow left to right**, with every box connected by arrows. Side zones (tools, data stores, models, measurement) sit below.
- **Depth on click.** Each box opens a panel with what it does, its limits and flags, and the *real* text it uses (a full prompt, a real config, a schema) with its size in characters, bytes, lines, words and estimated tokens.
- **Suspected bottlenecks.** Orange pins mark the places worth looking at first. Each card says how strong its evidence is: measured, partly, or not measured. A "Next step" card names the one measurement that would locate the real bottleneck.
- **Eval drill-down (optional).** When the project has per-case test or eval results, a click on a box shows before/after pass, partial and fail bars, a chart, and a filterable case list, down to one case with its expected facts, tool calls and answer.
- **Walk-through.** One concrete request, step by step, highlighted on the map.
- **Legend on demand.** A Legend button under the title opens beside the map. Pages show no local file paths, so they are safe to share.
- **No text overflow at any zoom.** Zoomed out, a box shows only its title, sized to the box.
- **Self-check.** The page validates its own data (unknown ids, missing sources, loose boxes, overflow, overlapping zones). `check.py` reads the result in headless Chrome and takes screenshots for a visual review.

The look is fixed: a dark grid sheet, Lucide icons, SF Pro on Apple devices (system font) and Geist elsewhere, Geist Mono for labels and numbers. Each map changes only its data.

## Install

```bash
git clone https://github.com/BohdanChuprynka/skills
cd skills/blueprint
./setup.sh
```

`setup.sh` links the skill into `~/.claude/skills/blueprint` and `${CODEX_HOME:-~/.codex}/skills/blueprint`, then builds the starter example as a self-test. It needs Python 3 (no packages). `check.py` needs Chrome or Chromium.

## Use

Ask your agent for a map:

```
make a blueprint of the sync pipeline
```

The skill tells the agent to scope the part, read the code end to end (read-only), write `blueprint.js`, render the real texts into `sources.json`, add `eval.json` only when per-case results already exist, build, check, review every screenshot, and publish.

By hand:

```bash
cp -R skills/blueprint/examples/minimal /tmp/my-map     # then edit /tmp/my-map/blueprint.js
python3 skills/blueprint/scripts/build.py /tmp/my-map
python3 skills/blueprint/scripts/check.py /tmp/my-map/<name>.html --also <box-id>
```

## Files

| Path | What it is |
|---|---|
| `skills/blueprint/SKILL.md` | The procedure the agent follows |
| `skills/blueprint/assets/renderer.html` | The generic page: style, layout, arrows, zoom, panels, eval views, self-check |
| `skills/blueprint/scripts/build.py` | Builds `NAME.page.html` (for an artifact) and `NAME.html` (standalone) from a data folder |
| `skills/blueprint/scripts/check.py` | Headless Chrome: data errors, warnings, and screenshots |
| `skills/blueprint/references/data-format.md` | Every field of `blueprint.js`, `sources.json` and `eval.json` |
| `skills/blueprint/examples/minimal/` | Starter: the skill drawn with itself |

## Limits

- The layout is a grid, not a graph solver. Long arrows between distant zones can cross boxes; move the box or the zone in the data.
- Icons and the Geist font load from a CDN. Offline, icons are missing and fonts fall back.
- `check.py` cannot emulate a true phone viewport.

MIT licensed, like the rest of this repository.
