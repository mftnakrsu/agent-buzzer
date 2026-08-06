#!/usr/bin/env bash
#
# agent-buzzer test suite.
#
# The silence rules are the product — a buzzer that beeps after every one-line
# reply gets uninstalled within an hour — so they are what gets tested here,
# along with the two rules that matter more than any feature: hooks stay silent
# on stdout, and hooks never block.
#
# No dependencies, no bats, no audio device. Runs the same on macOS, Linux and
# Git Bash:
#
#     ./tests/run.sh              # all tests
#     ./tests/run.sh quiet        # only tests whose name matches "quiet"
#
# How it fakes the outside world (all of these are read by buzzer.sh itself):
#   BUZZER_HOME           throwaway state directory per test
#   BUZZER_DRY_RUN=1      record what would play into $BUZZER_HOME/played
#   BUZZER_FAKE_FRONTMOST which app is frontmost; "-" means undetectable
#   BUZZER_FAKE_NOW       the wall clock, as HH:MM

# Every test function is called indirectly by run_test, which shellcheck cannot
# see, so its "never invoked" / "unreachable" checks do not apply here. Both
# codes are listed because shellcheck renamed this diagnostic: 0.9 reports
# SC2317, 0.10+ reports SC2329, and CI runs an older build than most laptops.
# shellcheck disable=SC2329,SC2317

set -u

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
BUZZER="$ROOT/buzzer.sh"
FILTER="${1-}"

PASSED=0
FAILED=0
FAILED_LIST=""
ERRORS=""
STATE=""

# Per-test knobs, reset by setup().
TP=""      # TERM_PROGRAM
FF="-"     # frontmost app; "-" = could not be detected
NOW=""     # fake HH:MM, empty = real clock

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

red() { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
dim() { printf '\033[2m%s\033[0m' "$1"; }

setup() {
  STATE=$(mktemp -d "${TMPDIR:-/tmp}/buzzer-test.XXXXXX")
  mkdir -p "$STATE/marks"
  TP=""
  FF="-"
  NOW=""
  # An explicit config, so tests never depend on the machine's system sounds.
  cat >"$STATE/config" <<EOF
enabled=true
threshold_seconds=30
volume=0.7
quiet_hours=false
quiet_start=23:00
quiet_end=08:00
terminal_app=
done_enabled=true
done_sound=$ROOT/sounds/bird.wav
done_volume=
done_repeat=1
waiting_enabled=true
waiting_sound=$ROOT/sounds/bird.wav
waiting_volume=
waiting_repeat=2
error_enabled=true
error_sound=$ROOT/sounds/bird.wav
error_volume=
error_repeat=1
subagent_enabled=true
subagent_sound=$ROOT/sounds/bird.wav
subagent_volume=0.35
subagent_repeat=1
EOF
}

teardown() {
  [ -n "$STATE" ] && [ -d "$STATE" ] && rm -rf "$STATE"
  STATE=""
}

fail_with() {
  ERRORS="$ERRORS
    $1"
}

run_test() {
  local name="$1" fn="$2"
  case "$name" in
    *"$FILTER"*) ;;
    *) return 0 ;;
  esac
  ERRORS=""
  setup
  "$fn"
  teardown
  if [ -z "$ERRORS" ]; then
    PASSED=$((PASSED + 1))
    printf '  %s %s\n' "$(green ok)" "$name"
  else
    FAILED=$((FAILED + 1))
    FAILED_LIST="$FAILED_LIST
  $name"
    printf '  %s %s%s\n' "$(red FAIL)" "$name" "$ERRORS"
  fi
}

# ---------------------------------------------------------------------------
# Driving buzzer.sh
# ---------------------------------------------------------------------------

# hook <event> [session_id] — feeds a realistic hook payload on stdin.
hook() {
  local event="$1" sid="${2-}"
  printf '{"session_id":"%s","transcript_path":"/tmp/t.jsonl","hook_event_name":"Stop"}' "$sid" |
    env BUZZER_HOME="$STATE" BUZZER_DRY_RUN=1 TERM_PROGRAM="$TP" \
      BUZZER_FAKE_FRONTMOST="$FF" BUZZER_FAKE_NOW="$NOW" \
      bash "$BUZZER" hook "$event"
}

cli() {
  env BUZZER_HOME="$STATE" BUZZER_DRY_RUN=1 TERM_PROGRAM="$TP" \
    BUZZER_FAKE_FRONTMOST="$FF" BUZZER_FAKE_NOW="$NOW" \
    bash "$BUZZER" "$@"
}

# mark_ago <session_id> <seconds> — pretend the turn started N seconds ago.
mark_ago() {
  mkdir -p "$STATE/marks"
  printf '%s\n' "$(($(date +%s) - $2))" >"$STATE/marks/$1"
}

