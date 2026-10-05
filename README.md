# Verbaline

**Private, on-device voice dictation for macOS.** Hold **fn**, talk, let go, and your words appear wherever your cursor is: cleaned up, punctuated and formatted. Highlight text and hold **fn + Control** to rewrite it by voice.

Everything runs on your Mac. Speech recognition uses Apple's built-in **SpeechAnalyzer**, and cleanup and rewriting use Apple's on-device **Foundation Models**. Verbaline needs no account and no API keys, has no networking code, and has no subscription.

> A personal project shared as-is. It's built and tested on one Mac, so expect rough edges elsewhere. Issues and pull requests are welcome.

---

## Why Verbaline

- **Private by design.** Your voice and your text are processed on your Mac and never sent to a server by Verbaline.
- **Free and open source** (MIT). No word limits.
- **Built for work where details matter.** A *number guard* stops the AI from adding, dropping, changing or reordering numbers you said, such as rates, amounts and dates.
- **Command Mode included.** Rewrite or draft text by voice, on-device.
- **It gets better as you use it.** Fix a misheard word once and Verbaline remembers it.
- **Plays nicely with AirPods.** It records from your Mac's built-in mic, so your music keeps playing in high quality.

---

## Commands and shortcuts

### Keys

| Do this | What happens |
|---|---|
| **Hold fn**, talk, release | Push-to-talk. The text is pasted where your cursor is. |
| **Double-tap fn**, talk, **tap fn** | Hands-free. Keeps listening until you tap fn again. |
| **Esc** | Cancels a recording. Also stops Type It Out. |
| Highlight text, **hold fn + Control**, say an instruction, release | **Command Mode:** rewrites the highlighted text. |
| **Hold fn + Control** with nothing highlighted | **Command Mode:** writes new text at the cursor from your instruction. |
| **⌃⌘V** | Pastes your last transcript again. |
| **⌃⌘C** | Copies your last transcript. |

### Things you can say while dictating

| Say | Result |
|---|---|
| "new line" | a line break |
| "new paragraph" | a blank line |
| "bullet point" / "next bullet" | a "• " bullet on a new line |
| "…at 2, **actually** make that 3" / "**no wait**" / "**I mean**" / "**or rather**" | the correction is applied and only the final version is kept (needs AI cleanup, below) |
| "first … second … third …" | a numbered list (needs AI cleanup) |
| "…**scratch that**" | removes what you said just before it |
| "Delete that." (said on its own between sentences) | removes the sentence before it |
| A snippet trigger, like "insert my signature" | pastes your saved text exactly |

Normal phrases are left alone: "a new line of credit", "the bullet point is…", "can you delete that?". *AI cleanup* means Apple Intelligence is on and **AI Cleanup** is checked in the menu; everything else works without it.

### Command Mode instructions (examples)

"make this more professional", "shorten this", "turn this into bullet points", "fix the grammar", "make it friendlier", "translate this to Spanish", and with nothing selected: "write a two-sentence follow-up thanking Sarah for the documents".

---

## Features

- **Smart cleanup**
  - Removes "um", "uh" and stutters.
  - Applies your spoken corrections and formats spoken lists.
  - Plain sentences skip the AI entirely and paste in about 0.3 s.
- **Number guard**
  - Every number written in digits has to survive exactly. Nothing new, nothing reordered, nothing dropped unless you corrected yourself.
  - If the AI breaks this rule, Verbaline uses the plain cleanup instead.
- **Command Mode**
  - Rewrites or drafts text with the on-device model.
  - ⌘Z undoes it like any paste.
  - The same number rules apply.
- **Personal dictionary**
  - Fixes the spelling and capitalization of your terms and names.
  - Supports `heard -> written` corrections.
- **Learns from your fixes**
  - Correct a misheard word after a paste, and Verbaline adds the fix to your dictionary. A small pill says **✨ Learned · Helllock → HELOC**.
  - When a saved fix is used later you'll see **✓ Fixed · Helllock → HELOC**, with a soft chime.
  - It never learns numbers, swaps of everyday words ("Monday" → "Tuesday") or single common words.
- **Snippets**
  - Say a trigger phrase to paste exact saved text, such as a signature, disclaimer or link.
  - Neither the AI nor the dictionary ever touches it.
