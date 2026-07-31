#!/usr/bin/env bash
#
# agent-buzzer — plays a sound when Claude Code finishes working, so you can
# look away from the terminal instead of babysitting it.
#
# Covers macOS (reference platform) and Linux. Windows lives in buzzer.ps1.
#
# There are two kinds of caller:
#
#   Claude Code   buzzer mark | buzzer hook <event>
#                 Must be instant and completely silent.
#   Humans        buzzer list | set | test | status | doctor | ...
#                 May print freely and exit non-zero on bad input.
#
# THREE RULES THAT OUTRANK EVERYTHING ELSE IN THIS FILE:
#
#   1. NEVER BLOCK. Playback is always fire-and-forget. The hook returns while
#      the sound is still playing, no matter how long the file is.
#
#   2. FAIL OPEN, NEVER FAIL LOUD. In hook mode, any unexpected condition exits
#      0 with nothing on stdout or stderr. A buzzer that prints errors into
#      someone's Claude session is worse than a buzzer that misses one beep.
#      Diagnostics go to $BUZZER_HOME/log instead.
#
#   3. WHEN SOMETHING IS UNKNOWN, PLAY. If focus can't be detected or the turn
#      duration can't be measured, play the sound. Missing a notification is a
#      worse failure than one extra beep. Please do not "fix" this the other
#      way around; it is deliberate, and it is the whole point of the tool.
#
# Zero runtime dependencies. No jq, no python, no daemon.

set -u

VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Deliberately not under ~/.claude. Claude Code is the first agent supported,
# not the only one planned, and a Codex user should not have to create another
# tool's config directory to set up this one.
#
# BUZZER_HOME can be overridden, which is also how the test suite runs against
# a throwaway state directory instead of your real one.
# ${HOME:-...} rather than $HOME: `set -u` is on, this runs at top level, and
# hook_mode_shield is not installed until cmd_hook/cmd_mark are reached. An
# environment without HOME — cron, systemd units, some CI runners — would
# therefore abort here with an unbound-variable message on stderr and exit 1,
# breaking two cardinal rules before the code that guarantees them ever runs.
BUZZER_HOME="${BUZZER_HOME:-${HOME:-/nonexistent}/.agent-buzzer}"

