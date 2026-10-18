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

# Verbaline additions: fillers and self-corrections, made-up names, a long hands-free style ramble.
clip build/test_audio/ums.wav "So um I was thinking uh we should like move the closing to Thursday."
clip build/test_audio/correction_wait.wav "Send the disclosure to John, no wait, to Sarah, and cc the processor."
clip build/test_audio/correction_mean.wav "Call Mike tomorrow, I mean Friday, about the appraisal."
clip build/test_audio/correction_sorry.wav "Email the appraiser, sorry, the underwriter, about the condo questionnaire."
clip build/test_audio/correction_actually.wav "The rate is six and a half percent, no actually six point seven five percent, on a thirty year fixed."
clip build/test_audio/names.wav "Tell Gwendolyn Achterberg her NMLS number is wrong on the Loan Estimate, and ask Kwabena Mensah for the W-2."
clip build/test_audio/long.wav "Okay so here is the plan for this week. Monday I need to call the title company about the payoff letter and confirm the wire instructions by phone, never by email. Tuesday the appraisal is scheduled for ten in the morning, and the borrower should leave the gate unlocked. Wednesday we review the conditions from underwriting, which are the gift letter, two months of bank statements, and a written explanation for the large deposit in March. Thursday is the rate lock deadline, so if the borrower has not decided by noon we float. Friday I am out, so send anything urgent to the processor."

clip build/test_audio/prompt_boost.wav "Write me a follow up email to a borrower about their missing W-2, the closing is on the 14th. Make this prompt better."
clip build/test_audio/prompt_boost_midsentence.wav "We should make this prompt better than the old one before we send it to the team."

# 2.7 s of silence
[[ -f build/transcriber_test/silence.wav ]] || python3 - <<'PY'
import wave
w = wave.open("build/transcriber_test/silence.wav", "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b"\x00\x00" * int(16000 * 2.7)); w.close()
PY
echo "Test audio ready in build/"

# Meeting notetaker end-to-end: a short two-person mortgage meeting, one file per side (made-up people and numbers).
mkdir -p build/meeting
clip2() { [[ -f "$1" ]] || say -v "$2" -o "$1" "${fmt[@]}" "$3"; }
clip2 build/meeting/you1.wav Samantha "Hi Maria, thanks for making time today. What price range are you looking at for the new house?"
clip2 build/meeting/them1.wav Daniel "We are hoping to stay under four hundred twenty five thousand, and we have saved about eighty five thousand for the down payment."
clip2 build/meeting/you2.wav Samantha "That works. Please send me your last two pay stubs and your W-2s by Friday, and I will send you the document checklist tonight."
clip2 build/meeting/them2.wav Daniel "Sounds good. We would like to close by the middle of January if possible."
