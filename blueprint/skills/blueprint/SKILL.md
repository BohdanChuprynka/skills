---
name: blueprint
description: Use when the user asks for a blueprint, an architecture map, or a diagram of a system or one part of it ("make a blueprint of the sync pipeline", "map the search architecture"), in any project. Builds a zoomable HTML map from the real code with connected zones that flow left to right, the real texts and their sizes on click, suspected bottlenecks with evidence levels, optional eval cases, and a walk-through, then checks it in headless Chrome and publishes it.
---

# Blueprint

A blueprint is one zoomable, pannable page. With it, an engineer can see the whole system, follow one real request through it, and see where to look first. Comprehension is the goal. Show what an engineer needs to find problems, and leave out the rest.

The look and the renderer are fixed and shared by Codex and Claude Code. Each map changes only its data. If the renderer cannot show something a map needs, work around it in the data, finish the map, and name the gap in your report. Change `assets/renderer.html` only when the user asks, then rebuild both `examples/` with 0 errors and 0 warnings.

## Files

| Path (in this skill folder) | Use |
|---|---|
| `assets/renderer.html` | The generic page: style, layout, arrows, zoom, panels, eval views, self-check |
| `scripts/build.py DIR` | Fills the renderer with `DIR/blueprint.js` (+ `sources.json`, `eval.json`) and writes `NAME.page.html` and `NAME.html` |
| `scripts/check.py PAGE.html` | Headless Chrome: prints the page's data errors and warnings, and writes screenshots to `shots/` |
| `references/data-format.md` | Every field of `blueprint.js`, `sources.json`, `eval.json`. Read it before you write data. |
| `examples/minimal/` | Small starter (this skill drawn with itself). Copy it to start. |

## The standard

- Header: only "<Name> Architecture" and the date. No PR, branch or commit details in the header.
- Under the title, a separate "Suspected bottleneck" key. Its one-sentence `bottleneckKey` is written for this system.
- No box codes (A2, B4). Titles are 1–4 words.
- Zones flow left to right in the order of the flow. The last box of a zone sits about level with the first box of the next zone. Side zones (tools, data stores, models, measurement) go below. Leave space: zoom handles size.
- Every box is connected by arrows, except reference boxes marked `free`.
- A click gives the depth: the real text, not a summary (full prompt, real config, real schema), with its size. It also gives numbers, limits, flags, and absolute code paths.
- Every claim about quality or speed carries its evidence level: measured, partly, or not measured. Never invent a number. A number without a source is "not measured".
- Suspected bottlenecks: up to 9 cards, only where the code or a run gives a reason. Each card says what we know and what we don't know, and names the one next step that would show where the real bottleneck is.
- Where an eval, a test run or a benchmark has per-case results, a click on a box shows those cases: passed, partial or failed, down to one case.
- The walk-through follows one concrete request with real values.

## Procedure

1. **Scope.** Name the part of the system, where it starts, and where it ends. The finish line is that the reader can follow one real request end to end and see where to look first. Infer the scope from the request and the code. Ask the user only when two different maps are equally likely.

2. **Read the code end to end.** Trace one real request or job through every file it touches. Write down each fact with its file path, each limit with its value, and each flag with its default. This step is read-only: do not change the project.
   - For a large system, split the reading by zone. Run parallel read-only agents (Explore in Claude Code) with narrow briefs: "list every step, limit, flag and data store in <files>, with paths and values". You own the data file and the final check.
   - Look for existing evidence: evals, test results, benchmarks, logs, docs with measured numbers. Note the run and the commit of each one.
   - Use evidence that already exists. Do not run evals, benchmarks, or code that needs an API key, a database or the network just for the map: they cost money or change state. Name such a run as the next step instead.

3. **Start the folder** outside the project, one folder for each map: your scratchpad in Claude Code, a new folder under `$TMPDIR` in Codex. Copy `<skill>/examples/minimal` there and delete its `shots/`, `sources.json` and built `.html` files. The folder is temporary; the published page holds all the data.

4. **Write `blueprint.js`** (see `references/data-format.md`).
   - Set `ROOT` to the project's absolute path. Use 4–8 zones on the main row. Put at most about 8 boxes in a zone, with one idea in each box.
   - Mark the main path with `main: true` and optional paths with `cond: true`.
   - Write `d` for each box: what it does, key numbers, limits, flags, then `code(...)` with the files.
   - Write the bottlenecks from what you read and measured. Pin them on the boxes (`issues`), and write `next` and `bottleneckKey`.
   - Write the tour: 5–10 steps for one concrete request. Make the last step point at the bottlenecks.

5. **Write `sources.json`** for every box where the real text matters (prompts, tool definitions, configs, queries). Where the function is local and has no side effects, run it for one fixed setup and say the setup in `note`; otherwise copy the text by hand and say so. A small script that imports the function, calls it, and writes `sources.json` is usually enough.

6. **Write `eval.json`** only when per-case results exist. Respect each data set's rules. For a hidden or blind test set, take the totals from the run's summary and do not open its case file: reading the case text already spoils the set. If the project's evidence has its own questions, add a chart in `charts`.

7. **Build and check:**
   ```bash
   python3 <skill>/scripts/build.py <dir>
   python3 <skill>/scripts/check.py <dir>/<name>.html --also <box-id> --also <box-id>
   ```
   - Fix every error. Fix every warning, or mark the box `free` when no arrow is correct.
   - Open every screenshot in `shots/` and look for crossing arrows, boxes that touch, labels on boxes, cramped or empty zones, and zone names that collide. Fix them by moving boxes (`col`, `row`) or zones (`place`), then rebuild and check again.
   - Stop at 0 errors and clean screenshots. If a problem remains after a few tries, or the check cannot run, publish anyway and list what is still wrong or unchecked in the report. A map with a named flaw helps more than no map.
   - If check.py says the page did not finish its self-check, Chrome probably has no network for the CDN. If a local policy blocks it, set `BLUEPRINT_CHROME_ARGS="--proxy-server=<approved proxy>"`. Do not try other ways around the policy.

8. **Publish.** Follow the user's rules for publishing. A private page in the user's own account is the usual delivery.
   - If you have an Artifact tool (Claude Code), publish `<name>.page.html` as built, with the icon `map`. Do not restyle it or start from an Artifact type. To update the map in the same session, publish the same file path again. In a later session, read it by its `url` and publish with that `url`.
   - Also send `<name>.html` as a file. Without the Artifact tool, hand over `<name>.html` and its absolute path.

9. **Report to the user:**
   - The link.
   - What the map covers.
   - The top 3 bottlenecks with their evidence levels.
   - What is not verified (production config, single runs, estimates), and anything step 7 left unfixed or unchecked.
   - The data folder's absolute path.

## Limits

- The layout is a grid, not a solver. Long arrows between distant zones can cross boxes. Fix this in the data.
- The icons (Lucide) and the Geist font come from a CDN. Offline, the icons are missing and the fonts fall back. Apple devices use SF Pro, the system font.
- Headless Chrome cannot show a true phone viewport. The phone layout is not verified by check.py.