# Abbreviate $HOME to ~ in anything a user might paste somewhere public. The
# issue template asks for `buzzer doctor` output, and a home path hands over a
# username to anyone reading the thread. Shorter to read, too.
tilde() {
  local home="${HOME:-}"
  [ -n "$home" ] || {
    printf '%s' "$1"
    return 0
  }
  case "$1" in
    "$home"/*) printf '~%s' "${1#"$home"}" ;;
    "$home") printf '~' ;;
    *) printf '%s' "$1" ;;
  esac
}
CONFIG_FILE="$BUZZER_HOME/config"
MARKS_DIR="$BUZZER_HOME/marks"
LOG_FILE="$BUZZER_HOME/log"

# The log is a debugging aid, not an archive. Trim it back to LOG_KEEP lines
# once it grows past LOG_MAX so it can never eat disk.
LOG_KEEP=100
LOG_MAX=140

EVENTS="done waiting error subagent"
REPEAT_GAP=0.35

# Where bundled sounds live, following symlinks so an installed
# ~/.local/bin/buzzer symlink still finds the repo's sounds/ directory.
script_dir() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "$src" ]; do
    dir=$(cd -P "$(dirname "$src")" && pwd)
    src=$(readlink "$src")
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}

SCRIPT_DIR=$(script_dir)

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

os_name() {
  # Test seam, same idea as BUZZER_FAKE_FRONTMOST and BUZZER_FAKE_NOW: the
  # Linux and Windows branches are the least exercised code here, and being
  # able to drive them from a macOS test run is worth one line.
  if [ -n "${BUZZER_FAKE_OS:-}" ]; then
    printf '%s\n' "$BUZZER_FAKE_OS"
    return 0
  fi
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) echo macos ;;
    Linux) echo linux ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

OS=$(os_name)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  local msg="$1" lines
  mkdir -p "$BUZZER_HOME" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$msg" \
    >>"$LOG_FILE" 2>/dev/null || return 0

  lines=$(wc -l <"$LOG_FILE" 2>/dev/null | tr -d ' ')
  case "$lines" in
    '' | *[!0-9]*) return 0 ;;
  esac
  if [ "$lines" -gt "$LOG_MAX" ]; then
    tail -n "$LOG_KEEP" "$LOG_FILE" >"$LOG_FILE.trim" 2>/dev/null &&
      mv "$LOG_FILE.trim" "$LOG_FILE" 2>/dev/null
  fi
  return 0
}

# Human-facing error. Only ever called from CLI mode.
err() {
  printf 'buzzer: %s\n' "$1" >&2
}

# ---------------------------------------------------------------------------
# Config: plain key=value, one per line, '#' starts a comment.
#
# Deliberately not JSON/TOML: bash and PowerShell both have to parse it with no
# dependencies, and humans have to edit it by hand.
# ---------------------------------------------------------------------------

default_sound() {
  local event="$1"
  if [ "$OS" = macos ]; then
    case "$event" in
      done) echo /System/Library/Sounds/Glass.aiff ;;
      waiting) echo /System/Library/Sounds/Ping.aiff ;;
      error) echo /System/Library/Sounds/Basso.aiff ;;
      subagent) echo /System/Library/Sounds/Pop.aiff ;;
    esac
  else
    # No system sound set to rely on, so fall back to the bundled bird —
    # preferring the installed copy, then this checkout's own. Writing a path
    # that isn't there would bake permanent silence into the default config of
    # anyone running from a clone without install.sh, which is the worst
    # possible failure for this tool. buzzer.ps1 guards the same way.
    if [ -f "$BUZZER_HOME/sounds/bird.wav" ]; then
      echo "$BUZZER_HOME/sounds/bird.wav"
    elif [ -f "$SCRIPT_DIR/sounds/bird.wav" ]; then
      echo "$SCRIPT_DIR/sounds/bird.wav"
    else
      echo "$BUZZER_HOME/sounds/bird.wav"
    fi
  fi
}

write_default_config() {
  mkdir -p "$BUZZER_HOME" "$MARKS_DIR" 2>/dev/null || return 1
  cat >"$CONFIG_FILE" <<EOF
# agent-buzzer config — plain key=value, one per line. '#' starts a comment.
# Edit by hand or use the CLI ("buzzer set", "buzzer volume", ...).
# Run "buzzer status" to see what is in effect and what would happen right now.

# Master switch.
enabled=true

# Turns shorter than this many seconds stay silent, so one-line chat replies
# don't beep. Only applies to 'done' and 'error'.
threshold_seconds=30

# Default playback volume, 0.0-1.0. Per-event overrides below win.
volume=0.7

# Quiet hours. Off by default. The window may wrap midnight (23:00 -> 08:00).
quiet_hours=false
quiet_start=23:00
quiet_end=08:00

# Which app counts as "your terminal", i.e. if it's frontmost you are already
# looking at Claude and don't need a sound. Empty = detect from TERM_PROGRAM.
# Accepts a comma-separated list of substrings, e.g. "cursor,ghostty".
terminal_app=

# done      — Claude finished its turn
# waiting   — Claude is blocked on a permission prompt or a question
# error     — the turn failed or was interrupted
# subagent  — a background/subagent task finished

done_enabled=true
done_sound=$(default_sound 'done')
done_volume=
done_repeat=1

waiting_enabled=true
waiting_sound=$(default_sound 'waiting')
waiting_volume=
waiting_repeat=2

error_enabled=true
error_sound=$(default_sound error)
error_volume=
error_repeat=1

subagent_enabled=true
subagent_sound=$(default_sound subagent)
subagent_volume=0.35
subagent_repeat=1
EOF
}

ensure_config() {
  mkdir -p "$BUZZER_HOME" "$MARKS_DIR" 2>/dev/null || return 1
  [ -f "$CONFIG_FILE" ] && return 0
  write_default_config
}

# cfg_get <key> [default]
cfg_get() {
  local key="$1" fallback="${2-}" value=""
  if [ -r "$CONFIG_FILE" ]; then
    value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\(.*\)\$/\1/p" \
      "$CONFIG_FILE" 2>/dev/null | tail -n 1)
    value=${value%$'\r'}
    value=$(printf '%s' "$value" | sed 's/[[:space:]]*$//')
  fi
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

# cfg_bool <key> <default> — prints "true" or "false", never anything else.
cfg_bool() {
  local raw
  raw=$(cfg_get "$1" "$2")
  case $(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]') in
    true | 1 | yes | on) echo true ;;
    false | 0 | no | off) echo false ;;
    *) echo "$2" ;;
  esac
}

# cfg_num <key> <default> — non-negative integer, default on anything weird.
cfg_num() {
  local raw
  raw=$(cfg_get "$1" "$2")
  case "$raw" in
    '' | *[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

# Valid volumes are 0.0-1.0. Anything else falls back rather than making afplay
# fail, because a silent failure here would mean a missed notification.
valid_volume() {
  case "$1" in
    '' | *[!0-9.]* | *.*.*) return 1 ;;
  esac
  awk -v v="$1" 'BEGIN { exit !(v >= 0 && v <= 1) }' 2>/dev/null
}

event_volume() {
  local event="$1" v
  v=$(cfg_get "${event}_volume" "")
  valid_volume "$v" && { printf '%s\n' "$v"; return 0; }
  v=$(cfg_get volume 0.7)
  valid_volume "$v" && { printf '%s\n' "$v"; return 0; }
  echo 0.7
}

# cfg_set <key> <value> — rewrites in place, appends if the key is absent.
cfg_set() {
  local key="$1" value="$2" tmp
  ensure_config || return 1
  tmp="$CONFIG_FILE.tmp.$$"
  BZ_KEY="$key" BZ_VAL="$value" awk '
    BEGIN { key = ENVIRON["BZ_KEY"]; val = ENVIRON["BZ_VAL"]; written = 0 }
    {
      line = $0
      probe = line
      sub(/^[ \t]+/, "", probe)
      if (probe ~ ("^" key "[ \t]*=")) {
        if (!written) { print key "=" val; written = 1 }
        next
      }
      print line
    }
    END { if (!written) print key "=" val }
  ' "$CONFIG_FILE" >"$tmp" 2>/dev/null && mv "$tmp" "$CONFIG_FILE" 2>/dev/null
}

is_event() {
  case " $EVENTS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

require_event() {
  if ! is_event "${1-}"; then
    err "unknown event '${1-}'. Valid events: $(echo "$EVENTS" | tr ' ' ',' | sed 's/,/, /g')"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Hook payload parsing. Claude Code sends JSON on stdin; we need exactly one
# string field out of it, which is not worth a dependency on jq.
# ---------------------------------------------------------------------------

json_string() {
  local key="$1" payload="$2"
  printf '%s' "$payload" | tr -d '\n' |
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null |
    head -n 1 | sed 's/^.*:[[:space:]]*"//; s/"$//'
}

# A session id becomes a filename, so allow only [A-Za-z0-9_-].
sanitize_id() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-128
}

now_epoch() {
  date +%s 2>/dev/null
}

# BUZZER_FAKE_NOW ("HH:MM") exists so the quiet-hours tests don't have to wait
# until 23:00 to run.
now_hhmm() {
  if [ -n "${BUZZER_FAKE_NOW:-}" ]; then
    printf '%s\n' "$BUZZER_FAKE_NOW"
  else
    date +%H:%M 2>/dev/null
  fi
}

hhmm_to_min() {
  local v="$1" h m
  case "$v" in
    [0-9][0-9]:[0-9][0-9]) ;;
    [0-9]:[0-9][0-9]) v="0$v" ;;
    *) return 1 ;;
  esac
  h=$((10#${v%%:*}))
  m=$((10#${v##*:}))
  { [ "$h" -le 23 ] && [ "$m" -le 59 ]; } || return 1
  printf '%s\n' "$((h * 60 + m))"
}

# in_quiet_window <now> <from> <to> — 0 if now is inside the window.
# Anything unparseable returns 1 (not quiet), because failing towards "play" is
# the safe direction.
in_quiet_window() {
  local n f t
  n=$(hhmm_to_min "$1") || return 1
  f=$(hhmm_to_min "$2") || return 1
  t=$(hhmm_to_min "$3") || return 1
  [ "$f" -eq "$t" ] && return 1
  if [ "$f" -lt "$t" ]; then
    [ "$n" -ge "$f" ] && [ "$n" -lt "$t" ]
  else
    # Wraps midnight, e.g. 23:00-08:00: inside if after 'from' OR before 'to'.
    [ "$n" -ge "$f" ] || [ "$n" -lt "$t" ]
  fi
}

# ---------------------------------------------------------------------------
# Turn duration
#
# 'buzzer mark' (UserPromptSubmit) drops an epoch timestamp per session; the
# done/error hook diffs against it. No mark means we cannot know how long the
# turn was, and unknown means PLAY.
# ---------------------------------------------------------------------------

mark_file() {
  local id
  id=$(sanitize_id "$1")
  [ -n "$id" ] || return 1
  printf '%s\n' "$MARKS_DIR/$id"
}

# Prints elapsed seconds, or nothing at all when unknown.
turn_elapsed() {
  local payload="$1" id file started now
  id=$(json_string session_id "$payload")
  file=$(mark_file "$id") || return 0
  [ -f "$file" ] || return 0
  started=$(head -n 1 "$file" 2>/dev/null | tr -cd '0-9')
  now=$(now_epoch)
  [ -n "$started" ] && [ -n "$now" ] || return 0
  [ "$now" -ge "$started" ] || return 0
  printf '%s\n' "$((now - started))"
}

prune_marks() {
  [ -d "$MARKS_DIR" ] || return 0
  # One rm per file rather than -exec ... +, which has to ask for ARG_MAX and
  # therefore fails outright in sandboxed environments. There are only ever a
  # handful of marks, so the extra processes cost nothing.
  find "$MARKS_DIR" -type f -mtime +1 -exec rm -f {} \; 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# Focus detection
#
# Returns the frontmost application's name, or nothing when it cannot be
# determined. Empty output means UNKNOWN, and unknown means PLAY.
# ---------------------------------------------------------------------------

# Every detector here talks to a window server, and a window server can stop
# answering: a wedged WindowServer, a machine mid-login, or an ssh session with
# no GUI at all. Without a ceiling the hook waits forever and takes the Claude
# session down with it — the exact failure this tool exists to prevent. Two
# seconds is twenty times a healthy osascript call.
FOCUS_TIMEOUT_SECONDS=2

# with_deadline <seconds> <command...> — echo the command's stdout, or nothing
# if it outstays its welcome. Silence reads as unknown focus, which plays.
with_deadline() {
  local secs="$1" out pid ticks
  shift
  out=$(mktemp "${TMPDIR:-/tmp}/buzzer-focus.XXXXXX") || return 0

  "$@" >"$out" 2>/dev/null &
  pid=$!

  ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((secs * 10)) ]; then
      # Take the children too: killing only the wrapper would leave a stuck
      # probe behind on every single turn.
      pkill -P "$pid" 2>/dev/null
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      return 0
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done

  wait "$pid" 2>/dev/null
  cat "$out" 2>/dev/null
  rm -f "$out"
  return 0
}

frontmost_app() {
  # Test/debug override. The single value "-" means "pretend focus could not be
  # detected", which is how the tests cover the unknown-focus path.
  if [ -n "${BUZZER_FAKE_FRONTMOST:-}" ]; then
    [ "$BUZZER_FAKE_FRONTMOST" = "-" ] && return 0
    printf '%s\n' "$BUZZER_FAKE_FRONTMOST"
    return 0
  fi

  with_deadline "$FOCUS_TIMEOUT_SECONDS" frontmost_app_probe
}

frontmost_app_probe() {
  case "$OS" in
    macos)
      # This exact form is load-bearing. It takes ~0.1s and needs NO
      # Accessibility or Automation permission, so users are never prompted.
      #
      # Do NOT replace it with System Events ("whose frontmost is true"): that
      # works but triggers a TCC Automation prompt.
      # Do NOT replace it with `lsappinfo info -only name`: on macOS 14 it
      # returns empty, which silently reads as "unknown" forever.
      osascript -e 'tell application "Finder" to return name of (path to frontmost application)' \
        2>/dev/null | head -n 1
      ;;
    linux)
      if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
        # Wayland has no portable way to ask "what is focused". sway can tell
        # us; other compositors stay unknown, which means PLAY.
        if command -v swaymsg >/dev/null 2>&1; then
          swaymsg -t get_tree 2>/dev/null |
            tr ',' '\n' | grep -A1 '"focused": *true' |
            grep -o '"app_id": *"[^"]*"' | head -n 1 |
            sed 's/.*"\([^"]*\)"$/\1/'
        fi
        return 0
      fi
      # Ask for the window CLASS, never the title. Titles are things like
      # "vim ~/x — Alacritty" and cannot be compared to an application name;
      # matching them loosely is what the Xcode bug was made of.
      if command -v xdotool >/dev/null 2>&1; then
        local name
        name=$(xdotool getactivewindow getwindowclassname 2>/dev/null | head -n 1)
        if [ -n "$name" ]; then
          printf '%s\n' "$name"
          return 0
        fi
        # xdotool older than 3.0 has no getwindowclassname; fall through to
        # xprop rather than guessing from the title.
      fi
      if command -v xprop >/dev/null 2>&1; then
        local id
        id=$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | grep -o '0x[0-9a-f]*' | head -n 1)
        [ -n "$id" ] || return 0
        xprop -id "$id" WM_CLASS 2>/dev/null |
          sed -n 's/.*"\([^"]*\)"$/\1/p' | head -n 1
      fi
      ;;
  esac
  return 0
}

normalize_app() {
  printf '%s' "$1" |
    sed 's/\.app$//; s/\.exe$//' |
    tr '[:upper:]' '[:lower:]' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Which frontmost-app names count as "the terminal I am running in", one per
# line. Empty output means we have no idea, which means PLAY.
terminal_candidates() {
  local override
  override=$(cfg_get terminal_app "")
  if [ -n "$override" ]; then
    printf '%s' "$override" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
      tr '[:upper:]' '[:lower:]' | grep -v '^$'
    return 0
  fi

  case $(normalize_app "${TERM_PROGRAM:-}") in
    vscode) printf 'code\ncursor\nwindsurf\nvscodium\nvisual studio code\n' ;;
    iterm) printf 'iterm2\niterm\n' ;;
    apple_terminal) printf 'terminal\n' ;;
    ghostty) printf 'ghostty\n' ;;
    warpterminal) printf 'warp\n' ;;
    hyper) printf 'hyper\n' ;;
    wezterm) printf 'wezterm\n' ;;
    # tmux tells us nothing about the outer terminal, and an unset or unknown
    # TERM_PROGRAM is the same situation: unknown -> PLAY.
    *) : ;;
  esac
}

terminal_is_frontmost() {
  local front cand
  front=$(normalize_app "$1")
  [ -n "$front" ] || return 1
  # Names must match exactly, not as substrings. "Xcode" contains "code", and a
  # substring match silenced the buzzer whenever you flipped from Cursor to
  # Xcode — precisely the moment you had looked away and needed the sound.
  #
  # Erring the other way is cheap: an app we fail to recognise as your terminal
  # just means one extra beep, while a false match means silence. Every
  # detector below is therefore expected to yield an application name, never a
  # window title.
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ "$front" = "$cand" ] && return 0
  done <<EOF
$(terminal_candidates)
EOF
  return 1
}

# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------

file_ext() {
  local base="${1##*/}"
  case "$base" in
    *.*) printf '%s\n' "${base##*.}" | tr '[:upper:]' '[:lower:]' ;;
    *) printf '\n' ;;
  esac
}

