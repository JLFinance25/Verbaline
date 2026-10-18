#!/bin/bash
# Verbaline's full test suite. Builds the app and every module's test, runs them all, prints a pass/fail
# summary, and saves timing-free output to build/regress/<label>/ so two runs can be compared:
#   tests/run_all.sh before   ...change something...   tests/run_all.sh after
#   diff -r build/regress/before build/regress/after     (any difference = behavior changed)
# Usage: tests/run_all.sh [label] [--quick]
#   --quick  skips the tests that open windows, type, or use the mic (they need the screen unlocked)
# Exit code: 0 only if every test passed.
set -uo pipefail
cd "$(dirname "$0")/.."
LABEL="${1:-current}"; QUICK=0; [[ "${2:-}" == "--quick" || "${1:-}" == "--quick" ]] && QUICK=1
[[ "$LABEL" == "--quick" ]] && LABEL=current
OUT="build/regress/$LABEL"
BIN="build/regress/bin"
rm -rf "$OUT"; mkdir -p "$OUT" "$BIN"
SW=(swiftc -swift-version 5 -O -target arm64-apple-macos26.0 -parse-as-library)
APPLE=tests/support/AppleTranscriber.swift   # only the gate/dictionary tests' own comparisons use it

tests/make_test_audio.sh > /dev/null || exit 1
echo "▶ compiling"
"${SW[@]}" src/TextCleaner.swift tests/cleaner_test.swift -o "$BIN/cleaner_test" || exit 1
"${SW[@]}" src/SpeechGate.swift $APPLE tests/gate_test.swift -o "$BIN/gate_test" || exit 1
"${SW[@]}" $APPLE src/PersonalDictionary.swift tests/dictionary_test.swift -o "$BIN/dictionary_test" || exit 1
"${SW[@]}" src/TextInserter.swift src/AXText.swift tests/clipboard_test.swift -o "$BIN/clipboard_test" || exit 1
"${SW[@]}" src/TextCleaner.swift tests/text_fixes_test.swift -o "$BIN/text_fixes_test" || exit 1
"${SW[@]}" src/TextCleaner.swift src/PersonalDictionary.swift src/Snippets.swift src/SpokenFormatting.swift src/PressEnter.swift src/Spelling.swift \
  src/PromptBoost.swift src/TextPipeline.swift tests/formatting_test.swift -o "$BIN/formatting_test" || exit 1
"${SW[@]}" src/EditWatcher.swift src/AXText.swift src/PersonalDictionary.swift tests/edit_watcher_test.swift -o "$BIN/edit_watcher_test" || exit 1
"${SW[@]}" src/EditLearner.swift tests/edit_learner_test.swift -o "$BIN/edit_learner_test" || exit 1
"${SW[@]}" src/CommandMode.swift tests/command_mode_test.swift -o "$BIN/command_mode_test" || exit 1
"${SW[@]}" src/TextTyper.swift tests/typer_test.swift -o "$BIN/typer_test" || exit 1
"${SW[@]}" src/PressEnter.swift tests/press_enter_test.swift -o "$BIN/press_enter_test" || exit 1
"${SW[@]}" src/Spelling.swift tests/spelling_test.swift -o "$BIN/spelling_test" || exit 1
"${SW[@]}" src/MeetingTypes.swift src/MeetingSummarizer.swift tests/meeting_summarizer_test.swift -o "$BIN/meeting_summarizer_test" || exit 1
"${SW[@]}" src/History.swift src/Stats.swift tests/stats_test.swift -o "$BIN/stats_test" || exit 1
"${SW[@]}" src/PromptBoost.swift tests/prompt_boost_test.swift -o "$BIN/prompt_boost_test" || exit 1
"${SW[@]}" src/Overlay.swift tests/overlay_test.swift -o "$BIN/overlay_test" || exit 1
"${SW[@]}" src/AppStyles.swift tests/app_styles_test.swift -o "$BIN/app_styles_test" || exit 1
"${SW[@]}" src/ModelDownloader.swift tests/support/model_paths_stub.swift tests/model_download_test.swift -o "$BIN/model_download_test" || exit 1
WH="$(brew --prefix whisper-cpp)"; GG="$(brew --prefix ggml)"
"${SW[@]}" -import-objc-header bridging.h -Xcc -I"$WH/include" -Xcc -I"$GG/include" -L"$WH/lib" -lwhisper -L"$GG/lib" -lggml \
  -Xlinker -rpath -Xlinker "$WH/lib" src/WhisperTranscriber.swift src/WhisperEngine.swift tests/engine_test.swift -o "$BIN/engine_test" || exit 1
