#!/usr/bin/env sh
#
# agent-buzzer installer.
#
#   ./install.sh              install to ~/.local/bin
#   PREFIX=/usr/local/bin ./install.sh
#   ./install.sh --uninstall
#
# What it does: copies buzzer.sh to $PREFIX/buzzer, copies the bundled sounds to
# ~/.agent-buzzer/sounds, creates a default config if there isn't one, and
# prints the hook snippet.
#
# What it deliberately does NOT do: touch ~/.claude/settings.json. That file is
# yours. A malformed settings.json silently disables every setting in it, so an
# installer has no business rewriting it — you add the hooks yourself, ideally
# through Claude Code's /hooks command.

set -eu

PREFIX="${PREFIX:-$HOME/.local/bin}"
BUZZER_HOME="${BUZZER_HOME:-$HOME/.agent-buzzer}"
SRC_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TARGET="$PREFIX/buzzer"

say() { printf '%s\n' "$1"; }
die() {
  printf 'install: %s\n' "$1" >&2
  exit 1
}

uninstall() {
  if [ -e "$TARGET" ]; then
    rm -f "$TARGET"
    say "removed $TARGET"
  else
    say "nothing at $TARGET"
  fi
  say ""
  say "Left alone on purpose:"
  say "  $BUZZER_HOME  (your config, sounds and log)"
  say "  ~/.claude/settings.json  (remove the buzzer hooks yourself, via /hooks)"
  say ""
  say "To delete the config too:  rm -rf $BUZZER_HOME"
  exit 0
}

case "${1-}" in
  --uninstall | uninstall) uninstall ;;
  -h | --help)
    say "usage: ./install.sh [--uninstall]    (honours \$PREFIX, default ~/.local/bin)"
    exit 0
    ;;
  '') ;;
  *) die "unknown option '$1'" ;;
esac

[ -f "$SRC_DIR/buzzer.sh" ] || die "buzzer.sh not found next to this script"

case "$(uname -s 2>/dev/null || echo unknown)" in
  Darwin | Linux) ;;
  *)
    say "Note: this installer covers macOS and Linux."
    say "On Windows use buzzer.ps1 directly — see the README."
    ;;
esac

# 1. The script itself.
mkdir -p "$PREFIX"
cp "$SRC_DIR/buzzer.sh" "$TARGET"
chmod +x "$TARGET"
say "installed $TARGET"

# 2. Bundled sounds, so they survive you deleting this checkout.
mkdir -p "$BUZZER_HOME/sounds" "$BUZZER_HOME/marks"
if [ -d "$SRC_DIR/sounds" ]; then
  for f in "$SRC_DIR/sounds"/*.wav "$SRC_DIR/sounds"/*.mp3 "$SRC_DIR/sounds"/*.aiff; do
    [ -f "$f" ] || continue
    cp "$f" "$BUZZER_HOME/sounds/"
  done
  say "copied sounds to $BUZZER_HOME/sounds"
fi

# 3. A config, if there isn't one already. Never overwrite an existing one.
if [ -f "$BUZZER_HOME/config" ]; then
  say "kept your existing config at $BUZZER_HOME/config"
else
  "$TARGET" list >/dev/null 2>&1 || true
  say "wrote a default config to $BUZZER_HOME/config"
fi

# 4. Is it actually reachable?
say ""
if command -v buzzer >/dev/null 2>&1; then
  say "buzzer is on your PATH: $(command -v buzzer)"
else
  say "WARNING: $PREFIX is not on your PATH."
  say "Add this to your shell profile (~/.zshrc, ~/.bashrc):"
  say ""
  say "    export PATH=\"$PREFIX:\$PATH\""
  say ""
  say "Until then, call it by full path: $TARGET"
fi

say ""
say "Next: hear it once, then wire up the hooks."
say ""
say "    $TARGET test done"
say "    $TARGET hooks      # prints the snippet to add to ~/.claude/settings.json"
say "    $TARGET doctor     # checks audio + focus detection"
say ""
say "This installer has not touched ~/.claude/settings.json, and neither will"
say "buzzer. Add the hooks yourself — Claude Code's /hooks command is safest."