set_cfg() {
  printf '%s=%s\n' "$1" "$2" >>"$STATE/config"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert_played() {
  local event="${1-}"
  if [ ! -s "$STATE/played" ]; then
    fail_with "expected a sound to play, nothing did (reason: $(last_reason))"
    return
  fi
  if [ -n "$event" ] && ! grep -q "^$event|" "$STATE/played"; then
    fail_with "expected event '$event' to play, got: $(tr '\n' ' ' <"$STATE/played")"
  fi
}

assert_silent() {
  if [ -s "$STATE/played" ]; then
    fail_with "expected silence, but this played: $(tr '\n' ' ' <"$STATE/played")"
  fi
}

last_reason() {
  [ -f "$STATE/log" ] || {
    printf 'no log'
    return
  }
  grep -o 'reason="[^"]*"' "$STATE/log" 2>/dev/null | tail -n 1 | sed 's/^reason="//; s/"$//'
}

assert_reason() {
  local want="$1" got
  got=$(last_reason)
  case "$got" in
    *"$want"*) ;;
    *) fail_with "expected the blocking reason to mention '$want', got '$got'" ;;
  esac
}

assert_eq() {
  [ "$1" = "$2" ] || fail_with "${3:-values differ}: expected '$1', got '$2'"
}

assert_contains() {
  case "$2" in
    *"$1"*) ;;
    *) fail_with "${3:-output} should contain '$1', got: $2" ;;
  esac
}

# ---------------------------------------------------------------------------
# Rule 3: short turns stay silent
# ---------------------------------------------------------------------------

test_long_turn_plays() {
  mark_ago abc123 120
  hook 'done' abc123
  assert_played 'done'
}

test_short_turn_silent() {
  mark_ago abc123 5
  hook 'done' abc123
  assert_silent
  assert_reason "turn too short"
}

test_threshold_boundary_is_inclusive_above() {
  # Exactly at the threshold is not "shorter than", so it plays.
  mark_ago abc123 30
  hook 'done' abc123
  assert_played 'done'
}

test_custom_threshold_respected() {
  set_cfg threshold_seconds 300
  mark_ago abc123 120
  hook 'done' abc123
  assert_silent
  # Not the exact elapsed seconds: the clock can tick over between marking and
  # hooking, and a test that fails once an hour is worse than no test.
  assert_reason "< 300s"
}

test_unknown_session_plays() {
  # No session id in the payload at all: duration is unknowable.
  # Unknown must never mean silence.
  hook 'done' ""
  assert_played 'done'
}

test_missing_mark_plays() {
  # A session we never saw a UserPromptSubmit for.
  hook 'done' never-marked
  assert_played 'done'
}

test_garbage_mark_plays() {
  mkdir -p "$STATE/marks"
  printf 'not-a-timestamp\n' >"$STATE/marks/abc123"
  hook 'done' abc123
  assert_played 'done'
}

test_future_mark_plays() {
  # Clock changed under us: nonsense elapsed time, so treat it as unknown.
  mkdir -p "$STATE/marks"
  printf '%s\n' "$(($(date +%s) + 5000))" >"$STATE/marks/abc123"
  hook 'done' abc123
  assert_played 'done'
}

test_error_event_uses_threshold() {
  mark_ago abc123 3
  hook error abc123
  assert_silent
  assert_reason "turn too short"
}

test_waiting_ignores_threshold() {
  # 'waiting' is not turn-scoped: being asked for permission 2 seconds in is
  # exactly when you need to be told.
  mark_ago abc123 2
  hook waiting abc123
  assert_played waiting
}

test_subagent_ignores_threshold() {
  mark_ago abc123 1
  hook subagent abc123
  assert_played subagent
}

test_mark_is_consumed_after_done() {
  mark_ago abc123 120
  hook 'done' abc123
  if [ -f "$STATE/marks/abc123" ]; then
    fail_with "the mark should be gone once the turn is over"
  fi
}

# ---------------------------------------------------------------------------
# Rule 1: switches
# ---------------------------------------------------------------------------

test_disabled_suppresses_everything() {
  set_cfg enabled false
  local event
  for event in 'done' 'waiting' 'error' 'subagent'; do
    mark_ago abc123 999
    hook "$event" abc123
  done
  assert_silent
  assert_reason "disabled globally"
}

test_per_event_disable_only_affects_that_event() {
  set_cfg done_enabled false
  mark_ago abc123 999
  hook 'done' abc123
  assert_silent
  assert_reason "event 'done' is off"
  hook waiting abc123
  assert_played waiting
}

test_enabled_accepts_yes_no_spellings() {
  set_cfg enabled off
  hook 'done' ""
  assert_silent
  set_cfg enabled yes
  hook 'done' ""
  assert_played 'done'
}

test_gate_defaults_play_when_keys_are_omitted() {
  # The shipped defaults are the safety net for hand-edited configs that omit
  # a key. Every gate key missing at once must still allow an old enough turn
  # through, even with the clock inside the default quiet window.
  cat >"$STATE/config" <<EOF
volume=0.7
done_sound=$ROOT/sounds/bird.wav
EOF
  NOW="23:30"
  mark_ago abc123 120
  hook 'done' abc123
  assert_played 'done'
}

# ---------------------------------------------------------------------------
# Rule 2: quiet hours
# ---------------------------------------------------------------------------

test_quiet_hours_off_by_default_ignores_window() {
  # The window says it's quiet, but quiet_hours=false, so it plays.
  NOW="23:30"
  hook 'done' ""
  assert_played 'done'
}

test_quiet_hours_wrapping_midnight_before_midnight() {
  set_cfg quiet_hours true
  NOW="23:30"
  hook 'done' ""
  assert_silent
  assert_reason "quiet hours"
}

test_quiet_hours_wrapping_midnight_after_midnight() {
  set_cfg quiet_hours true
  NOW="02:00"
  hook 'done' ""
  assert_silent
}

