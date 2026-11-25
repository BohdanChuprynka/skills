# Blueprint data format

A map is one folder:

| File | Required | What it holds |
|---|---|---|
| `blueprint.js` | yes | `const BLUEPRINT = {...}`, plus optional chart functions and eval tweaks |
| `sources.json` | no | Verbatim texts that boxes show on click (prompts, configs, schemas, SQL) |
| `eval.json` | no | Per-case results of two runs (before / after) that boxes link to |

`blueprint.js` runs as a plain browser script after these globals exist:
`SOURCES`, `EVAL` (or `null`), `M`, `P`, `N` (evidence badges as HTML), and
`codeAt(root)`, which returns `code(...relPaths)` that prints a "Code" block of absolute paths.
Chart functions you define run later, so they may use the renderer's helpers:
`CASES`, `hist()`, `sbar()`, `count()`, `vchip()`, `esc()`, `icon()`.

Text fields marked *text* are escaped. Fields marked *html* are inserted as HTML.

## BLUEPRINT

```js
const ROOT = "/abs/path/to/repo/";      // absolute, so every path in the map can be opened as is
const code = codeAt(ROOT);
const BLUEPRINT = {
  title: "Search Architecture",            // "<Name> Architecture". Nothing else in the header.
  date: "2026-11-25",
  zones: [...], nodes: [...], edges: [...],
  issues: [...], next: {...}, bottleneckKey: "...",   // optional, but expected
  tour: {...},                                       // optional, but expected
  legend: { main: "Main path of a request", d: "<p>Where this map came from…</p>" },
  charts: { name: (cases) => "<h4>…</h4>…" },        // optional, project-specific charts
  kinds: { queue: ["list-ordered", "Queue"] },       // optional, adds or overrides box kinds
};
```

### zones

```js
{ id: "loop", name: "Tool loop", icon: "repeat", color: "#4fd1e8",
  place: { after: "context" }, sub: "One or two sentences: what happens here.", free: false }
```

- `place` (one of):
  - `{ start: true }`: the first zone.
  - `{ after: "zoneId" }`: to the right of that zone. The zone moves up or down so the first arrow that enters it is straight.
  - `{ below: "zoneId", under: "nodeId" }`: under that zone. `under` centres it under one box, for example a "Tools" zone under "Run tools".