# Prints the player to use for a given file extension, or fails if there is none.
audio_backend() {
  local ext="${1-}" cmd
  case "$OS" in
    macos)
      if command -v afplay >/dev/null 2>&1; then
        echo afplay
        return 0
      fi
      ;;
    linux)
      for cmd in pw-play paplay ffplay mpv aplay; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        # aplay only understands WAV. Skip it for anything else instead of
        # letting it fail on a file it was never going to play.
        if [ "$cmd" = aplay ] && [ "$ext" != wav ]; then
          continue
        fi
        echo "$cmd"
        return 0
      done
      ;;
    windows)
      if command -v powershell >/dev/null 2>&1; then
        echo powershell
        return 0
      fi
      ;;
  esac
  return 1
}

vol_pct() { awk -v v="$1" 'BEGIN { printf "%d", v * 100 }' 2>/dev/null || echo 70; }
vol_pulse() { awk -v v="$1" 'BEGIN { printf "%d", v * 65536 }' 2>/dev/null || echo 45875; }

play_once() {
  local backend="$1" file="$2" volume="$3"
  case "$backend" in
    afplay) afplay -v "$volume" "$file" ;;
    pw-play) pw-play --volume="$volume" "$file" ;;
    paplay) paplay "--volume=$(vol_pulse "$volume")" "$file" ;;
    ffplay) ffplay -nodisp -autoexit -loglevel quiet -volume "$(vol_pct "$volume")" "$file" ;;
    mpv) mpv --no-video --really-quiet "--volume=$(vol_pct "$volume")" "$file" ;;
    aplay) aplay -q "$file" ;;
    powershell) powershell -NoProfile -Command \
      "(New-Object Media.SoundPlayer '$file').PlaySync()" ;;
  esac
}