test_quiet_hours_wrapping_midnight_outside() {
  set_cfg quiet_hours true
  NOW="09:00"
  hook 'done' ""
  assert_played 'done'
}

test_quiet_hours_start_boundary_is_quiet() {
  set_cfg quiet_hours true
  NOW="23:00"
  hook 'done' ""
  assert_silent
}

test_quiet_hours_end_boundary_is_awake() {
  # 08:00 is when you get up, so 08:00 is not quiet any more.
  set_cfg quiet_hours true
  NOW="08:00"
  hook 'done' ""
  assert_played 'done'
  rm -f "$STATE/played"
  NOW="07:59"
  hook 'done' ""
  assert_silent
}

test_quiet_hours_same_day_window() {
  set_cfg quiet_hours true
  set_cfg quiet_start 09:00
  set_cfg quiet_end 17:00
  NOW="12:00"
  hook 'done' ""
  assert_silent
  NOW="18:00"
  hook 'done' ""
  assert_played 'done'
  NOW="08:59"
  hook 'done' ""
  assert_played 'done'
}

test_malformed_quiet_hours_plays() {
  # Unparseable window: fail towards playing, never towards silence.
  set_cfg quiet_hours true
  set_cfg quiet_start "half past nine"
  NOW="23:30"
  hook 'done' ""
  assert_played 'done'
}

# ---------------------------------------------------------------------------
# Rule 4: your terminal is already frontmost
# ---------------------------------------------------------------------------

test_unknown_focus_plays() {
  TP="vscode"
  FF="-" # focus detection failed
  hook 'done' ""
  assert_played 'done'
}

test_terminal_frontmost_is_silent() {
  TP="vscode"
  FF="Cursor.app"
  hook 'done' ""
  assert_silent
  assert_reason "frontmost"
}

test_other_app_frontmost_plays() {
  TP="vscode"
  FF="Safari.app"
  hook 'done' ""
  assert_played 'done'
}

test_term_program_mapping() {
  local pair term front
  # TERM_PROGRAM:frontmost pairs that must be recognised as "you are looking
  # at your terminal already".
  for pair in \
    "vscode:Code.app" \
    "vscode:Cursor.app" \
    "vscode:Windsurf.app" \
    "vscode:VSCodium.app" \
    "vscode:Visual Studio Code.app" \
    "iTerm.app:iTerm2.app" \
    "iTerm.app:iTerm.app" \
    "Apple_Terminal:Terminal.app" \
    "ghostty:Ghostty.app" \
    "WarpTerminal:Warp.app" \
    "Hyper:Hyper.app" \
    "WezTerm:WezTerm.app"; do
    term="${pair%%:*}"
    front="${pair#*:}"
    rm -f "$STATE/played"
    TP="$term"
    FF="$front"
    hook 'done' ""
    if [ -s "$STATE/played" ]; then
      fail_with "TERM_PROGRAM=$term with $front frontmost should be silent"
    fi
  done
}

test_unset_term_program_plays() {
  # We cannot tell which app is "yours", so we must not suppress.
  TP=""
  FF="Cursor.app"
  hook 'done' ""
  assert_played 'done'
}

test_tmux_is_treated_as_unknown() {
  # tmux says nothing about the outer terminal.
  TP="tmux"
  FF="Cursor.app"
  hook 'done' ""
  assert_played 'done'
}

test_terminal_app_override_wins() {
  TP=""
  FF="Ghostty.app"
  set_cfg terminal_app "ghostty,kitty"
  hook 'done' ""
  assert_silent
  assert_reason "frontmost"
}

test_terminal_app_override_is_case_insensitive() {
  TP=""
  FF="GHOSTTY"
  set_cfg terminal_app "Ghostty"
  hook 'done' ""
  assert_silent
}

# ---------------------------------------------------------------------------
# Rule ordering
# ---------------------------------------------------------------------------

test_rules_short_circuit_in_order() {
  # Everything is blocking at once; the reported reason must be the first rule
  # in the documented order, otherwise "which rule blocked it" lies to people.
  set_cfg enabled false
  set_cfg quiet_hours true
  NOW="23:30"
  TP="vscode"
  FF="Cursor.app"
  mark_ago abc123 1
  hook 'done' abc123
  assert_reason "disabled globally"
}

test_quiet_hours_outranks_threshold() {
  set_cfg quiet_hours true
  NOW="23:30"
  mark_ago abc123 1
  hook 'done' abc123
  assert_reason "quiet hours"
}

# ---------------------------------------------------------------------------
# The hook contract: silent, harmless, exit 0
# ---------------------------------------------------------------------------

test_hook_prints_nothing_and_exits_zero() {
  # Anything on stdout can end up inside someone's Claude session.
  local out status
  mark_ago abc123 120
  out=$(hook 'done' abc123 2>&1)
  status=$?
  assert_eq "0" "$status" "hook exit status"
  assert_eq "" "$out" "hook output"
}

test_mark_prints_nothing_and_exits_zero() {
  local out status
  out=$(printf '{"session_id":"s1"}' |
    env BUZZER_HOME="$STATE" bash "$BUZZER" mark 2>&1)
  status=$?
  assert_eq "0" "$status" "mark exit status"
  assert_eq "" "$out" "mark output"
  [ -f "$STATE/marks/s1" ] || fail_with "mark should have written marks/s1"
}

