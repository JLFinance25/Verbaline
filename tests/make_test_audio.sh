#!/bin/bash
# Generates the speech clips the test suite uses, with macOS's built-in `say` voice (nothing is downloaded).
# Output goes to build/ (not checked in).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/transcriber_test build/test_audio
fmt=(--file-format=WAVE --data-format=LEI16@16000)
clip() { [[ -f "$1" ]] || say -o "$1" "${fmt[@]}" "$2"; }

clip build/transcriber_test/t1.wav "Hey team, let's meet tomorrow at three to review the quarterly numbers. Can you send me the slides beforehand?"
clip build/transcriber_test/t2.wav "The current thirty year fixed mortgage rate is around six point five percent, and your debt to income ratio needs to stay under forty three percent."
clip build/transcriber_test/t3.wav "Thanks for reaching out about the refinance. I looked over your preapproval letter, and everything seems in order. Before we lock the rate, I need your last two pay stubs, your most recent bank statements, and a copy of your driver's license. Once I have those, I can send everything to underwriting, and we should hear back within about two business days. Let me know if you have any questions in the meantime."
clip build/messy.wav "um so I wanted to follow up on the uh the refinance. let's talk at two, actually make that four o'clock. three things, first send me your pay stubs, second your bank statements, third your license."
clip build/test_audio/email_newline.wav "Hi Sarah, new line. Thanks for sending the documents. New paragraph. Best, Alex"
clip build/test_audio/bullets.wav "Here is what I need. Bullet point. Your last two pay stubs. Bullet point. Your bank statements."
clip build/test_audio/snippet.wav "Thanks for your time. Insert test snippet."
clip build/test_audio/new_line_of_loans.wav "We are launching a new line of loans next month."
clip build/test_audio/spell_heloc.wav "Spell H E L O C."
clip build/test_audio/spell_name.wav "Please email spell K E R G E R about the appraisal."
clip build/test_audio/spell_paused.wav "Spell [[slnc 300]] N [[slnc 250]] M [[slnc 250]] L [[slnc 250]] S"

# 2.7 s of silence
[[ -f build/transcriber_test/silence.wav ]] || python3 - <<'PY'
import wave
w = wave.open("build/transcriber_test/silence.wav", "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b"\x00\x00" * int(16000 * 2.7)); w.close()
PY
echo "Test audio ready in build/"