- `icon`: a [Lucide](https://lucide.dev/icons/) name (0.460.0).
- `color`: the zone tint. Pick from the palette below, and give each zone a different color.
- `free: true`: boxes in this zone may have no arrows (reference zones such as Models or Measurement).
- If `issues` exist and no zone has the id `issues`, the renderer adds a Bottlenecks zone after the last zone. It always adds a Legend zone unless you declare one. Declare `issues` and `legend` yourself to place them.

Palette (dark background, high contrast): `#8aa4ff` blue, `#b896f5` violet, `#4fd1e8` cyan,
`#f08aa8` pink, `#7ee0a1` green, `#d9b97a` sand, `#6fd6c4` teal, `#c3cad6` gray,
`#ff9b54` orange (Bottlenecks only), `#7d889a` slate (Legend only).

### nodes (boxes)

```js
{ id: "rerank", zone: "query", col: 3, row: 0, kind: "model", icon: "scan-search",
  title: "Rerank", sub: "A cross-encoder reorders the top 50 hits.",
  chips: ["top 50 → 10", "120 ms p50"], main: true, cond: false, free: false,
  w: 300, span: 1, issues: ["2"], src: ["rerank_config"],
  eval: { all: true, chart: "flips" },
  html: "", d: `<p>…</p>${code("src/search/rerank.ts")}` }
```

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Unique. Used in links (`#rerank`). Never shown. |
| `zone` | string | Zone id. |
| `col`, `row` | int | Grid cell in the zone, from 0. Columns go left to right in flow order. |
| `kind` | string | `step`, `decision`, `guard`, `model`, `tools`, `store`, `external`, `limit`, `note`, or one from `kinds`. Sets the label and default icon. |
| `icon` | string | Lucide name for this box. Optional; the kind's icon is the default. |
| `title` | text | 1–4 words. No codes like "A2". |
| `sub` | text | One sentence. |
| `chips` | text[] | Key numbers and names (`"96 KB total"`, `"10 s timeout"`). |
| `main` | bool | On the main path: brighter outline. |
| `cond` | bool | Only sometimes (a flag, a condition): dashed box. |
| `free` | bool | May have no arrow (reference boxes). |
| `w` | px | Column width (default 300). Wider for tables. |
| `span` | int | Columns this box covers. |
| `issues` | string[] | Bottleneck ids: draws a pin on the box. |
| `src` | string[] | Keys in `sources.json`. The panel shows each text in full, with its size. The first one is open. |
| `eval` | object | Links eval cases (below). |
| `html` | html | Extra content inside the box (for example a small table). |
| `d` | html | The click panel: the depth. What it does, numbers, limits, flags, then `code(...)`. Use `${M}`, `${P}`, `${N}` before a claim to show its evidence level. |

`eval` filters, one of:
- `{ all: true }`: every case.
- `{ tools: ["search"] }`: cases whose turns called any of these tools.
- `{ areas: ["dates"] }`: cases tagged with any of these areas.

Add `chart: "<name>"` (built in: `areas`, `flips`; or one from `charts`) and `label: "date cases"`.

### edges (arrows)

```js
["from", "to", "label", "style"]   // style: "main" | "cond" | ""
```

- `to` may be `"zone:<id>"` to point at a whole zone.
- Draw every box into the flow. A box with no arrow is a warning unless it is `free`.
- Keep labels to 1–2 words.

### issues (suspected bottlenecks)

```js
{ id: "3", title: "Index misses new files", ev: "m",
  sub: "One sentence with the number.", on: ["indexer", "index"],
  eval: { tools: ["search"] }, d: "<p>What we know. What we don't know.</p>" }
```

- `ev`: `m` measured (from a run), `p` partly (some evidence), `n` not measured (reasoned from code).
- `on`: the boxes involved. Put the same id in each box's `issues`, so the box gets a pin.
- The renderer lays the cards out 3 to a row in the Bottlenecks zone, and puts `next` under them.

`next`: `{ title, sub, d }`. The one next step that would show where the real bottleneck is.

`bottleneckKey`: *html*, one sentence written for this system, shown when the "Suspected bottleneck" key opens. Keep it to 1–2 lines.

### tour (walk-through)

```js
{ question: "EXAMPLE: \"Find the Q3 budget sheet\" (web search)",
  steps: [{ ids: ["user", "api"], cap: "What happens, with real values." }] }
```

Use one concrete request with real values. Use 5–10 steps. Make the last step show where it could fail (the bottleneck cards).

## sources.json

```json
{ "system_full": { "title": "Full system prompt", "text": "…", "note": "Rendered for setup X.",
                   "parts": [{ "name": "Identity", "text": "…" }] } }
```

build.py adds characters, bytes, lines, words and ≈tokens (chars / 4) to each source, and to each part.
Render real text from the real code where you can (call the function that builds the prompt), and say the setup in `note`.

## eval.json

```json
{ "label": "test cases",
  "runs": { "v0": "Before: run A, tree abc123", "v1": "After: run B, tree def456" },
  "totals": [{ "name": "Hidden set", "v0": [32, 94, 25], "v1": [32, 95, 24], "note": "Totals only." }],
  "cases": [{
    "id": "case-004", "v0": "partial", "v1": "pass", "areas": ["dates"],
    "persona": "…", "lang": "en", "diff": "normal", "surface": "web",
    "must": ["fact 1", "fact 2"], "met": [true, false], "mustNot": ["…"], "hit": [],
    "why": "…", "notes": "judge note (after)", "notes0": "judge note (before)", "gap": "retrieval",
    "turns": [{ "q": "question", "a": "answer", "ms": 48000, "note": "retried once",
                "tools": [[1, "search", "{args}", false, "first lines of the result"]] }] }] }
```

- Verdicts are `pass`, `partial`, `fail` (or null when a run has no verdict).
- `tools` rows: `[step, name, args, error?, result head]`. Cut long values (args ~220 chars, heads ~260, answers ~3,000).
- Only `id`, `v0`, `v1` are required. Everything else is shown when present.
- Put only cases you may read. For a hidden or blind set, put its totals in `totals`, never its cases.
- Use a project-specific `charts` function for a question that only this system has (for example: steps per request, results per search).