test_hook_survives_a_broken_config() {
  printf 'this is not\nkey=value\x00 data\n[weird]\n' >"$STATE/config"
  local out status
  out=$(hook 'done' "" 2>&1)
  status=$?
  assert_eq "0" "$status" "hook exit status with a broken config"
  assert_eq "" "$out" "hook output with a broken config"
}

test_hook_survives_missing_home() {
  rm -rf "$STATE"
  local out status
  out=$(hook 'done' "" 2>&1)
  status=$?
  assert_eq "0" "$status" "hook exit status with no state directory"
  assert_eq "" "$out" "hook output with no state directory"
  mkdir -p "$STATE"
}

test_hook_survives_empty_stdin() {
  local out status
  out=$(printf '' | env BUZZER_HOME="$STATE" BUZZER_DRY_RUN=1 BUZZER_FAKE_FRONTMOST="-" \
    bash "$BUZZER" hook 'done' 2>&1)
  status=$?
  assert_eq "0" "$status" "hook exit status with empty stdin"
  assert_eq "" "$out" "hook output with empty stdin"
  assert_played 'done'
}

test_unknown_event_is_silent_and_exits_zero() {
  local out status
  out=$(hook nonsense "" 2>&1)
  status=$?
  assert_eq "0" "$status" "unknown event exit status"
  assert_eq "" "$out" "unknown event output"
  assert_silent
}

test_missing_sound_file_does_not_error() {
  set_cfg done_sound "$STATE/does-not-exist.wav"
  local out status
  out=$(hook 'done' "" 2>&1)
  status=$?
  assert_eq "0" "$status" "exit status with a missing sound file"
  assert_eq "" "$out" "output with a missing sound file"
  assert_contains "sound not readable" "$(cat "$STATE/log")" "log"
}

# ---------------------------------------------------------------------------
# Never block
# ---------------------------------------------------------------------------

