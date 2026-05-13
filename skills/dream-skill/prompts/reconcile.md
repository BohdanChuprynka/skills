Run a dream-cycle reconciliation. Inputs below — produce the dream report in the exact format specified by your system prompt.

The vault tracks **the user as a person**, not their work outputs. Filter accordingly.

**Today's date:** {TODAY}
**Active window:** {WINDOW}

=== SESSION SIGNALS (window: {WINDOW}) ===
{SESSIONS}

=== VAULT STATE ===
{VAULT}

=== TASK ===

**Step 1 — Probe external sources (if available).** Before reasoning over the inlined inputs, check whether MCP tools are present. For each tool that is wired in:

- List Notion pages edited within {WINDOW}; read persona-relevant ones.
- List Calendar events from `today − {WINDOW}` through `today + 7d`.
- Search Gmail for `newer_than:` matching {WINDOW}; scan persona-relevant subjects only.

If a tool is absent or errors, note the absence once under `## signals not acted on` and move on. Do not retry.

**Step 2 — Reconcile.** Compare every available signal source (SESSIONS + VAULT + any MCP outputs) per your system-prompt protocol. Address:

1. Persona-level facts that contradict or update the vault.
2. New persona-level entities (people, programs, mentors, deadlines, gyms, courses) mentioned 2+ times across any sources, with no vault page.
3. Pages flagged `needs_verification:` — did any source answer the gap?
4. Stale pages (`updated:` past threshold) — do current signals confirm or contradict?
5. Open contradictions requiring clarification.

**Step 3 — Classify each proposal** into the correct section by channel diversity, then sort each section by confidence descending. Cite every distinct source separately so the parser can count channels.

Write the report directly. The first character of your response MUST be `-` (the start of the YAML frontmatter `---`). No preamble. No code fence wrapping the output.