# Fire and forget. Returns immediately; the sound outlives this process.
spawn_play() {
  local event="$1" file="$2" volume="$3" repeat="$4" backend ext

  if [ -z "$file" ]; then
    log "skip $event: no sound configured"
    return 1
  fi
  if [ ! -r "$file" ]; then
    log "skip $event: sound not readable: $file"
    return 1
  fi

  ext=$(file_ext "$file")
  backend=$(audio_backend "$ext") || backend=""

  # BUZZER_DRY_RUN records what would have played instead of playing it. The
  # test suite reads this file; it is also handy when debugging over SSH.
  # It records the intent even on a machine with no audio backend, because the
  # silence rules are what it exists to check.
  if [ -n "${BUZZER_DRY_RUN:-}" ]; then
    mkdir -p "$BUZZER_HOME" 2>/dev/null
    printf '%s|%s|%s|%s|%s\n' "$event" "$file" "$volume" "$repeat" "${backend:-none}" \
      >>"$BUZZER_HOME/played" 2>/dev/null
    log "dry-run $event: ${backend:-no-backend} $file vol=$volume repeat=$repeat"
    return 0
  fi

  if [ -z "$backend" ]; then
    log "skip $event: no audio backend for .$ext on $OS"
    return 1
  fi

  (
    trap '' HUP INT TERM
    i=0
    while [ "$i" -lt "$repeat" ]; do
      if [ "$i" -gt 0 ]; then
        sleep "$REPEAT_GAP" 2>/dev/null || sleep 1
      fi
      play_once "$backend" "$file" "$volume"
      i=$((i + 1))
    done
  ) </dev/null >/dev/null 2>&1 &

  # Detach so nothing about this process's lifetime affects the sound.
  disown 2>/dev/null || true
  log "play $event: $backend $file vol=$volume repeat=$repeat"
  return 0
}

