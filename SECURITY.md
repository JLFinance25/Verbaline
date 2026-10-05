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
  - **Key watching:** an event tap sees every key press system-wide, but reads only the key code, to spot fn, Esc and fn+key shortcuts. It swallows only the fn key, plus Esc while recording or typing. Keystrokes are never recorded.
  - **Keystrokes it sends:** ⌘V to paste, ⌘C to read a selection when an app doesn't share it, and one keystroke per character in Type It Out mode.
  - **Text it reads:**
    - after a paste, the text box that holds the pasted text, for Learn From My Edits;
    - your selection, for Command Mode;
    - the character just before the cursor, for smart spacing.
  - **Password fields** are skipped when the app marks them as password fields: they aren't read, and dictation into them isn't saved. Some apps (such as Chrome and Slack) don't report which field has focus, so this check can miss; don't dictate secrets.
  - **Electron apps:** sets `AXManualAccessibility` on them so their text boxes can be read.
- **Network:** Verbaline has no networking code. It asks macOS to install Apple's speech model if missing.
- **Local files:** `~/Library/Application Support/Verbaline/` holds history, dictionary, snippets and status. The folder is readable only by your account.
- **Code integrity:** built with the hardened runtime. Test-only command-line modes are compiled out of normal builds.

## Known limitations

- **Command Mode:** passes selected text to an on-device language model. Text that contains instructions is usually treated as content, not obeyed, but this is not guaranteed. The model has no tools and no network access, and its output only replaces your selection, so ⌘Z undoes it.
- **History:** `history.jsonl` keeps dictations and Command Mode results in plain text until you delete it, or until it's trimmed to the newest 2,000 entries.
- **Clipboard copy:** when Command Mode falls back to ⌘C, a clipboard manager may record the copied selection.