"${SW[@]}" -import-objc-header bridging.h -Xcc -I"$WH/include" -Xcc -I"$GG/include" -L"$WH/lib" -lwhisper -L"$GG/lib" -lggml \
  -Xlinker -rpath -Xlinker "$WH/lib" src/WhisperTranscriber.swift src/WhisperEngine.swift src/SpeechGate.swift tests/music_gate_test.swift \
  -o "$BIN/music_gate_test" || exit 1
"${SW[@]}" -import-objc-header bridging.h -Xcc -I"$WH/include" -Xcc -I"$GG/include" -L"$WH/lib" -lwhisper -L"$GG/lib" -lggml \
  -Xlinker -rpath -Xlinker "$WH/lib" src/WhisperTranscriber.swift src/WhisperEngine.swift src/SpeechGate.swift src/MeetingTypes.swift \
  src/MeetingTranscriber.swift tests/meeting_transcriber_test.swift -o "$BIN/meeting_transcriber_test" || exit 1
"${SW[@]}" -import-objc-header bridging.h -Xcc -I"$WH/include" -Xcc -I"$GG/include" -L"$WH/lib" -lwhisper -L"$GG/lib" -lggml \
  -Xlinker -rpath -Xlinker "$WH/lib" src/WhisperTranscriber.swift src/WhisperEngine.swift src/SpeechGate.swift src/MeetingTypes.swift \
  src/MeetingTranscriber.swift src/MeetingSummarizer.swift tests/meeting_pipeline_test.swift -o "$BIN/meeting_pipeline_test" || exit 1
"${SW[@]}" src/MusicDucker.swift src/AudioRecorder.swift src/MicCapture.swift tests/ducker_test.swift -o "$BIN/ducker_test" || exit 1
"${SW[@]}" src/MeetingTypes.swift src/MeetingAudio.swift src/SystemAudioTap.swift src/MicCapture.swift src/AudioRecorder.swift \
  tests/meeting_audio_test.swift -o "$BIN/meeting_audio_test" || exit 1
"${SW[@]}" -import-objc-header bridging.h -Xcc -I"$WH/include" -Xcc -I"$GG/include" -L"$WH/lib" -lwhisper -L"$GG/lib" -lggml \
  -Xlinker -rpath -Xlinker "$WH/lib" src/WhisperTranscriber.swift src/WhisperEngine.swift src/MeetingTypes.swift src/MeetingAudio.swift \
  src/SystemAudioTap.swift src/MicCapture.swift src/AudioRecorder.swift tests/call_mode_test.swift -o "$BIN/call_mode_test" || exit 1
VERBALINE_TESTING=1 ./build.sh > "$OUT/build.raw.txt" 2>&1 || { cat "$OUT/build.raw.txt"; exit 1; }
APPDIR="${VERBALINE_BUILD_DIR:-$HOME/Library/Caches/Verbaline-build.noindex}/Verbaline.app"
APPBIN="$APPDIR/Contents/MacOS/Verbaline"

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
run press_enter "$BIN/press_enter_test"
run spelling "$BIN/spelling_test"
# Meeting audio: --quick runs only the parts with no sound or mic; the full run also plays two quiet tones
# (one app's tap must hear only its own) and opens the mic from a helper process (meeting start/end detection).
if [[ $QUICK == 1 ]]; then run meeting_audio "$BIN/meeting_audio_test" --quick; else run meeting_audio "$BIN/meeting_audio_test"; fi
# AirPods call mode: plays a clip and opens the mic, so full run only; skips itself without Bluetooth headphones.
[[ $QUICK == 1 ]] || run call_mode "$BIN/call_mode_test" build/test_audio/long.wav
run stats "$BIN/stats_test"
run prompt_boost "$BIN/prompt_boost_test" --ai
run overlay "$BIN/overlay_test"
run app_styles "$BIN/app_styles_test"
run model_download "$BIN/model_download_test"
run cleaner "$BIN/cleaner_test" --prewarm
QUICKARG=(); [[ $QUICK == 1 ]] && QUICKARG=(--quick)
run meeting_summarizer "$BIN/meeting_summarizer_test" ${QUICKARG[@]+"${QUICKARG[@]}"}   # on-device model: ~20 s; the 60-minute meeting (~90 s) only in the full run
run gate env GATE_SEED=7 GATE_SKIP_STT=1 "$BIN/gate_test"
run dictionary "$BIN/dictionary_test" --skip-stt
run engine "$BIN/engine_test" build/test_audio/correction_wait.wav
run meeting_transcriber "$BIN/meeting_transcriber_test" build/transcriber_test/t3.wav build/test_audio/long.wav build/transcriber_test/t1.wav \
  build/transcriber_test/t2.wav build/messy.wav   # fake-transcriber logic, then a ~3 min joined recording: chunked vs one-go Whisper
