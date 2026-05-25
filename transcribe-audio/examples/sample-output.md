# Sample output

Below is the kind of output produced by:

```bash
transcribe-audio transcribe ~/Downloads/sample-call.m4a \
  --language uk \
  --prompt "Розмова про knowledge graphs, ontology, Neo4j" \
  --summary --summary-style brief \
  --obsidian
```

## Terminal output

```
sample-call.m4a — 11.5 min, 2.0 MB, mp3 16000Hz (1 ch)
Estimated cost: $0.0690  (model: whisper-1)
⠋ Transcribing... transcribe: 1/1
Transcribed 87 segments

✓ Transcripts written:
  /Users/me/transcripts/sample-call.txt
  /Users/me/transcripts/sample-call.srt
  /Users/me/transcripts/sample-call.summary.md  (summary: brief)

✓ Obsidian note: /Users/me/Documents/Obsidian/personal/inbox/2026-05-25-sample-call.md

Detected language: uk
```

## sample-call.txt

```
Привіт, як справи. Я дивлюся в твою презентацію по knowledge graphs.
Що саме ви робите з ontology? Чи це більше LLM extraction поверх ISO 20022?
...
```

## sample-call.srt

```srt
1
00:00:00,000 --> 00:00:03,200
Привіт, як справи.

2
00:00:03,200 --> 00:00:08,500
Я дивлюся в твою презентацію по knowledge graphs.
...
```

## sample-call.summary.md

```markdown
**Topic:** обговорення архітектури knowledge graph системи на базі ontology.

**Key points:**
- Анастасія описує продукт Catalyst Data Intelligence
- Bohdan розглядає entity resolution як основний challenge
- Технічний стек: Neo4j + LLM extraction поверх ISO 20022 ontology
- Дедлайн на listopad 2026

**Decisions:**
- Узгоджено продовжити розмову на технічному рівні з Mark наступного тижня

**Open questions:**
- Який формат співпраці (contract / project-based) — не визначено
```

## Obsidian note: 2026-05-25-sample-call.md

```markdown
---
created: 2026-05-25T13:42:18
type: transcript
source: /Users/me/Downloads/sample-call.m4a
duration_seconds: 685.1
language: uk
transcribe_model: whisper-1
summary_model: gpt-4o-mini
summary_style: brief
status: unreviewed
---

# sample-call

## Summary

**Topic:** обговорення архітектури knowledge graph системи на базі ontology.
...

---

## Transcript

Привіт, як справи. Я дивлюся в твою презентацію по knowledge graphs.
...
```
