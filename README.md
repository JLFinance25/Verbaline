# Verbaline

**Private, on-device voice dictation for macOS.** Hold **fn**, talk, let go, and your words appear wherever your cursor is: cleaned up, punctuated and formatted. Highlight text and hold **fn + Control** to rewrite it by voice.

Everything runs on your Mac. Speech recognition uses Apple's built-in **SpeechAnalyzer**, and cleanup and rewriting use Apple's on-device **Foundation Models**. Verbaline needs no account and no API keys, has no networking code, and has no subscription.

> A personal project shared as-is. It's built and tested on one Mac, so expect rough edges elsewhere. Issues and pull requests are welcome.

> **Will it work on my Mac?** You need a Mac with an Apple chip (M1 or newer) running macOS 26 or newer. To check, click the Apple menu → **About This Mac**. There's no download yet: you build it yourself by pasting a few commands into Terminal (see [Install](#install)).

---

## Why Verbaline

- **Private by design.** Your voice and your text are processed on your Mac and never sent to a server by Verbaline.
- **Free and open source** (MIT). No word limits.
- **Built for work where details matter.** A *number guard* checks that the AI didn't add, drop, change or reorder numbers you said, such as rates, amounts and dates, and falls back to plain cleanup if it did.
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
| "email **spell** K E R G E R about it" | "email Kerger about it": the letters become one word. 5 letters or fewer come out in capitals (HELOC, NMLS), 6 or more with a capital first letter. |
| "**Press enter**" (said on its own, after you've checked your text) | presses Return, which sends the message in chat apps. "Press return" works too. At the end of a longer dictation it's just text, so nothing is ever sent before you've seen it. |

Normal phrases are left alone: "a new line of credit", "the bullet point is…", "can you delete that?", "can you spell that", "a dry spell", "tell them to press enter". *AI cleanup* means Apple Intelligence is on and **AI Cleanup** is checked in the menu; everything else works without it.

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
- **Spell a word**
  - Say "spell" and then the letters, for names and terms the speech engine doesn't know.
  - Leave a tiny pause between letters. Rushed letters can be misheard ("age" for H, "in" for N).
  - The spelled word skips the AI cleanup, and the dictionary can't change it.
- **Press enter to send**
  - Dictate your message, check it, then hold fn and say just "press enter" to send it.
  - Verbaline never pastes and sends in one step, so a misheard word can't go out on its own.
  - Switch it off in the menu (**Press Enter Command**).
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
- **Menu-bar settings:** AI cleanup, noise filter, built-in mic, mic mode (Voice Isolation), personal dictionary, snippets, Learn From My Edits, Press Enter Command, Type It Out and typing speed, sounds, launch at login, recent transcripts.

---

## Verbaline vs. Wispr Flow

Wispr Flow is the polished commercial app that inspired this project. Here's an honest comparison, based on Wispr's public pricing page, help center and terms as of October 2026:

| | Verbaline | Wispr Flow |
|---|---|---|
| Where your speech is processed | On your Mac (Apple SpeechAnalyzer) | Wispr's cloud |
| AI cleanup | On your Mac (Apple Foundation Models) | Cloud models (Wispr's terms say it may use OpenAI or Anthropic models) |
| Account | None | Required |
| Price | Free, open source (MIT) | Free plan: 2,000 words/week on desktop (1,000 on mobile). Pro: $12–15/month |
| Command Mode (rewrite by voice) | Included, on-device | Pro or trial only; runs on Wispr's servers |
| Number guard for rates and amounts | Yes | Not mentioned in the Wispr pages we checked |
| Learns from your edits | Yes | Yes |
| Snippets, personal dictionary | Yes | Yes |
| Languages | English (US) | 100+ |
| Platforms | macOS 26+ on Apple Silicon | Mac, Windows, iPhone, Android |
| Meeting notes | No | Yes (Notetaker) |
| Polish and support | A personal project | A commercial product with a team behind it |

Sources: [pricing](https://wisprflow.ai/pricing), [data controls](https://wisprflow.ai/data-controls), [supported devices](https://docs.wisprflow.ai/articles/1036674442-supported-devices-and-system-requirements), [Command Mode help](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode), [terms](https://wisprflow.ai/terms-of-service). Verbaline is not affiliated with or endorsed by Wispr.

---

## Requirements

- A Mac with Apple Silicon (M1 or newer) running macOS 26 or later
- Xcode Command Line Tools (free from Apple; step 2 below installs them)
- English (US) speech
- **Apple Intelligence** turned on, for AI cleanup and Command Mode. Basic dictation works without it.

## Install

1. **Open Terminal.** Press ⌘ Space, type `Terminal`, and press Return.
2. **Install Apple's developer tools** (skip if you already have them). Paste this and press Return, then click **Install** in the window that appears and wait for it to finish:
   ```bash
   xcode-select --install
   ```
3. **Download and build Verbaline.** Paste this and press Return:
   ```bash
   git clone https://github.com/JLFinance25/Verbaline.git
   cd Verbaline
   ./build.sh --install     # builds and installs /Applications/Verbaline.app, then starts it
   ```
   A waveform icon appears in your menu bar when it's running.

### First-time setup

1. When macOS asks for the **Microphone**, click **Allow**.
2. Open **System Settings → Privacy & Security → Accessibility** and turn on **Verbaline**. If macOS asks for **Input Monitoring**, turn it on there too.
3. Open **System Settings → Keyboard** and set **"Press 🌐 key to"** to **Do Nothing**. Otherwise fn opens the emoji picker instead of starting dictation.
4. Click into any text box, hold **fn**, say a sentence, and let go. The first time can take a little longer while macOS downloads Apple's speech model.

| Permission | Why |
|---|---|
| Microphone | to hear you |
| Accessibility | to see the fn key, paste or type text, read your selection (Command Mode), and read the text box you pasted into (learning) |
| Input Monitoring | if macOS asks: to see the fn key |

### Keep permissions across rebuilds (recommended)

Apps you build yourself are "ad-hoc" signed, so macOS forgets their permissions every time you rebuild or update. To avoid that, run this once from the Verbaline folder:

```bash
scripts/make-signing-identity.sh
```

It creates a private certificate that can only sign apps on your Mac, saves it in your login keychain, and records its name in `local.env` (a settings file that stays on your Mac). It doesn't change any trust settings. Then run `./build.sh --install` again. The first build asks for keychain access to the certificate; choose **Always Allow**. To remove the certificate later, delete "Verbaline Local Signing" in Keychain Access.

## Update

In Terminal:

```bash
cd Verbaline
git pull
./build.sh --install
```

## Uninstall

1. Click the menu-bar icon → **Quit Verbaline**.
2. Drag **Verbaline** from Applications to the Trash.
3. To remove your history, dictionary and snippets too, delete the folder `~/Library/Application Support/Verbaline` (in Finder: Go → Go to Folder…).
4. Optional clean-up in Terminal: `defaults delete local.verbaline.app` removes its settings, and `tccutil reset All local.verbaline.app` removes its permissions. If you created the signing certificate, delete "Verbaline Local Signing" in Keychain Access.

## Troubleshooting

| What you see | What to do |
|---|---|
| Holding fn opens the emoji picker | Set **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**. |
| Nothing happens when you hold fn | Check the menu-bar icon's menu. If it says "Needs Accessibility permission" or "Needs Input Monitoring permission", turn Verbaline on in **System Settings → Privacy & Security**. If it's already on, switch it off and on again. |
| "Copied — turn on Accessibility for Verbaline to auto-paste" | Your text is on the clipboard; paste it with ⌘V. Turn on Accessibility (above) so it pastes by itself. |
| macOS asks for permissions again after every update | Do the one-time [signing step](#keep-permissions-across-rebuilds-recommended). |
| The menu says "AI Cleanup (Apple Intelligence unavailable…)" | Turn on Apple Intelligence in **System Settings → Apple Intelligence & Siri**. Apple Intelligence may not be available in every region or language. Basic dictation still works without it. |
| The first dictation is slow or says "Loading speech model…" | macOS is downloading Apple's speech model. Wait a minute and try again. |
| `./build.sh` fails with a compiler or SDK error | Install or update the Command Line Tools: run `xcode-select --install`, or check **System Settings → General → Software Update**. |

Still stuck? [Open an issue](https://github.com/JLFinance25/Verbaline/issues) with your macOS version, what you did, and what happened.

---

## Privacy

- **Audio stays in memory.** Recordings are never written to disk or sent anywhere.
- **No networking code.** On first launch Verbaline asks macOS to install Apple's English speech model if it's missing; macOS does the download. Apple Intelligence models are managed by macOS.
- **The key watcher** sees every key press system-wide, but only looks at which key it was, to spot fn, Esc and fn+key shortcuts. It never records keystrokes.
- **Password fields are skipped when the app marks them as password fields.** If you dictate into one, the text goes in but isn't saved to history or watched. Some apps, such as Chrome and Slack, don't tell macOS which box you're typing in, so Verbaline can't always tell. Don't dictate passwords.
- **What's stored** in `~/Library/Application Support/Verbaline/` (a folder only your account can open):
  - `history.jsonl`: your dictations and Command Mode results, in plain text, trimmed to the newest 2,000 entries once it passes 5,000. Clear it any time from the menu: **Recent → Clear History…**
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
- **Hardened runtime.** The app is built with macOS's hardened runtime, which makes it much harder for other programs to inject code into it and borrow its permissions.

See [SECURITY.md](SECURITY.md) for how to report a problem.

## Use it responsibly

- **AI output can be wrong.** Proofread anything important, especially Command Mode drafts.
- **The number guard has limits.** It checks numbers written in digits, not facts, claims, or numbers spelled out in words.
- **Don't use it unsupervised for high-stakes advice.** That includes financial, legal and medical advice. Apple's terms for its on-device model apply.
- **Not designed for regulated records.** History is saved as plain text on your Mac. Check your employer's rules before dictating client or customer information.
- **No warranty.** Verbaline is provided as-is; see [LICENSE](LICENSE).

---

## Tests

```bash
tests/run_all.sh mylabel     # builds a test version and runs every test; results in build/regress/mylabel/
```

- **Speech clips** are generated with macOS's built-in `say` voice. The first run may trigger macOS's one-time speech-model download.
- **Self-test windows:** a few tests briefly open a small window that closes by itself. The typing and press-enter tests send keystrokes only to their own window. The press-enter test briefly puts text on your clipboard and restores it.
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
| `src/Snippets.swift`, `src/SpokenFormatting.swift`, `src/PressEnter.swift`, `src/Spelling.swift` | snippets, spoken formatting, "press enter", and "spell" |
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

Apple, Mac, macOS, AirPods and Apple Intelligence are trademarks of Apple Inc. Wispr Flow is a product of its owner. Other names belong to their owners. Verbaline is an independent project, not affiliated with or endorsed by any of them.