test_hook_returns_immediately_while_sound_plays() {
  # Put a player on PATH that takes 5 seconds, then insist the hook is back in
  # under 3. If this ever fails, Claude is being made to wait on audio.
  local bin start elapsed player
  bin="$STATE/fakebin"
  mkdir -p "$bin"
  for player in afplay pw-play paplay powershell; do
    cat >"$bin/$player" <<EOF
#!/bin/sh
printf 'ran\n' >>"$STATE/player-ran"
sleep 5
EOF
    chmod +x "$bin/$player"
  done

  mark_ago abc123 120
  start=$(date +%s)
  printf '{"session_id":"abc123"}' |
    env PATH="$bin:$PATH" BUZZER_HOME="$STATE" BUZZER_FAKE_FRONTMOST="-" \
      bash "$BUZZER" hook 'done'
  elapsed=$(($(date +%s) - start))

  if [ "$elapsed" -ge 3 ]; then
    fail_with "the hook blocked for ${elapsed}s; playback must be fire-and-forget"
  fi

  # And the sound really was started, rather than skipped.
  local waited=0
  while [ ! -f "$STATE/player-ran" ] && [ "$waited" -lt 20 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$STATE/player-ran" ] || fail_with "no player was ever launched"
}

# ---------------------------------------------------------------------------
# Session ids become filenames
# ---------------------------------------------------------------------------

test_session_id_is_sanitized() {
  printf '{"session_id":"../../../tmp/buzzer-escape"}' |
    env BUZZER_HOME="$STATE" bash "$BUZZER" mark
  if [ -e "/tmp/buzzer-escape" ]; then
    rm -f /tmp/buzzer-escape
    fail_with "a session id escaped the marks directory"
  fi
  # Everything outside [A-Za-z0-9_-] is stripped, so this lands in one file.
  [ -f "$STATE/marks/tmpbuzzer-escape" ] ||
    fail_with "expected marks/tmpbuzzer-escape, got: $(find "$STATE/marks" -type f 2>/dev/null | tr '\n' ' ')"
}

test_session_id_with_slashes_still_measures_duration() {
  printf '{"session_id":"a/b/c"}' | env BUZZER_HOME="$STATE" bash "$BUZZER" mark
  # Same id in, same sanitized file out, so the duration is still found (and a
  # 0-second turn is below the threshold).
  hook 'done' "a/b/c"
  assert_silent
  assert_reason "turn too short"
}

test_empty_session_id_writes_no_mark() {
  printf '{"session_id":""}' | env BUZZER_HOME="$STATE" bash "$BUZZER" mark
  assert_eq "0" "$(find "$STATE/marks" -type f 2>/dev/null | wc -l | tr -d ' ')" "mark count"
}

test_old_marks_are_pruned() {
  mkdir -p "$STATE/marks"
  printf '1\n' >"$STATE/marks/ancient"
  touch -t 202001010000 "$STATE/marks/ancient" 2>/dev/null ||
    fail_with "could not backdate a file; skipping prune check"
  printf '{"session_id":"fresh"}' | env BUZZER_HOME="$STATE" bash "$BUZZER" mark
  local waited=0
  while [ -f "$STATE/marks/ancient" ] && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$STATE/marks/ancient" ] && fail_with "marks older than 24h should be pruned"
  [ -f "$STATE/marks/fresh" ] || fail_with "the fresh mark should survive pruning"
}

# ---------------------------------------------------------------------------
# Playback details
# ---------------------------------------------------------------------------

test_waiting_plays_twice() {
  hook waiting ""
  assert_contains "|2|" "$(cat "$STATE/played")" "played record"
}

test_subagent_is_quieter() {
  hook subagent ""
  assert_contains "|0.35|" "$(cat "$STATE/played")" "played record"
}

test_per_event_volume_overrides_global() {
  set_cfg volume 0.9
  set_cfg done_volume 0.2
  hook 'done' ""
  assert_contains "|0.2|" "$(cat "$STATE/played")" "played record"
}

test_out_of_range_volume_falls_back() {
  set_cfg volume 11
  hook 'done' ""
  assert_contains "|0.7|" "$(cat "$STATE/played")" "played record"
}

# ---------------------------------------------------------------------------
# Log
# ---------------------------------------------------------------------------

test_log_is_capped() {
  local i=0 lines
  while [ "$i" -lt 60 ]; do
    hook 'done' "" >/dev/null 2>&1
    i=$((i + 1))
  done
  lines=$(wc -l <"$STATE/log" | tr -d ' ')
  if [ "$lines" -gt 145 ]; then
    fail_with "log grew to $lines lines; it must stay around 100"
  fi
  if [ "$lines" -lt 10 ]; then
    fail_with "log only has $lines lines; it should be recording decisions"
  fi
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

test_status_agrees_with_the_hook() {
  # If status and the hook can disagree, status is decoration. They must share
  # the decision code.
  set_cfg quiet_hours true
  NOW="23:30"
  assert_contains "silent" "$(cli status)" "status output"
  assert_contains "quiet hours" "$(cli status)" "status output"
  hook 'done' ""
  assert_silent
}

test_status_reports_unknown_focus_honestly() {
  TP=""
  FF="-"
  assert_contains "unknown" "$(cli status)" "status output"
}

test_set_rejects_unknown_event() {
  local out status
  out=$(cli set nosuchevent "$ROOT/sounds/bird.wav" 2>&1)
  status=$?
  [ "$status" -eq 0 ] && fail_with "expected a non-zero exit for an unknown event"
  assert_contains "done" "$out" "error message"
  assert_contains "waiting" "$out" "error message"
  assert_contains "subagent" "$out" "error message"
}

test_set_rejects_missing_file() {
  local status
  cli set 'done' /no/such/file.wav >/dev/null 2>&1
  status=$?
  [ "$status" -eq 0 ] && fail_with "expected a non-zero exit for a missing sound"
}

test_set_accepts_a_bundled_sound_by_name() {
  cli set 'done' bird.wav >/dev/null 2>&1
  assert_contains "sounds/bird.wav" "$(cli config done_sound)" "configured sound"
}

test_off_then_on_round_trips() {
  cli off >/dev/null
  hook 'done' ""
  assert_silent
  cli on >/dev/null
  hook 'done' ""
  assert_played 'done'
}

test_quiet_hours_cli_sets_the_window() {
  cli quiet-hours 22:15 06:45 >/dev/null
  assert_eq "true" "$(cli config quiet_hours)" "quiet_hours"
  assert_eq "22:15" "$(cli config quiet_start)" "quiet_start"
  assert_eq "06:45" "$(cli config quiet_end)" "quiet_end"
  cli quiet-hours off >/dev/null
  assert_eq "false" "$(cli config quiet_hours)" "quiet_hours after off"
}

test_quiet_hours_cli_rejects_nonsense() {
  local status
  cli quiet-hours 99:99 08:00 >/dev/null 2>&1
  status=$?
  [ "$status" -eq 0 ] && fail_with "expected a non-zero exit for an invalid time"
}

test_cli_does_not_touch_settings_json() {
  # The one file this project must never write.
  local fake_home settings before
  fake_home="$STATE/fakehome"
  mkdir -p "$fake_home/.claude"
  settings="$fake_home/.claude/settings.json"
  printf '{"model":"opus"}' >"$settings"
  before=$(cat "$settings")
  env HOME="$fake_home" BUZZER_HOME="$STATE" bash "$BUZZER" on >/dev/null 2>&1
  env HOME="$fake_home" BUZZER_HOME="$STATE" bash "$BUZZER" set 'done' bird.wav >/dev/null 2>&1
  env HOME="$fake_home" BUZZER_HOME="$STATE" bash "$BUZZER" hooks >/dev/null 2>&1
  env HOME="$fake_home" BUZZER_HOME="$STATE" bash "$BUZZER" doctor >/dev/null 2>&1
  env HOME="$fake_home" BUZZER_HOME="$STATE" bash "$BUZZER" status >/dev/null 2>&1
  printf '{"session_id":"x"}' | env HOME="$fake_home" BUZZER_HOME="$STATE" bash "$BUZZER" mark
  printf '{"session_id":"x"}' | env HOME="$fake_home" BUZZER_HOME="$STATE" BUZZER_DRY_RUN=1 \
    bash "$BUZZER" hook 'done'
  assert_eq "$before" "$(cat "$settings")" "settings.json contents"
}

test_hooks_snippet_is_valid_json_ish() {
  local out
  out=$(cli hooks)
  assert_contains "UserPromptSubmit" "$out" "hooks snippet"
  assert_contains "SubagentStop" "$out" "hooks snippet"
  assert_contains "mark" "$out" "hooks snippet"
  assert_contains "hook done" "$out" "hooks snippet"
  # Braces must balance, or people will paste a broken settings.json.
  local opens closes
  opens=$(printf '%s' "$out" | tr -cd '{' | wc -c | tr -d ' ')
  closes=$(printf '%s' "$out" | tr -cd '}' | wc -c | tr -d ' ')
  assert_eq "$opens" "$closes" "brace balance in the hooks snippet"
}

test_unknown_command_exits_nonzero() {
  local status
  cli frobnicate >/dev/null 2>&1
  status=$?
  [ "$status" -eq 0 ] && fail_with "expected a non-zero exit for an unknown command"
}

test_doctor_flags_a_missing_sound() {
  set_cfg done_sound "$STATE/gone.wav"
  local out status
  out=$(cli doctor 2>&1)
  status=$?
  assert_contains "MISSING" "$out" "doctor output"
  [ "$status" -eq 0 ] && fail_with "doctor should exit non-zero when something is broken"
}

test_doctor_passes_on_a_healthy_setup() {
  local out status
  out=$(cli doctor 2>&1)
  status=$?
  assert_contains "no problems" "$out" "doctor output"
  assert_eq "0" "$status" "doctor exit status"
}

test_list_shows_every_event() {
  local out
  out=$(cli list)
  local event
  for event in 'done' 'waiting' 'error' 'subagent'; do
    assert_contains "$event" "$out" "list output"
  done
}

# `set -u` plus $HOME at top level means an environment without HOME aborts the
# script before hook_mode_shield is ever reached — so the shield cannot protect
# anything. cron, systemd units and some CI runners all invoke commands with no
# HOME. The result breaks two cardinal rules at once: a message on stderr, and a
# non-zero exit, both landing in the agent's session.
test_hook_survives_an_unset_home() {
  local out rc
  out=$(env -u HOME -u BUZZER_HOME bash "$BUZZER" hook 'done' </dev/null 2>&1)
  rc=$?
  assert_eq "0" "$rc" "hook exit status with HOME unset"
  if [ -n "$out" ]; then
    fail_with "hook wrote to stdout/stderr with HOME unset: $out"
  fi
}

test_mark_survives_an_unset_home() {
  local out rc
  out=$(printf '{"session_id":"x"}' | env -u HOME -u BUZZER_HOME bash "$BUZZER" mark 2>&1)
  rc=$?
  assert_eq "0" "$rc" "mark exit status with HOME unset"
  if [ -n "$out" ]; then
    fail_with "mark wrote to stdout/stderr with HOME unset: $out"
  fi
}

# On a platform with no system sound set, the default config points at the
# bundled bird. buzzer.ps1 checks that file exists and falls back to the
# checkout's copy; buzzer.sh did not, so a Linux user running from a clone
# without install.sh got a config naming a file that was never there — and a
# sound file that does not exist is silence on every event, forever.
test_default_config_never_names_a_missing_sound() {
  local fresh event sound
  fresh="$STATE/freshhome"
  mkdir -p "$fresh"
  # Force the no-system-sounds branch that Linux and Windows take.
  env BUZZER_HOME="$fresh" BUZZER_FAKE_OS=linux bash "$BUZZER" list >/dev/null 2>&1

  for event in 'done' waiting error subagent; do
    sound=$(sed -n "s/^${event}_sound=//p" "$fresh/config" 2>/dev/null | tail -n 1)
    if [ -z "$sound" ]; then
      fail_with "no ${event}_sound written to the default config"
      continue
    fi
    [ -f "$sound" ] ||
      fail_with "default config points ${event}_sound at a file that does not exist: $sound"
  done
}

# The issue template asks people to paste doctor output into a public bug
# report, so doctor decides what strangers see. Machine names routinely contain
# a real name ("Sules-MacBook-Air") and home paths contain the username. Neither
# helps anyone debug an audio backend.
test_doctor_does_not_leak_hostname_or_home_path() {
  local fake_home out host
  fake_home="$STATE/doctorhome"
  mkdir -p "$fake_home"
  out=$(env -u BUZZER_HOME HOME="$fake_home" BUZZER_FAKE_FRONTMOST="-" \
    bash "$BUZZER" doctor 2>&1)

  case "$out" in
    *"$fake_home"*)
      fail_with "doctor prints the absolute home path; it should abbreviate to ~"
      ;;
  esac

  host=$(uname -n 2>/dev/null)
  if [ -n "$host" ]; then
    case "$out" in
      *"$host"*)
        fail_with "doctor prints the machine hostname ($host), which people paste into public issues"
        ;;
    esac
  fi

  # Still has to be useful: redacting must not have emptied the section. The
  # kernel line is the part that actually explains a platform-specific bug.
  # Deliberately not asserting a specific OS name — this suite runs on macOS,
  # Linux and Git Bash, and hard-coding one of them made CI red on the other two.
  assert_contains "[platform]" "$out" "doctor platform section"
  assert_contains "kernel" "$out" "doctor platform section"
}