- **Spoken formatting:** new line, new paragraph, bullets.
- **Noise handling**
  - Ignores recordings with no speech (taps, clicks, fidgeting) and shrinks long pauses.
  - Uses Apple's echo cancellation when sound plays from your speakers.
- **AirPods-friendly**
  - Records from the built-in mic, so AirPods stay in music mode.
  - Your music isn't paused, muted or transcribed.
- **Type It Out** (optional)
  - Types your dictation letter by letter instead of pasting, at Steady or Fast speed.
  - Useful where pasting is blocked. Your clipboard is never touched.
  - It stops if you switch apps.
  - Only your own dictated words are typed. Command Mode's AI-written text always pastes.
- **Floating pill** at the bottom of the screen
  - Live sound bars while you talk, a wand in Command Mode, dots while it works, and small confirmations.
- **Menu-bar settings:** AI cleanup, noise filter, built-in mic, mic mode (Voice Isolation), personal dictionary, snippets, Learn From My Edits, Type It Out and typing speed, sounds, launch at login, recent transcripts.

---

## Verbaline vs. Wispr Flow

Wispr Flow is the polished commercial app that inspired this project. Here's an honest comparison, based on Wispr's public pricing page, help center and terms as of October 2026:

| | Verbaline | Wispr Flow |
|---|---|---|
| Where your speech is processed | On your Mac (Apple SpeechAnalyzer) | Wispr's cloud |
| AI cleanup | On your Mac (Apple Foundation Models) | Cloud models (Wispr's terms mention OpenAI and Anthropic) |
| Account | None | Required |
| Price | Free, open source (MIT) | Free plan: 2,000 words/week. Pro: $12–15/month |
| Command Mode (rewrite by voice) | Included, on-device | Pro or trial only; sends your text to their servers |
| Number guard for rates and amounts | Yes | Not documented |
| Learns from your edits | Yes | Yes |
| Snippets, personal dictionary | Yes | Yes |
| Languages | English (US) | 100+ |
| Platforms | macOS 26+ on Apple Silicon | Mac, Windows, iPhone |
| Meeting notes | No | Yes (Notetaker, beta) |
| Polish and support | A personal project | A commercial product with a team behind it |

Sources: [pricing](https://wisprflow.ai/pricing), [Command Mode help](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode), [terms](https://wisprflow.ai/terms-of-service). Verbaline is not affiliated with or endorsed by Wispr.

---

## Requirements

- macOS 26 or later on Apple Silicon
- Xcode Command Line Tools: `xcode-select --install`
- English (US) speech
- **Apple Intelligence** turned on, for AI cleanup and Command Mode. Basic dictation works without it.

## Install

```bash
git clone https://github.com/JLFinance25/Verbaline.git
cd Verbaline
./build.sh --install     # builds and installs /Applications/Verbaline.app, then starts it
```

Then, in **System Settings → Privacy & Security**:

| Permission | Why |
|---|---|
| Microphone | to hear you |
| Accessibility | to see the fn key, paste or type text, read your selection (Command Mode), and read the text box you pasted into (learning) |
| Input Monitoring | if macOS asks: to see the fn key |

Also set **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**, so fn doesn't open the emoji picker.

### Keep permissions across rebuilds (optional)

Locally built apps are "ad-hoc" signed, so macOS forgets their permissions every time you rebuild. To avoid that, create a private signing certificate once:

```bash
scripts/make-signing-identity.sh     # adds a self-signed code-signing certificate to your login keychain
```

Then create `local.env` next to `build.sh`. It's git-ignored and read as plain `KEY=value` lines, never run as code.

```bash
VERBALINE_SIGN_IDENTITY="Verbaline Local Signing"
```

The first build asks for keychain access to the certificate. Approve it once.

---

## Privacy

- **Audio stays in memory.** Recordings are never written to disk or sent anywhere.
- **No networking code.** On first launch Verbaline asks macOS to install Apple's English speech model if it's missing; macOS does the download. Apple Intelligence models are managed by macOS.
- **The key watcher** sees every key press system-wide, but only looks at which key it was, to spot fn, Esc and fn+key shortcuts. It never records keystrokes.
- **Password fields are never read.** If you dictate into one, the text goes in but isn't saved to history or watched.
- **What's stored** in `~/Library/Application Support/Verbaline/` (a folder only your account can open):
  - `history.jsonl`: your dictations and Command Mode results, in plain text, trimmed to the newest 2,000 entries once it passes 5,000. Delete it any time.
  - `dictionary.txt`: your words and learned fixes.
  - `snippets.txt`: your snippets.
  - `status.json`: permission and status flags, plus the name of the last app it watched. No transcripts or text.
- **Learn From My Edits** is on by default and can be switched off in the menu.
  - After a paste, Verbaline finds the text box that holds what it pasted. If needed, it searches the front app's windows.
  - It re-reads that box for about a minute, or up to 90 s while you're still typing.
  - It keeps only the pasted text and the 40 characters around it, and saves only short word pairs it learns.
- **Command Mode** reads your selection through Accessibility.
  - If an app doesn't share it, Verbaline presses ⌘C and then restores your clipboard. A clipboard manager you use may record that copy.
  - The selection goes only to Apple's on-device model.
- **Apps like Chrome, Slack and Claude** only share their text boxes when asked. Verbaline asks with the standard `AXManualAccessibility` flag, the same mechanism screen readers use.
- **Hardened runtime.** The app is built with macOS's hardened runtime, so other programs can't inject code into it and borrow its permissions.

See [SECURITY.md](SECURITY.md) for how to report a problem.

## Use it responsibly

- **AI output can be wrong.** Proofread anything important, especially Command Mode drafts.
- **The number guard has limits.** It checks numbers written in digits, not facts, claims, or numbers spelled out in words.
- **Don't use it unsupervised for high-stakes advice.** That includes financial, legal and medical advice. Apple's terms for its on-device model apply.

---

## Tests

```bash
tests/run_all.sh mylabel     # builds a test version and runs every test; results in build/regress/mylabel/
```

- **Speech clips** are generated with macOS's built-in `say` voice. The first run may trigger macOS's one-time speech-model download.
- **Self-test windows:** a few tests briefly open a small window that closes by itself. The typing test sends keystrokes only to its own window.
- **Test tools** (`--selftest`, `--mictest` and similar) exist only in test builds (`VERBALINE_TESTING=1 ./build.sh`), never in the installed app.

## Project layout

| File | What it does |
|---|---|
| `src/AppDelegate.swift` | fn gestures, menu bar, dictation and Command Mode flow |
| `src/FnKeyMonitor.swift` | the system-wide fn key watcher |
| `src/AudioRecorder.swift`, `src/MicCapture.swift` | mic capture (built-in mic via AVCaptureSession) |
| `src/SpeechGate.swift` | keeps speech, drops clicks and silence, shrinks pauses |
| `src/AppleTranscriber.swift` | on-device speech-to-text (SpeechAnalyzer) |
| `src/TextCleaner.swift` | rule cleanup plus the on-device AI, with the number guard |
| `src/TextPipeline.swift` | transcript → cleanup → dictionary → formatting → snippets |
| `src/CommandMode.swift` | Command Mode rewriting and drafting |
| `src/PersonalDictionary.swift`, `src/EditWatcher.swift`, `src/EditLearner.swift` | the dictionary and learning from your fixes |
| `src/Snippets.swift`, `src/SpokenFormatting.swift` | snippets and spoken formatting |
| `src/TextInserter.swift`, `src/TextTyper.swift`, `src/AXText.swift` | pasting, typing, and reading other apps' text boxes |
| `src/Overlay.swift` | the floating pill |

The starter dictionary leans toward US mortgage terms; edit `dictionary.txt` for your field.

## Known limitations

- English (US) only.
- macOS 26+ on Apple Silicon only.
- Some apps don't share their text boxes, so learning from edits won't work there.
- Command Mode on long selections is slow (about 12 s for 2,500 characters) and is capped at 2,500 characters.
- Text that contains instructions ("ignore previous instructions…") is usually edited, not obeyed, by Command Mode, but that isn't guaranteed.

## Prior art and credits

- Inspired by [Wispr Flow](https://wisprflow.ai).
- Other open-source projects in this space:
  - [FreeFlow](https://github.com/zachlatta/freeflow)
  - [Megaphone](https://github.com/Kuberwastaken/megaphone), which also uses SpeechAnalyzer and Foundation Models
  - [VoiceInk](https://github.com/Beingpax/VoiceInk)
  - [Handy](https://github.com/cjpais/Handy)

## License

[MIT](LICENSE)
