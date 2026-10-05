#!/bin/bash
# Regression suite: builds the app and every module's test harness, runs them all, and saves
# timing-normalized output to build/regress/<label>/ so two runs can be compared with:
#   diff -r build/regress/before build/regress/after
# Usage: tests/run_all.sh <label>
set -uo pipefail
cd "$(dirname "$0")/.."
LABEL="${1:-current}"
OUT="build/regress/$LABEL"
BIN="build/regress/bin"
rm -rf "$OUT"; mkdir -p "$OUT" "$BIN"
SW=(swiftc -swift-version 5 -O -target arm64-apple-macos26.0 -parse-as-library)

tests/make_test_audio.sh > /dev/null || exit 1
echo "▶ compiling"
"${SW[@]}" src/TextCleaner.swift tests/cleaner_test.swift -o "$BIN/cleaner_test" || exit 1
"${SW[@]}" src/AppleTranscriber.swift tests/transcribe_test.swift -o "$BIN/transcribe_test" || exit 1
"${SW[@]}" src/SpeechGate.swift src/AppleTranscriber.swift tests/gate_test.swift -o "$BIN/gate_test" || exit 1
"${SW[@]}" src/AppleTranscriber.swift src/PersonalDictionary.swift tests/dictionary_test.swift -o "$BIN/dictionary_test" || exit 1
"${SW[@]}" src/TextInserter.swift src/AXText.swift tests/clipboard_test.swift -o "$BIN/clipboard_test" || exit 1
"${SW[@]}" src/TextCleaner.swift tests/text_fixes_test.swift -o "$BIN/text_fixes_test" || exit 1
"${SW[@]}" src/TextCleaner.swift src/PersonalDictionary.swift src/Snippets.swift src/SpokenFormatting.swift \
  src/TextPipeline.swift tests/formatting_test.swift -o "$BIN/formatting_test" || exit 1
"${SW[@]}" src/EditWatcher.swift src/AXText.swift src/PersonalDictionary.swift tests/edit_watcher_test.swift -o "$BIN/edit_watcher_test" || exit 1
"${SW[@]}" src/EditLearner.swift tests/edit_learner_test.swift -o "$BIN/edit_learner_test" || exit 1
"${SW[@]}" src/CommandMode.swift tests/command_mode_test.swift -o "$BIN/command_mode_test" || exit 1
"${SW[@]}" src/TextTyper.swift tests/typer_test.swift -o "$BIN/typer_test" || exit 1
VERBALINE_TESTING=1 ./build.sh > "$OUT/build.raw.txt" 2>&1 || { cat "$OUT/build.raw.txt"; exit 1; }
APPDIR="$HOME/Library/Caches/Verbaline-build.noindex/Verbaline.app"

run() {
  local name=$1; shift
  echo "▶ $name"
  "$@" > "$OUT/$name.raw.txt" 2>&1
  echo "exit=$?" >> "$OUT/$name.raw.txt"
}
run clipboard "$BIN/clipboard_test"
run text_fixes "$BIN/text_fixes_test"
run formatting "$BIN/formatting_test"
run edit_watcher "$BIN/edit_watcher_test"
run edit_learner "$BIN/edit_learner_test"
run command_mode "$BIN/command_mode_test"
run typer "$BIN/typer_test"
run cleaner "$BIN/cleaner_test" --prewarm
run transcribe "$BIN/transcribe_test" build/transcriber_test/t1.wav build/transcriber_test/t2.wav \
  build/transcriber_test/t3.wav build/transcriber_test/silence.wav
run gate env GATE_SEED=7 "$BIN/gate_test"
run dictionary "$BIN/dictionary_test"
run spoken "$APPDIR/Contents/MacOS/Verbaline" --selftest build/test_audio/email_newline.wav build/test_audio/bullets.wav \
  build/test_audio/snippet.wav build/test_audio/new_line_of_loans.wav
run pipeline "$APPDIR/Contents/MacOS/Verbaline" --selftest build/gate_test/c_raw.wav build/gate_test/d_raw.wav \
  build/dictionary_test/c1.wav build/messy.wav build/transcriber_test/t3.wav build/transcriber_test/silence.wav

echo "▶ typing"   # types only into its own test window (posted to that process), then reads it back
open -W -n "$APPDIR" --args --typetest "$PWD/$OUT/typing.raw.txt"
echo "▶ mic"   # launched through `open` so it runs with Verbaline's own microphone permission
open -W -n "$APPDIR" --args --mictest "$PWD/$OUT/mic.raw.txt" builtin

# Strip timings and room-noise levels so only behavior differences show up in a diff.
for f in "$OUT"/*.raw.txt; do
  sed -E -e 's/[0-9]+(\.[0-9]+)? ?(ms|s)([^a-zA-Z]|$)/<t>\3/g' \
         -e 's/"(peak|rmsDb|seconds|samples|buffers|firstBufferMs|secondFirstBufferMs|startCallMs)" : [-0-9.e]+/"\1" : <v>/' \
         -e 's/\([0-9]+ reads\)/(<n> reads)/' -e 's/[0-9.]+x realtime/<x> realtime/' \
         -e 's/latency median ms : .*/latency median ms : <t>/' -e 's/^( +ms +:).*/\1 <t>/' -e 's/[-+]<t>/±<t>/g' \
         -e 's/^([a-z0-9]+ +(yes|no) +(true|false) +[0-9.]+ +[0-9.]+ +)[0-9.]+/\1<t>/' "$f" > "${f%.raw.txt}.txt"
done
grep -h "^exit=" "$OUT"/*.raw.txt | sort | uniq -c
grep -q '"buffers" : [1-9]' "$OUT/mic.raw.txt" && echo "mic: audio arriving" || echo "mic: NO AUDIO"
echo "Results in $OUT"