# agent-buzzer is not a Claude Code accessory. Keeping its config and logs
# inside ~/.claude would mean a Codex or Gemini user has to create another
# tool's directory to configure this one, and it quietly asserts an ownership
# that stops being true the moment a second adapter lands.
test_state_lives_outside_any_single_agents_directory() {
  local fake_home out
  fake_home="$STATE/statehome"
  mkdir -p "$fake_home"
  out=$(env -u BUZZER_HOME HOME="$fake_home" BUZZER_FAKE_FRONTMOST="-" \
    bash "$BUZZER" status 2>&1)
  # Paths are printed ~-abbreviated (see tilde()), so match that form. The
  # literal tilde is the point here — expanding it to $HOME would test the
  # opposite of what this asserts.
  # shellcheck disable=SC2088
  assert_contains "~/.agent-buzzer" "$out" "the default state directory"
  case "$out" in
    *".claude/buzzer"*)
      fail_with "state still defaults to ~/.claude/buzzer, inside another tool's config directory"
      ;;
  esac
}

# An app whose name merely CONTAINS a terminal's name is not that terminal.
# Xcode is the one that bites in practice: run Claude in Cursor's terminal,
# flip to Xcode to read something, and a substring match reads "xcode" as
# containing "code" and goes silent — exactly when you most need the sound.
test_lookalike_app_names_still_play() {
  local pair term front
  for pair in \
    "vscode:Xcode.app" \
    "vscode:Barcode Scanner.app" \
    "vscode:Codebook.app" \
    "Apple_Terminal:Terminal Pro.app" \
    "Hyper:Hyperion.app" \
    "WarpTerminal:Warpinator.app"; do
    term="${pair%%:*}"
    front="${pair#*:}"
    rm -f "$STATE/played"
    TP="$term"
    FF="$front"
    hook 'done' ""
    if [ ! -s "$STATE/played" ]; then
      fail_with "TERM_PROGRAM=$term with $front frontmost is a different app and must play"
    fi
  done
}

