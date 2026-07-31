# agent-buzzer demo, rendered by VHS: https://github.com/charmbracelet/vhs
#
#     brew install vhs
#     vhs docs/demo.tape
#
# Re-run it whenever the CLI output changes — that is the whole point of
# scripting the demo instead of screen-recording it once and letting it rot.
#
# What this has to communicate, given that a GIF has no sound and the hook
# deliberately prints nothing: not "a sound plays", but "it knows when NOT to".
# So the last screen deliberately does NOT clear between the two status runs —
# seeing `silent` and `PLAY` stacked in one frame is the entire pitch, and
# splitting them across two frames throws that away.

Output docs/demo.gif

Set Shell bash
Set FontSize 18
Set Width 1100
Set Height 400
Set Padding 22
Set TypingSpeed 28ms
Set BorderRadius 8

# Matched to docs/banner.png: near-black, with the same green as the wordmark.
Set Theme { "background": "#0A0A0A", "foreground": "#E6E6E6", "cursor": "#4ADE80", "selection": "#264F36", "black": "#0A0A0A", "red": "#F87171", "green": "#4ADE80", "yellow": "#FACC15", "blue": "#60A5FA", "magenta": "#C084FC", "cyan": "#22D3EE", "white": "#E6E6E6", "brightBlack": "#6B7280", "brightRed": "#FCA5A5", "brightGreen": "#86EFAC", "brightYellow": "#FDE047", "brightBlue": "#93C5FD", "brightMagenta": "#D8B4FE", "brightCyan": "#67E8F9", "brightWhite": "#FFFFFF" }

# VHS runs the shell under ttyd, which does not set TERM_PROGRAM the way a real
# terminal does. Set it here so the "that IS your terminal" branch can fire at
# all — in real use your terminal provides this and you never think about it.
Hide
Type "export TERM_PROGRAM=vscode" Enter
Type "clear" Enter
Show

Sleep 600ms

Type "buzzer list"
Enter
Sleep 2800ms

Type "buzzer test done"
Enter
Sleep 2200ms

Type "clear" Enter
Sleep 400ms

# Both sides of the comparison fake the frontmost app, and both are shown doing
# it. A GIF cannot alt-tab, and quietly faking only the half that flatters the
# tool would be a cheat. The decision logic underneath is entirely real.
Type "# a GIF can't alt-tab, so we tell it what's in front:"
Enter
Sleep 400ms

Type "export BUZZER_FAKE_FRONTMOST='Cursor.app'    # looking at the terminal"
Enter
Type "buzzer status | grep -A4 'would it'"
Enter
Sleep 3400ms

Type "export BUZZER_FAKE_FRONTMOST='Google Chrome.app'    # looked away"
Enter
Type "buzzer status | grep -A4 'would it'"
Enter
Sleep 4200ms
