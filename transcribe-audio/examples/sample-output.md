# Sample output

Below is the kind of output produced by:

```bash
transcribe-audio transcribe ~/Downloads/sample-call.m4a \
  --language uk \
  --prompt "Розмова про semantic search, embeddings, pgvector" \
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

✓ Obsidian note: /Users/me/Documents/Obsidian/personal/inbox/2026-03-10-sample-call.md

Detected language: uk
```

## sample-call.txt

```
Привіт, як справи. Я дивлюся в твою презентацію по semantic search.
Що саме ви робите з embeddings? Чи це більше hybrid search поверх pgvector?
...
```

## sample-call.srt

```srt
1
00:00:00,000 --> 00:00:03,200
Привіт, як справи.

2
00:00:03,200 --> 00:00:08,500
Я дивлюся в твою презентацію по semantic search.
...
```

## sample-call.summary.md

```markdown
**Topic:** обговорення архітектури semantic search для каталогу продуктів.

**Key points:**
- Олена описує продукт Acme Analytics
- Користувач розглядає якість embeddings як основний challenge
- Технічний стек: PostgreSQL + pgvector + hybrid search
- Дедлайн на березень 2027

**Decisions:**
- Узгоджено продовжити розмову на технічному рівні з Іваном наступного тижня

**Open questions:**
- Який формат пілоту (безкоштовний / платний) — не визначено
```

## Obsidian note: 2026-03-10-sample-call.md

```markdown
---
created: 2026-03-10T13:42:18
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

**Topic:** обговорення архітектури semantic search для каталогу продуктів.
...

---

## Transcript

Привіт, як справи. Я дивлюся в твою презентацію по semantic search.
...
```