# The existing "returns immediately" test stubs the frontmost-app lookup out
# entirely, so it never exercises the one component that can actually wedge in
# production. Focus detection shells out to osascript (or xdotool/xprop), and
# if the window server is busy — or there is no GUI session at all, as over
# ssh — that call can hang forever, taking the Claude session down with it.
test_hook_returns_when_focus_detection_hangs() {
  local bin start elapsed detector
  bin="$STATE/fakebin"
  mkdir -p "$bin"
  for detector in osascript xdotool xprop swaymsg; do
    printf '#!/bin/sh\nsleep 30\n' >"$bin/$detector"
    chmod +x "$bin/$detector"
  done

  mark_ago wedged 120
  start=$(date +%s)
  # Deliberately no BUZZER_FAKE_FRONTMOST: this must go through the real
  # detector so the hang is real.
  printf '{"session_id":"wedged"}' |
    env PATH="$bin:$PATH" BUZZER_HOME="$STATE" BUZZER_DRY_RUN=1 \
      TERM_PROGRAM="vscode" DISPLAY=":0" \
      bash "$BUZZER" hook 'done'
  elapsed=$(($(date +%s) - start))

  if [ "$elapsed" -ge 5 ]; then
    fail_with "focus detection hung for ${elapsed}s and the hook waited on it; Claude was stalled"
  fi
  # A detector that never answers is the definition of unknown focus, and
  # unknown focus plays.
  assert_played 'done'
}

test_hooks_snippet_covers_every_event() {
  local out event
  out=$(cli hooks)
  for event in UserPromptSubmit Stop StopFailure Notification SubagentStop; do
    assert_contains "\"$event\"" "$out" "the hooks snippet"
  done
}

# Without async the hook is on the turn's critical path: Claude waits for it
# before handing control back. It is a one-word fix and it makes an entire
# class of "the buzzer stalled my session" bug impossible.
test_hooks_snippet_marks_every_hook_async() {
  local json commands asyncs
  # Count inside the JSON block only. The prose around it discusses async too,
  # and a test that counts the explanation is measuring the wrong thing.
  json=$(cli hooks | sed -n '/^{/,/^}/p')
  commands=$(printf '%s' "$json" | grep -c '"type": *"command"')
  asyncs=$(printf '%s' "$json" | grep -c '"async": *true')
  assert_eq "$commands" "$asyncs" "every command hook should be marked async"
}

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------

printf 'agent-buzzer tests  %s\n' "$(dim "$BUZZER")"
[ -n "$FILTER" ] && printf '%s\n' "$(dim "filter: $FILTER")"
printf '\n'

if [ ! -f "$ROOT/sounds/bird.wav" ]; then
  printf '%s sounds/bird.wav is missing — run: python3 tools/make-sounds.py\n' "$(red 'error:')"
  exit 1
fi

run_test "long turn plays" test_long_turn_plays
run_test "short turn stays silent" test_short_turn_silent
run_test "a turn exactly at the threshold plays" test_threshold_boundary_is_inclusive_above
run_test "custom threshold is respected" test_custom_threshold_respected
run_test "unknown session plays" test_unknown_session_plays
run_test "missing mark plays" test_missing_mark_plays
run_test "garbage mark plays" test_garbage_mark_plays
run_test "mark in the future plays" test_future_mark_plays
run_test "error event obeys the threshold" test_error_event_uses_threshold
run_test "waiting ignores the threshold" test_waiting_ignores_threshold
run_test "subagent ignores the threshold" test_subagent_ignores_threshold
run_test "the mark is consumed when the turn ends" test_mark_is_consumed_after_done

