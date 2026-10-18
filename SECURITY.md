# Security

## Reporting a vulnerability

Please report security issues **privately**: open this repository's **Security** tab and choose **Report a vulnerability**. Please don't open a public issue for security problems.

Include what you found, how to reproduce it, and your macOS version.

## What Verbaline can access

Verbaline asks for powerful permissions, so here is exactly what it does with them.

- **Microphone**
  - On only while you dictate: while you hold fn, or in hands-free mode from the double-tap until you tap fn again.
  - A quick single tap opens the mic for under a second, and that audio is thrown away.
  - Audio stays in memory and is never saved or sent.
- **Accessibility and Input Monitoring**
  - **Key watching:** an event tap sees every key press system-wide, but reads only key codes and the fn/Control modifier state, to spot fn, Esc and fn+key shortcuts. It swallows only the fn key, plus Esc while recording or typing. Keystrokes are never recorded.
  - **Keystrokes it sends:** ⌘V to paste, ⌘C to read a selection when an app doesn't share it, one keystroke per character in Type It Out mode, and Return only when you say "press enter" on its own.
  - **Text it reads:**
    - after a paste, the text box that holds the pasted text, for Learn From My Edits;
    - your selection, for Command Mode;
    - the character just before the cursor, for smart spacing.
    - whether the cursor is in something you can type into, so your words stay on the clipboard when there's no text box;
    - the name of the app in front and, for web browsers, the title of the front window, to pick a writing style (never saved).
  - **Password fields** are skipped when the app marks them as password fields: they aren't read, and dictation into them isn't saved. Some apps (Electron apps in particular) don't report which field has focus, so this check can miss; don't dictate secrets.
  - **Electron apps:** sets `AXManualAccessibility` on them so their text boxes can be read.
- **System Audio Recording:** not used by dictation. macOS asks for it only if you turn on the experimental meeting notes (below).
- **Speaker volume:** while you dictate with sound playing on the Mac's built-in speakers, Verbaline turns the volume down (50% by default) and puts it back afterwards. Turn this off with **Ignore Mac audio**.
- **Network:** one use only. On first launch, when you click **Download the speech model** in the menu bar panel, it downloads the Whisper model file (1.6 GB) from the whisper.cpp project's Hugging Face page. The file must match the published size and SHA-256 or it's thrown away. Nothing about you or your speech is sent anywhere.
- **Local files:** `~/Library/Application Support/Verbaline/` holds history, dictionary, snippets, usage counts, status and the speech model. The folder is readable only by your account.
- **Code integrity:** built with the hardened runtime. Library validation is turned off so the app can load whisper.cpp from Homebrew, which means any library at that Homebrew path is trusted. Test-only command-line modes are compiled out of normal builds.
- **Experimental meeting notes:** the code includes a meeting-notes mode that is **off by default** and not supported yet. Only if you turn it on (`defaults write local.verbaline.app meetingNotesEnabled -bool true`) does it record the other side of a call (using System Audio Recording) plus your microphone, and save a transcript and summary as Markdown files in `~/Documents/Verbaline Notes/`. Recording a call can require everyone's consent where you live; that's your responsibility.

## Known limitations

- **Command Mode:** passes selected text to an on-device language model. Text that contains instructions is usually treated as content, not obeyed, but this is not guaranteed. The model has no tools and no network access, and its output only replaces your selection, so ⌘Z undoes it.
- **"Make this prompt better" and AI cleanup:** both use Apple's on-device model, which can occasionally reword things. Read AI-written text before you send it.
- **History:** `history.jsonl` keeps dictations and Command Mode results in plain text until you clear it (menu: **Recent → Clear History…**). At launch, a history over 5,000 entries is cut to the newest 2,000.
- **Clipboard copy:** when Command Mode falls back to ⌘C, a clipboard manager may record the copied selection.
- **No-text-box copies:** when there's no text box, your dictation is left on the clipboard on purpose, so a clipboard manager may record it.