run meeting_pipeline "$BIN/meeting_pipeline_test" build/meeting   # two-voice meeting -> live lines -> note -> saved and loaded back
A=build/test_audio
run spoken "$APPBIN" --selftest $A/email_newline.wav $A/bullets.wav $A/snippet.wav $A/new_line_of_loans.wav \
  $A/spell_heloc.wav $A/spell_name.wav $A/spell_paused.wav
run pipeline "$APPBIN" --selftest build/transcriber_test/t1.wav build/transcriber_test/t2.wav build/transcriber_test/t3.wav \
  build/messy.wav build/transcriber_test/silence.wav $A/long.wav
run prompt_spoken "$APPBIN" --selftest $A/prompt_boost.wav $A/prompt_boost_midsentence.wav
run fixes "$APPBIN" --selftest $A/ums.wav $A/correction_wait.wav $A/correction_mean.wav $A/correction_sorry.wav \
  $A/correction_actually.wav $A/names.wav
# Stress: the same clips 5 times in one process. Output must be identical every time, and nothing may hang.
run stress "$APPBIN" --selftest $(for i in 1 2 3 4 5; do printf '%s ' $A/ums.wav $A/long.wav build/transcriber_test/silence.wav $A/spell_heloc.wav; done)

if [[ $QUICK == 0 ]]; then
  echo "▶ typing"   # types only into its own test window (posted to that process), then reads it back
  open -W -n "$APPDIR" --args --typetest "$PWD/$OUT/typing.raw.txt"
  echo "▶ no text box"   # its own window: pastes into a field; with nothing focused, words stay on the clipboard
  open -W -n "$APPDIR" --args --boxtest "$PWD/$OUT/box.json"
  { cat "$OUT/box.json"; echo; python3 -c "import json,sys; d=json.load(open(sys.argv[1])); bad=[k for k,v in d.items() if v is False]; print('FAIL  box: '+', '.join(bad) if bad else 'PASS  box')" "$OUT/box.json"; } > "$OUT/box.raw.txt" 2>&1
  echo "▶ press enter"   # pastes into its own test window, presses Return there, reads it back
  open -W -n "$APPDIR" --args --entertest "$PWD/$OUT/enter.raw.txt"
  echo "▶ panel"   # opens the real menu bar panel in a test copy of the app, presses its buttons, checks placement
  open -W -n "$APPDIR" --args --paneltest "$PWD/$OUT/panel.json"
  { cat "$OUT/panel.json"; echo; python3 -c "import json,sys; d=json.load(open(sys.argv[1])); bad=[k for k,v in d.items() if v is False]; print('FAIL  panel: '+', '.join(bad) if bad else 'PASS  panel')" "$OUT/panel.json"; } > "$OUT/panel.raw.txt" 2>&1
  echo "▶ notes window"   # opens the notes window with sample data in light and dark, saves screenshots to $OUT/notes_window/
  mkdir -p "$PWD/$OUT/notes_window"
  open -W -n "$APPDIR" --args --noteswindowtest "$PWD/$OUT/notes_window"
  { cat "$OUT/notes_window/report.json" 2>&1; echo; python3 - "$OUT/notes_window/report.json" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception as e: print("FAIL  notes window: no report (app crashed or hung?) - %s" % e); sys.exit()
need = ["windowExists", "lookSwitchChangesWindow", "autoFollowsMac"] + ["%s.%s" % (m, k) for m in ("light", "dark")
        for k in ("live", "empty", "past", "note", "insights", "popup", "popupExists", "popupEnded", "popupReady")]
bad = [k for k in need if d.get(k) is not True] + ([] if d.get("tabCount") == 3 else ["tabCount"])
print("FAIL  notes window: " + ", ".join(bad) if bad else "PASS  notes window")
PY
  } > "$OUT/notes_window.raw.txt" 2>&1
  echo "▶ music"   # plays speech and a sung line on the speakers at full and half volume, records the mic,
                    # then checks the music gate drops it and keeps a voice mixed on top; then the volume ducker
  ORIG_VOL=$(osascript -e 'output volume of (get volume settings)')
  trap "osascript -e 'set volume output volume $ORIG_VOL'" EXIT
  mkdir -p build/leak
  [[ -f build/leak/podcast.wav ]] || say -o build/leak/podcast.wav --file-format=WAVE --data-format=LEI16@16000 "Welcome back to the show. Today we are talking about how interest rates move, and why the bond market matters for anyone buying a home this year."
  [[ -f build/leak/song.wav ]] || say -v "Good News" -o build/leak/song.wav --file-format=WAVE --data-format=LEI16@16000 "Oh baby I just want to dance with you all night long under the summer moon"
  for vol in 69 34; do osascript -e "set volume output volume $vol"
    for clip in podcast song; do open -W -n "$APPDIR" --args --leaktest "$PWD/build/leak/$clip-$vol.json" "$PWD/build/leak/$clip.wav"; done
  done
  osascript -e "set volume output volume $ORIG_VOL"
  # Report only: with the lid open, MacBook speakers reach the mic as loudly as a voice even at half volume,
  # so some leaks are expected physics, not a regression. Compare runs with diff instead.
  run music_gate env MGT_REPORT_ONLY=1 "$BIN/music_gate_test" build/leak build/test_audio/correction_wait.wav build/transcriber_test/t1.wav
  afplay -v 0.05 build/transcriber_test/t3.wav & PLAYER=$!; sleep 0.3   # something quietly playing, for the ducker
  run ducker "$BIN/ducker_test"
  kill $PLAYER 2>/dev/null
  echo "▶ mic"   # launched through `open` so it runs with Verbaline's own microphone permission
  open -W -n "$APPDIR" --args --mictest "$PWD/$OUT/mic.raw.txt" builtin
