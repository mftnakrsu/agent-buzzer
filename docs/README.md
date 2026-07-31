# docs

## demo.gif

`README.md` points at `docs/demo.gif`, which doesn't exist yet.

The awkward part of demoing this tool: **a GIF has no sound, and the hook prints
nothing on purpose.** Record a terminal naively and you get a still image of an
idle prompt. So the demo can't show the sound — it has to show the *decision*,
and specifically the moment it decides to stay quiet. That restraint is the
product; the beep is just the delivery mechanism.

There are two ways to make one.

### Scripted (preferred)

[`demo.tape`](demo.tape) is a [VHS](https://github.com/charmbracelet/vhs)
script. It renders a GIF from a written scenario, so there's no recording, no
editing, and no drift when the CLI output changes later — just re-run it.

```sh
brew install vhs
vhs docs/demo.tape
```

It walks through `buzzer list`, `buzzer test done`, and then the frame that
matters: the same `buzzer status` run twice, once with the terminal focused
(everything `silent`) and once pretending you've switched to a browser
(everything `PLAY`). Side by side, those two frames explain the whole tool
without a single decibel.

Tweak the `Sleep` values if it feels rushed. Keep the result under 2MB so it
loads on a phone.

### Real screen recording

More authentic, more work, and it goes stale the moment the output changes. Use
it as a second GIF further down the README rather than the header.

1. `Cmd+Shift+5` → *Record Selected Portion*, framed on the terminal plus enough
   desktop to see you switch apps.
2. Start something genuinely long in Claude Code, switch to a browser, and let
   the sound arrive while you're clearly elsewhere.
3. Then ask a one-line question and let it answer with **nothing happening.**
   This is the half people don't expect and the reason the tool is bearable.
4. Add a caption where the sound fires — the viewer can't hear it.
5. Convert: `brew install gifski && gifski --fps 12 --width 1000 -o docs/demo.gif recording.mov`

Don't record anything with tokens, private paths, or client names on screen.
