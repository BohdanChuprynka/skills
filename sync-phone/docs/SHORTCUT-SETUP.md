# iPhone Shortcut setup

Build on iPhone. Open the **Shortcuts** app.

Target file the shortcut writes to:
- iCloud Drive → `_obsidian-capture` → `iphone-raw.md`

(If you put the capture folder somewhere else, point the **Append to File** action at your folder instead.)

---

## Step 1: Build the "Add to Wiki" shortcut

**Goal**: tap a button or say "Hey Siri, add to wiki" → speak → entry appends to `iphone-raw.md` in iCloud.

**Why Record Audio + Transcribe, not Dictate Text:** Dictate Text is unreliable in practice — it cuts off mid-thought, drops words on noisy walks, and sometimes never fires the "stop" condition. Record Audio captures the full waveform first, then transcribes it as a separate step. You get the complete thought every time, and the transcription quality is noticeably better because it has the whole audio file to work with.

1. Shortcuts app → tap **+** (top right) → name it exactly **`Add to Wiki`** (Siri matches this name).
2. Add actions in this order:

| # | Action | Setting |
|---|--------|---------|
| 1 | **Record Audio** | Audio Quality: **Very High**. Start Recording: **Immediately**. Finish Recording: **On Tap**. |
| 2 | **Transcribe Recorded Audio to text** | Input: **Recorded Audio** (from action 1). |
| 3 | **Get Current Date** | Format: Custom → `yyyy-MM-dd HH:mm` (or whatever you prefer) |
| 4 | **Text** | Content: `### ([Current Date]) Content:\n"[Transcribed Audio]"\n` |
| 5 | **Append to File** | File: tap **File** → choose **iCloud Drive → _obsidian-capture → iphone-raw.md**. Input: **Text** (from action 4). |
| 6 | **Show Notification** (optional) | Title: "Captured". Body: first 50 chars of [Transcribed Audio]. |

Visually:

```
Record audio                (Very High / Immediately / On Tap)
        |
        v
Transcribe Recorded Audio to text
        |
        v
Current Date
        |
        v
Text: ### (Current Date) Content:
      "Transcribed Audio"
        |
        v
Append Text to _obsidian-capture/iphone-raw.md
```

The skill's parser is forgiving about the exact header format — `## YYYY-MM-DD HH:MM`, `### (date) Content:`, or anything similar all parse fine. Pick whatever the iPhone Shortcuts editor makes easiest.

---

## Step 2: Bind it to something fast

You want a single button or phrase so you don't lose the thought hunting for the Shortcuts app.

**Action Button (iPhone 15 Pro and later):**
- Settings → Action Button → swipe to **Shortcut** → choose **Add to Wiki**.

**Siri (any iPhone):**
- The shortcut name is already the Siri phrase. Test: "Hey Siri, add to wiki, testing the pipeline."

**Apple Watch complication:**
- Watch app on iPhone → My Watch → Complications → add **Shortcuts** complication.
- Watch face → tap complication → pick **Add to Wiki**. Works on Series 8 and later, requires phone reachable for transcription.

**AirPods / CarPlay / HomePod:**
- All work through Siri once the shortcut is named correctly. "Hey Siri, add to wiki, …".

---

## Step 3: Verify the round trip

1. On iPhone: "Hey Siri, add to wiki, testing the pipeline."
2. Wait ~10 seconds for iCloud to sync.
3. On Mac: `cat ~/Library/Mobile\ Documents/com~apple~CloudDocs/_obsidian-capture/iphone-raw.md` — should show your entry with the timestamp header.

If sync is slow: open the **Files** app on iPhone and tap into `_obsidian-capture/`. That often nudges iCloud to flush.

---

## Step 4: Drain the inbox from Mac

Once you have a few entries:

```
/sync-phone
```

in Claude Code. The skill reads the file, summarizes, routes into your vaults, archives the summary, and clears the inbox.

---

## Tips

- **Naming matters for Siri.** The exact phrase "Add to Wiki" is what Siri matches. If you rename the shortcut, the Siri trigger changes too.
- **One file, not many.** Keep everything appending to `iphone-raw.md`. The skill is built for a single sink. Multiple sink files would complicate routing without adding value.
- **Don't over-engineer.** The whole point is "thought happens → finger taps once → it's saved." If you find yourself adding 8 actions to the shortcut, you've reinvented the EOD recap and you're not going to use it.
- **iCloud is the only network dependency.** No third-party app, no API key, no token. If iCloud is down, the file just doesn't sync until it's back — your dictation is still on the phone.