# ---------------------------------------------------------------------------
# The silence rules
#
# This single function is the whole point of the tool, and it is also what
# `buzzer status` reports on, so what status tells you is by construction what
# the hook will actually do.
#
# Returns 0 to play, 1 to stay silent, and sets DECISION_REASON either way.
# ---------------------------------------------------------------------------

DECISION_REASON=""

decide() {
  local event="$1" payload="${2-}"
  local from to now threshold elapsed front
  DECISION_REASON=""

  # 1. Global switch.
  if [ "$(cfg_bool enabled true)" != true ]; then
    DECISION_REASON="disabled globally (enabled=false)"
    return 1
  fi

  # 1b. Per-event switch.
  if [ "$(cfg_bool "${event}_enabled" true)" != true ]; then
    DECISION_REASON="event '$event' is off (${event}_enabled=false)"
    return 1
  fi

  # 2. Quiet hours. Off by default.
  if [ "$(cfg_bool quiet_hours false)" = true ]; then
    from=$(cfg_get quiet_start 23:00)
    to=$(cfg_get quiet_end 08:00)
    now=$(now_hhmm)
    if in_quiet_window "$now" "$from" "$to"; then
      DECISION_REASON="quiet hours ($from-$to, now $now)"
      return 1
    fi
  fi

  # 3. Short turns stay silent. 'waiting' and 'subagent' are not turn-scoped,
  #    so this rule does not apply to them at all.
  case "$event" in
    done | error)
      threshold=$(cfg_num threshold_seconds 30)
      elapsed=$(turn_elapsed "$payload")
      if [ -z "$elapsed" ]; then
        # Duration unknown -> PLAY. Missing information must never cause a
        # missed notification.
        :
      elif [ "$elapsed" -lt "$threshold" ]; then
        DECISION_REASON="turn too short (${elapsed}s < ${threshold}s)"
        return 1
      fi
      ;;
  esac

  # 4. You are already looking at it.
  front=$(frontmost_app)
  if [ -n "$front" ] && terminal_is_frontmost "$front"; then
    DECISION_REASON="your terminal is frontmost ($front)"
    return 1
  fi

  # 5. Play.
  DECISION_REASON="all rules passed"
  return 0
}

# ---------------------------------------------------------------------------
# Hook mode
# ---------------------------------------------------------------------------

# Structural guarantee for rule 2: from here on nothing can reach Claude's
# stdout/stderr, and every exit path is exit 0 — including a crash.
hook_mode_shield() {
  trap 'exit 0' EXIT
  exec >/dev/null 2>&1
}

read_payload() {
  # Hooks always get JSON on stdin. When stdin is a terminal (someone running
  # this by hand) don't sit there waiting for EOF.
  if [ -t 0 ]; then
    printf ''
  else
    cat 2>/dev/null || printf ''
  fi
}

cmd_mark() {
  hook_mode_shield
  local payload id file
  ensure_config
  payload=$(read_payload)
  id=$(sanitize_id "$(json_string session_id "$payload")")
  if [ -z "$id" ]; then
    # No session id means the done hook won't find a mark, which means
    # "duration unknown", which means it plays. That is the correct fallback.
    log "mark: no session_id in payload"
    exit 0
  fi
  mkdir -p "$MARKS_DIR" 2>/dev/null
  file="$MARKS_DIR/$id"
  now_epoch >"$file" 2>/dev/null
  log "mark: $id"
  prune_marks &
  exit 0
}

cmd_hook() {
  hook_mode_shield
  local event="${1-}" payload sound volume repeat id file

  if ! is_event "$event"; then
    log "hook: unknown event '${event}'"
    exit 0
  fi

  ensure_config
  payload=$(read_payload)

  if decide "$event" "$payload"; then
    sound=$(cfg_get "${event}_sound" "$(default_sound "$event")")
    volume=$(event_volume "$event")
    repeat=$(cfg_num "${event}_repeat" 1)
    [ "$repeat" -ge 1 ] 2>/dev/null || repeat=1
    log "decision=play event=$event reason=\"$DECISION_REASON\""
    spawn_play "$event" "$sound" "$volume" "$repeat"
  else
    log "decision=silent event=$event reason=\"$DECISION_REASON\""
  fi

  # The turn is over, so the mark has done its job.
  case "$event" in
    done | error)
      id=$(sanitize_id "$(json_string session_id "$payload")")
      if [ -n "$id" ] && file=$(mark_file "$id"); then
        rm -f "$file" 2>/dev/null
      fi
      ;;
  esac

  exit 0
}

# ---------------------------------------------------------------------------
# CLI mode
# ---------------------------------------------------------------------------