run_test "disabled suppresses everything" test_disabled_suppresses_everything
run_test "per-event disable affects only that event" test_per_event_disable_only_affects_that_event
run_test "on/off spellings are accepted" test_enabled_accepts_yes_no_spellings
run_test "gate defaults play when keys are omitted" test_gate_defaults_play_when_keys_are_omitted

run_test "quiet hours off ignores the window" test_quiet_hours_off_by_default_ignores_window
run_test "quiet hours wrapping midnight: 23:30 is quiet" test_quiet_hours_wrapping_midnight_before_midnight
run_test "quiet hours wrapping midnight: 02:00 is quiet" test_quiet_hours_wrapping_midnight_after_midnight
run_test "quiet hours wrapping midnight: 09:00 is not" test_quiet_hours_wrapping_midnight_outside
run_test "quiet hours start boundary is quiet" test_quiet_hours_start_boundary_is_quiet
run_test "quiet hours end boundary is awake" test_quiet_hours_end_boundary_is_awake
run_test "quiet hours within one day" test_quiet_hours_same_day_window
run_test "malformed quiet hours plays" test_malformed_quiet_hours_plays

run_test "unknown focus plays" test_unknown_focus_plays
run_test "your terminal frontmost is silent" test_terminal_frontmost_is_silent
run_test "another app frontmost plays" test_other_app_frontmost_plays
run_test "TERM_PROGRAM mapping table" test_term_program_mapping
run_test "unset TERM_PROGRAM plays" test_unset_term_program_plays
run_test "tmux counts as unknown" test_tmux_is_treated_as_unknown
run_test "hook survives an unset HOME" test_hook_survives_an_unset_home
run_test "mark survives an unset HOME" test_mark_survives_an_unset_home
run_test "default config never names a missing sound" test_default_config_never_names_a_missing_sound
run_test "doctor leaks neither hostname nor home path" test_doctor_does_not_leak_hostname_or_home_path
run_test "state lives outside any one agent's directory" test_state_lives_outside_any_single_agents_directory
run_test "a lookalike app name still plays" test_lookalike_app_names_still_play
run_test "a hanging focus detector does not block" test_hook_returns_when_focus_detection_hangs
run_test "terminal_app override wins" test_terminal_app_override_wins
run_test "terminal_app override ignores case" test_terminal_app_override_is_case_insensitive

run_test "rules short-circuit in the documented order" test_rules_short_circuit_in_order
run_test "quiet hours outranks the threshold" test_quiet_hours_outranks_threshold

run_test "hook prints nothing and exits 0" test_hook_prints_nothing_and_exits_zero
run_test "mark prints nothing and exits 0" test_mark_prints_nothing_and_exits_zero
run_test "hook survives a broken config" test_hook_survives_a_broken_config
run_test "hook survives a missing state directory" test_hook_survives_missing_home
run_test "hook survives empty stdin" test_hook_survives_empty_stdin
run_test "unknown event is silent and exits 0" test_unknown_event_is_silent_and_exits_zero
run_test "missing sound file does not error" test_missing_sound_file_does_not_error

run_test "hook returns immediately while the sound plays" test_hook_returns_immediately_while_sound_plays

run_test "session id is sanitized" test_session_id_is_sanitized
run_test "sanitized session id still measures duration" test_session_id_with_slashes_still_measures_duration
run_test "empty session id writes no mark" test_empty_session_id_writes_no_mark
run_test "marks older than 24h are pruned" test_old_marks_are_pruned

run_test "waiting plays twice" test_waiting_plays_twice
run_test "subagent is quieter" test_subagent_is_quieter
run_test "per-event volume overrides the default" test_per_event_volume_overrides_global
run_test "out-of-range volume falls back" test_out_of_range_volume_falls_back

run_test "the log is capped" test_log_is_capped

run_test "status agrees with the hook" test_status_agrees_with_the_hook
run_test "status reports unknown focus honestly" test_status_reports_unknown_focus_honestly
run_test "set rejects an unknown event" test_set_rejects_unknown_event
run_test "set rejects a missing file" test_set_rejects_missing_file
run_test "set accepts a bundled sound by name" test_set_accepts_a_bundled_sound_by_name
run_test "off then on round-trips" test_off_then_on_round_trips
run_test "quiet-hours sets the window" test_quiet_hours_cli_sets_the_window
run_test "quiet-hours rejects nonsense" test_quiet_hours_cli_rejects_nonsense
run_test "nothing ever writes settings.json" test_cli_does_not_touch_settings_json
run_test "the hooks snippet looks pasteable" test_hooks_snippet_is_valid_json_ish
run_test "the hooks snippet covers every event" test_hooks_snippet_covers_every_event
run_test "the hooks snippet marks hooks async" test_hooks_snippet_marks_every_hook_async
run_test "an unknown command exits non-zero" test_unknown_command_exits_nonzero
run_test "doctor flags a missing sound" test_doctor_flags_a_missing_sound
run_test "doctor passes on a healthy setup" test_doctor_passes_on_a_healthy_setup
run_test "list shows every event" test_list_shows_every_event

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '%s %s passed\n' "$(green 'all good:')" "$PASSED"
  exit 0
fi
printf '%s %s passed, %s failed%s\n' "$(red 'failures:')" "$PASSED" "$FAILED" "$FAILED_LIST"
exit 1