fi

# Strip timings and room-noise levels so only behavior differences show up in a diff.
for f in "$OUT"/*.raw.txt; do
  grep -vE '^(ggml_|whisper_|load_backend|system_info)' "$f" | sed -E -e 's/[0-9]+(\.[0-9]+)? ?(ms|s)([^a-zA-Z]|$)/<t>\3/g' \
         -e 's/"(peak|rmsDb|seconds|samples|buffers|firstBufferMs|secondFirstBufferMs|startCallMs)" : [-0-9.e]+/"\1" : <v>/' \
         -e 's/\([0-9]+ reads\)/(<n> reads)/' -e 's/[0-9.]+x realtime/<x> realtime/' \
         -e 's/latency median ms : .*/latency median ms : <t>/' -e 's/^( +ms +:).*/\1 <t>/' -e 's/[-+]<t>/±<t>/g' \
         -e 's/^([a-z0-9]+ +(yes|no) +(true|false) +[0-9.]+ +[0-9.]+ +)[0-9.]+/\1<t>/' > "${f%.raw.txt}.txt"
done

# Stress check: each clip's cleaned text must be the same on all 5 passes.
STRESS_BAD=$(grep "^cleaned" "$OUT/stress.txt" | sort | uniq -c | awk '$1 != 5' | wc -l | tr -d ' ')

echo
echo "===== summary ($OUT)"
FAILED=0
for f in "$OUT"/*.raw.txt; do
  name=$(basename "$f" .raw.txt); [[ $name == build ]] && continue
  code=$(grep -h "^exit=" "$f" | tail -1 | cut -d= -f2)
  fails=$(grep -cE "^ *(FAIL|✗)|SELFTEST ERROR|GGML_ASSERT|Fatal error" "$f")
  if [[ "${code:-0}" != 0 || $fails != 0 ]]; then echo "  FAIL  $name (exit=${code:-?}, $fails failing lines)"; FAILED=1
  elif grep -q "^SKIP" "$f"; then echo "  ok    $name — SKIPPED: $(grep -h "^SKIP" "$f" | sed -E 's/^SKIP +//' | paste -sd ';' -)"
  else echo "  ok    $name"; fi
done
if [[ $STRESS_BAD == 0 ]]; then echo "  ok    stress: same output on all 5 passes"; else echo "  FAIL  stress: $STRESS_BAD outputs changed between passes"; FAILED=1; fi
if [[ $QUICK == 0 ]]; then
  # Real sound, not just zeros: at least 1 s of samples with a non-zero peak. (The built-in-mic path
  # doesn't fill in "buffers", so that number can't be used.)
  if grep -qE '"samples" : [0-9]{5,}' "$OUT/mic.raw.txt" && ! grep -qE '"peak" : 0(\.0+)?,' "$OUT/mic.raw.txt"; then
    echo "  ok    mic: audio arriving"
  else echo "  FAIL  mic: NO AUDIO"; FAILED=1; fi
fi
exit $FAILED