# Accepts a path, a bundled sound name ("bird.wav"), or a macOS system sound
# name ("Hero"). Prints the resolved absolute path.
resolve_sound() {
  local input="$1" candidate
  for candidate in \
    "$input" \
    "$BUZZER_HOME/sounds/$input" \
    "$SCRIPT_DIR/sounds/$input" \
    "$SCRIPT_DIR/sounds/community/$input" \
    "/System/Library/Sounds/$input" \
    "/System/Library/Sounds/$input.aiff"; do
    if [ -f "$candidate" ]; then
      case "$candidate" in
        /*) printf '%s\n' "$candidate" ;;
        *) printf '%s\n' "$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")" ;;
      esac
      return 0
    fi
  done
  return 1
}

cmd_list() {
  ensure_config
  local event sound volume repeat on state
  printf '%-9s  %-3s  %-6s  %-3s  %s\n' EVENT ON VOLUME REP SOUND
  for event in $EVENTS; do
    sound=$(cfg_get "${event}_sound" "$(default_sound "$event")")
    volume=$(event_volume "$event")
    repeat=$(cfg_num "${event}_repeat" 1)
    on=$(cfg_bool "${event}_enabled" true)
    state=no
    [ "$on" = true ] && state=yes
    if [ -n "$sound" ] && [ ! -r "$sound" ]; then
      sound="$sound  (MISSING)"
    fi
    printf '%-9s  %-3s  %-6s  %-3s  %s\n' "$event" "$state" "$volume" "$repeat" "$sound"
  done
  if [ "$(cfg_bool enabled true)" != true ]; then
    printf '\nAll sounds are off: enabled=false. Turn them back on with "buzzer on".\n'
  fi
}

cmd_set() {
  local event="${1-}" input="${2-}" path
  require_event "$event" || return 1
  if [ -z "$input" ]; then
    err "usage: buzzer set <event> <path|name>"
    return 1
  fi
  if ! path=$(resolve_sound "$input"); then
    err "no such sound: $input"
    printf 'Tried it as a path, a bundled sound, and a macOS system sound.\n' >&2
    printf 'See available system sounds with "buzzer sounds".\n' >&2
    return 1
  fi
  local ext
  ext=$(file_ext "$path")
  if ! audio_backend "$ext" >/dev/null; then
    err "nothing on this machine can play a .$ext file"
    return 1
  fi
  cfg_set "${event}_sound" "$path" || {
    err "could not write $CONFIG_FILE"
    return 1
  }
  printf '%s -> %s\n' "$event" "$path"
}

cmd_test() {
  local event="${1-done}" sound volume repeat
  require_event "$event" || return 1
  ensure_config
  sound=$(cfg_get "${event}_sound" "$(default_sound "$event")")
  volume=$(event_volume "$event")
  repeat=$(cfg_num "${event}_repeat" 1)
  printf 'playing %s: %s (volume %s, %sx)\n' "$event" "$sound" "$volume" "$repeat"
  printf 'This bypasses every silence rule. Use "buzzer status" to see what a real hook would do.\n'
  if ! spawn_play "$event" "$sound" "$volume" "$repeat"; then
    err "could not play it — run 'buzzer doctor'"
    return 1
  fi
}

cmd_toggle() {
  ensure_config
  cfg_set enabled "$1" || {
    err "could not write $CONFIG_FILE"
    return 1
  }
  if [ "$1" = true ]; then
    printf 'buzzer is on\n'
  else
    printf 'buzzer is off — no event will play until "buzzer on"\n'
  fi
}

cmd_event_toggle() {
  local value="$1" event="${2-}"
  if [ -z "$event" ]; then
    err "usage: buzzer $([ "$value" = true ] && echo enable || echo disable) <event>"
    printf 'For the master switch use "buzzer on" / "buzzer off".\n' >&2
    return 1
  fi
  require_event "$event" || return 1
  ensure_config
  cfg_set "${event}_enabled" "$value" || return 1
  printf '%s is %s\n' "$event" "$([ "$value" = true ] && echo on || echo off)"
}

cmd_threshold() {
  local value="${1-}"
  case "$value" in
    '' | *[!0-9]*)
      err "usage: buzzer threshold <seconds>   (whole seconds, e.g. 30)"
      return 1
      ;;
  esac
  ensure_config
  cfg_set threshold_seconds "$value" || return 1
  printf 'turns shorter than %ss stay silent\n' "$value"
}

cmd_volume() {
  local value="${1-}" event="${2-}"
  if ! valid_volume "$value"; then
    err "usage: buzzer volume <0.0-1.0> [event]"
    return 1
  fi
  ensure_config
  if [ -n "$event" ]; then
    require_event "$event" || return 1
    cfg_set "${event}_volume" "$value" || return 1
    printf '%s volume -> %s\n' "$event" "$value"
  else
    cfg_set volume "$value" || return 1
    printf 'default volume -> %s\n' "$value"
    printf '(per-event overrides still win; see "buzzer list")\n'
  fi
}

cmd_quiet_hours() {
  local from="${1-}" to="${2-}"
  ensure_config
  case "$from" in
    off | false | none)
      cfg_set quiet_hours false || return 1
      printf 'quiet hours off\n'
      return 0
      ;;
    on | true)
      cfg_set quiet_hours true || return 1
      printf 'quiet hours on (%s-%s)\n' "$(cfg_get quiet_start 23:00)" "$(cfg_get quiet_end 08:00)"
      return 0
      ;;
  esac
  if ! hhmm_to_min "$from" >/dev/null || ! hhmm_to_min "$to" >/dev/null; then
    err "usage: buzzer quiet-hours <from> <to>   (e.g. 23:00 08:00)"
    printf '       buzzer quiet-hours off\n' >&2
    return 1
  fi
  cfg_set quiet_start "$from" || return 1
  cfg_set quiet_end "$to" || return 1
  cfg_set quiet_hours true || return 1
  printf 'quiet hours on: %s-%s' "$from" "$to"
  if [ "$(hhmm_to_min "$from")" -gt "$(hhmm_to_min "$to")" ]; then
    printf ' (wraps midnight)'
  fi
  printf '\n'
}

cmd_sounds() {
  local f found=0
  if [ -d /System/Library/Sounds ]; then
    printf 'macOS system sounds (/System/Library/Sounds):\n'
    for f in /System/Library/Sounds/*.aiff; do
      [ -f "$f" ] || continue
      printf '  %s\n' "$(basename "$f" .aiff)"
      found=1
    done
  fi
  for dir in "$BUZZER_HOME/sounds" "$SCRIPT_DIR/sounds" "$SCRIPT_DIR/sounds/community"; do
    [ -d "$dir" ] || continue
    local listed=0
    for f in "$dir"/*.wav "$dir"/*.mp3 "$dir"/*.aiff "$dir"/*.m4a; do
      [ -f "$f" ] || continue
      if [ "$listed" -eq 0 ]; then
        printf '\n%s:\n' "$dir"
        listed=1
      fi
      printf '  %s\n' "$(basename "$f")"
      found=1
    done
  done
  [ "$found" -eq 1 ] || printf 'No sounds found. Pass "buzzer set <event> <path>" a file directly.\n'
  printf '\nUse any of these by name: buzzer set done bird.wav\n'
}

cmd_status() {
  ensure_config
  local event front cand candidates verdict

  printf 'agent-buzzer %s\n' "$VERSION"
  printf 'config      %s\n' "$(tilde "$CONFIG_FILE")"
  printf 'log         %s\n' "$(tilde "$LOG_FILE")"
  printf 'platform    %s (%s)\n' "$OS" "$(uname -sr 2>/dev/null)"
  printf '\n'
  printf 'enabled            %s\n' "$(cfg_bool enabled true)"
  printf 'threshold_seconds  %s\n' "$(cfg_num threshold_seconds 30)"
  printf 'volume             %s\n' "$(cfg_get volume 0.7)"
  if [ "$(cfg_bool quiet_hours false)" = true ]; then
    printf 'quiet_hours        on, %s-%s (now %s, %s)\n' \
      "$(cfg_get quiet_start 23:00)" "$(cfg_get quiet_end 08:00)" "$(now_hhmm)" \
      "$(in_quiet_window "$(now_hhmm)" "$(cfg_get quiet_start 23:00)" "$(cfg_get quiet_end 08:00)" && echo inside || echo outside)"
  else
    printf 'quiet_hours        off\n'
  fi
  printf '\n'

  printf 'TERM_PROGRAM       %s\n' "${TERM_PROGRAM:-<unset>}"
  candidates=$(terminal_candidates | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  if [ -n "$candidates" ]; then
    printf 'your terminal      %s\n' "$candidates"
  else
    printf 'your terminal      unknown -> the "already looking at it" rule can never fire, so sounds play\n'
  fi
  front=$(frontmost_app)
  if [ -n "$front" ]; then
    printf 'frontmost app      %s' "$front"
    if terminal_is_frontmost "$front"; then
      printf '  (that IS your terminal)\n'
    else
      printf '  (not your terminal)\n'
    fi
  else
    printf 'frontmost app      unknown -> treated as "not frontmost", so sounds play\n'
  fi
  printf '\n'

  # Same code path the hook takes, so this is not decorative.
  printf 'would it play right now?\n'
  for event in $EVENTS; do
    if decide "$event" ""; then
      verdict="PLAY"
    else
      verdict="silent"
    fi
    printf '  %-9s %-7s %s\n' "$event" "$verdict" "$DECISION_REASON"
  done
  printf '\n'
  printf 'Note: outside a real hook there is no session_id, so turn duration is\n'
  printf 'unknown here and the short-turn rule cannot fire. In a real turn it can.\n'
}

cmd_doctor() {
  ensure_config
  local problems=0 warnings=0 event sound ext backend front

  printf 'agent-buzzer %s — doctor\n\n' "$VERSION"

  printf '[platform]\n'
  printf '  os              %s\n' "$OS"
  # Kernel and architecture, not `uname -a`: that carries the machine's
  # hostname, which is often someone's actual name, and the issue template
  # asks people to paste this straight into a public bug report.
  printf '  kernel          %s %s %s\n' \
    "$(uname -s 2>/dev/null)" "$(uname -r 2>/dev/null)" "$(uname -m 2>/dev/null)"
  printf '  bash            %s\n' "${BASH_VERSION:-unknown}"
  printf '  TERM_PROGRAM    %s\n' "${TERM_PROGRAM:-<unset>}"
  printf '\n'

  printf '[state]\n'
  if [ -w "$BUZZER_HOME" ] 2>/dev/null; then
    printf '  home            %s (writable)\n' "$(tilde "$BUZZER_HOME")"
  else
    printf '  home            %s (NOT WRITABLE)\n' "$(tilde "$BUZZER_HOME")"
    problems=$((problems + 1))
  fi
  if [ -r "$CONFIG_FILE" ]; then
    printf '  config          %s\n' "$(tilde "$CONFIG_FILE")"
  else
    printf '  config          %s (MISSING)\n' "$(tilde "$CONFIG_FILE")"
    problems=$((problems + 1))
  fi
  if [ -d "$MARKS_DIR" ]; then
    printf '  marks           %s (%s present)\n' "$(tilde "$MARKS_DIR")" \
      "$(find "$MARKS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
  else
    printf '  marks           %s (MISSING — turn duration will always be unknown, so everything plays)\n' "$(tilde "$MARKS_DIR")"
    warnings=$((warnings + 1))
  fi
  printf '\n'

  printf '[audio]\n'
  case "$OS" in
    macos) printf '  candidates      afplay\n' ;;
    linux) printf '  candidates      pw-play paplay ffplay mpv aplay\n' ;;
    windows) printf '  candidates      powershell (use buzzer.ps1 natively)\n' ;;
  esac
  if backend=$(audio_backend wav); then
    printf '  backend (wav)   %s -> %s\n' "$backend" "$(command -v "$backend" 2>/dev/null)"
  else
    printf '  backend (wav)   NONE FOUND — nothing will ever play\n'
    problems=$((problems + 1))
  fi
  if [ "$OS" = linux ]; then
    if backend=$(audio_backend mp3); then
      printf '  backend (mp3)   %s\n' "$backend"
    else
      printf '  backend (mp3)   none — stick to .wav sounds on this machine\n'
      warnings=$((warnings + 1))
    fi
  fi
  printf '\n'

  printf '[sounds]\n'
  for event in $EVENTS; do
    sound=$(cfg_get "${event}_sound" "$(default_sound "$event")")
    ext=$(file_ext "$sound")
    if [ -z "$sound" ]; then
      printf '  %-9s      NOT SET\n' "$event"
      problems=$((problems + 1))
    elif [ ! -r "$sound" ]; then
      printf '  %-9s      MISSING: %s\n' "$event" "$sound"
      problems=$((problems + 1))
    elif ! audio_backend "$ext" >/dev/null; then
      printf '  %-9s      UNPLAYABLE (.%s has no backend): %s\n' "$event" "$ext" "$sound"
      problems=$((problems + 1))
    else
      printf '  %-9s      ok: %s\n' "$event" "$sound"
    fi
  done
  printf '\n'

  printf '[focus detection]\n'
  case "$OS" in
    macos)
      printf '  method          osascript / Finder (needs no permissions)\n'
      ;;
    linux)
      if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
        printf '  method          Wayland (%s) — only sway is supported\n' "$WAYLAND_DISPLAY"
      else
        printf '  method          X11 via %s\n' "$(command -v xdotool 2>/dev/null || command -v xprop 2>/dev/null || echo 'nothing found')"
      fi
      ;;
    *) printf '  method          none on %s\n' "$OS" ;;
  esac
  front=$(frontmost_app)
  if [ -n "$front" ]; then
    printf '  frontmost now   %s\n' "$front"
    printf '  is that you?    %s\n' "$(terminal_is_frontmost "$front" && echo 'yes -> sounds suppressed while it is focused' || echo 'no -> sounds play')"
  else
    printf '  frontmost now   UNKNOWN\n'
    printf '  effect          unknown always means PLAY, so you get an extra beep, never silence\n'
    warnings=$((warnings + 1))
  fi
  printf '\n'

  printf '[hooks]\n'
  printf '  buzzer never edits ~/.claude/settings.json. Run "buzzer hooks" for the\n'
  printf '  snippet and add it yourself via /hooks.\n'
  if [ -f "$HOME/.claude/settings.json" ]; then
    if grep -q 'buzzer' "$HOME/.claude/settings.json" 2>/dev/null; then
      printf '  settings.json   mentions buzzer — looks wired up\n'
    else
      printf '  settings.json   exists but does not mention buzzer — hooks are probably not wired up yet\n'
      warnings=$((warnings + 1))
    fi
  else
    printf '  settings.json   not found — hooks are not wired up yet\n'
    warnings=$((warnings + 1))
  fi
  printf '\n'

  if [ "$problems" -gt 0 ]; then
    printf 'RESULT: %s problem(s), %s warning(s). Sounds may not play.\n' "$problems" "$warnings"
    return 1
  fi
  printf 'RESULT: no problems, %s warning(s).\n' "$warnings"
}

cmd_hooks() {
  local self
  self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  command -v buzzer >/dev/null 2>&1 && self=$(command -v buzzer)

  cat <<EOF
Add this to ~/.claude/settings.json yourself — buzzer will never write that
file. The safest route is Claude Code's /hooks command; a malformed
settings.json silently disables every setting in it.

{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "async": true, "command": "$self mark" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "async": true, "command": "$self hook done" } ] }
    ],
    "StopFailure": [
      { "hooks": [ { "type": "command", "async": true, "command": "$self hook error" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "async": true, "command": "$self hook waiting" } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "async": true, "command": "$self hook subagent" } ] }
    ]
  }
}

UserPromptSubmit is what makes the short-turn rule work: it records when the
turn started. Without it every turn counts as "duration unknown" and plays.

"async": true keeps the hook off the turn's critical path, so Claude never
waits on it even if something below it misbehaves.

StopFailure is what fires the 'error' sound when a turn fails or is
interrupted. If your Claude Code build does not know that event name it will
say so when you add it, and you can drop that one block; the other four are
independent.
EOF
}

cmd_log() {
  if [ -r "$LOG_FILE" ]; then
    cat "$LOG_FILE"
  else
    printf 'no log yet: %s\n' "$(tilde "$LOG_FILE")"
  fi
}

cmd_config() {
  local key="${1-}" value="${2-}"
  ensure_config
  if [ -z "$key" ]; then
    printf '# %s\n' "$CONFIG_FILE"
    cat "$CONFIG_FILE"
    return 0
  fi
  if [ -z "$value" ]; then
    cfg_get "$key" ""
    return 0
  fi
  cfg_set "$key" "$value" || return 1
  printf '%s=%s\n' "$key" "$value"
}

usage() {
  cat <<'EOF'
agent-buzzer — a sound when Claude Code finishes, so you can look away.

  buzzer list                     what plays for which event
  buzzer set <event> <path>       change a sound (path, bundled name, or macOS sound name)
  buzzer test <event>             play it now, ignoring every silence rule
  buzzer on | off                 master switch
  buzzer enable | disable <event> per-event switch
  buzzer threshold <seconds>      short-turn cutoff (default 30)
  buzzer quiet-hours <from> <to>  e.g. buzzer quiet-hours 23:00 08:00
  buzzer quiet-hours off
  buzzer volume <0.0-1.0> [event]
  buzzer sounds                   list sounds available on this machine
  buzzer status                   effective config + would it play right now, and if not why
  buzzer doctor                   audio backend, focus detection, missing files
  buzzer hooks                    print the settings.json snippet to add yourself
  buzzer log                      recent decisions
  buzzer config [key] [value]     read or write config directly
  buzzer version

Events: done, waiting, error, subagent

Used by Claude Code, not by you:
  buzzer mark                     records when a turn started (UserPromptSubmit)
  buzzer hook <event>             runs the silence rules and plays

Nothing here ever writes ~/.claude/settings.json.
EOF
}

main() {
  local cmd="${1-help}"
  [ "$#" -gt 0 ] && shift

  case "$cmd" in
    hook) cmd_hook "$@" ;;
    mark) cmd_mark "$@" ;;
    list | ls) cmd_list ;;
    set) cmd_set "$@" ;;
    test | play) cmd_test "$@" ;;
    on) cmd_toggle true ;;
    off) cmd_toggle false ;;
    enable) cmd_event_toggle true "$@" ;;
    disable) cmd_event_toggle false "$@" ;;
    threshold) cmd_threshold "$@" ;;
    quiet-hours | quiet) cmd_quiet_hours "$@" ;;
    volume) cmd_volume "$@" ;;
    sounds) cmd_sounds ;;
    status) cmd_status ;;
    doctor) cmd_doctor ;;
    hooks) cmd_hooks ;;
    log) cmd_log ;;
    config) cmd_config "$@" ;;
    version | --version | -V) printf 'agent-buzzer %s\n' "$VERSION" ;;
    help | --help | -h) usage ;;
    *)
      err "unknown command '$cmd'"
      usage >&2
      exit 64
      ;;
  esac
}

main "$@"
