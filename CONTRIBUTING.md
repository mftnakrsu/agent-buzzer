# Contributing

Two things are wanted more than anything else: **a good sound**, and **an
adapter for another agent**. Everything else is welcome too.

## Agent adapters

Claude Code is the only agent wired up today, and that is the most obvious gap
in the project. The good news is that the gap is narrow: the silence rules,
focus detection, playback, config and CLI are all agent-agnostic already. An
adapter only has to answer three questions — how the agent announces events, how
a turn is identified, and how to tell which terminal it runs in.

[The README explains each one](README.md#adding-an-agent), using the Claude Code
adapter as the worked example. `tests/run.sh` is the specification: it encodes
every silence rule as an executable assertion, so an adapter that keeps those
green behaves correctly by construction.

Codex, Cursor's agent, Gemini CLI and Antigravity are all unclaimed. Open an
issue before you start if you want to avoid two people building the same one.

## Sound packs

A notification sound is a strange design problem: you will hear it fifty times a
day, forever. Most sounds that seem fine once are unbearable by the fortieth
time. So the bar is less about audio quality and more about whether it wears
well.

Open a PR adding your file to `sounds/community/` and a row to the table in
[`sounds/community/README.md`](sounds/community/README.md).

**Requirements — a PR missing any of these can't be merged:**

1. **You can license it.** Either you made it yourself, or it is provably free to
   redistribute. State which in the PR, and link the license or source for
   anything you did not make. "I found it on a free sounds site" is not enough;
   link the exact page and its license terms. This is the one we are strict
   about, because everyone who clones the repo inherits the licensing problem.
2. **Under 2 seconds.** Ideally under 500ms. Notification, not composition.
3. **Normalised**, peaking around -3 dBFS. Not maxed out — a sound that clips
   is harsh on laptop speakers.
4. **No clicks.** Start and end at or near zero amplitude, with a short fade if
   needed. A click is the fastest way to make a pleasant sound annoying.
5. **WAV or MP3.** WAV plays everywhere, including the Linux `aplay` fallback.
   Mono is fine and usually better.
6. **Say why it wears well.** One or two sentences in the PR description: why is
   this still fine on the fortieth listen? "Short, soft attack, no sharp
   transient, sits above voice frequencies so it cuts through music" is the kind
   of answer that makes a reviewer's job easy.

Things that tend to get turned down: anything longer than a second, anything
with a hard transient at the start, speech, anything recognisable as a brand's
sound, and anything you cannot license.

If you want a starting point, [`tools/make-sounds.py`](tools/make-sounds.py)
generates the bundled `bird.wav` from nothing but `math` and `wave`, and is
about 100 lines. Synthesised sounds have no licensing questions at all, which
makes them the easiest kind to accept.

## Code

Rules that come before style, taste, or features:

1. **Hooks never block.** Playback is fire-and-forget. If Claude ever waits on
   audio, the whole point of the tool is gone.
2. **Hooks never print.** Anything on stdout can land inside somebody's Claude
   session. Diagnostics go to `~/.agent-buzzer/log`.
3. **Hooks always exit 0.** Fail open. A buzzer that reports errors into a
   session is worse than one that misses a beep.
4. **Unknown means play.** Cannot detect focus? Cannot measure the turn? Play.
   Missing a notification is a worse failure than one extra beep. There are
   comments saying this next to the code; please don't "fix" them.
5. **Nothing writes `~/.claude/settings.json`.** Not the CLI, not the installer,
   not a helper. A malformed settings.json silently disables every setting in
   it. We print a snippet and let people paste it.
6. **No dependencies.** No jq, no Python at runtime, no daemon, no package
   manager. Bash and PowerShell parse the config in a few lines each, which is
   why the config is `key=value` and not JSON.

### Working on it

```sh
./tests/run.sh              # all of it, about 15 seconds
./tests/run.sh quiet        # just the tests whose name matches "quiet"
pwsh -File tests/run.ps1    # the Windows port (runs anywhere pwsh runs)
shellcheck buzzer.sh install.sh tests/run.sh
```

```powershell
# -Path takes one file at a time, hence the loop.
foreach ($f in 'buzzer.ps1', 'tests/run.ps1') {
    Invoke-ScriptAnalyzer -Path $f -Settings ./PSScriptAnalyzerSettings.psd1
}
```

Both suites and both linters run in CI on macOS, Linux and Windows. The
PowerShell suite is worth running even on a Mac — `pwsh` is happy there, and it
catches the kind of bug that would otherwise only show up on someone else's
machine.

New behaviour in the silence rules needs a test. They are pure logic, they are
the entire product, and they are cheap to test — `tests/run.sh` fakes the clock,
the frontmost app and the audio backend through environment variables that
`buzzer.sh` reads (`BUZZER_FAKE_NOW`, `BUZZER_FAKE_FRONTMOST`,
`BUZZER_DRY_RUN`), so no test needs a GUI or a speaker.

The runner is plain bash rather than [bats](https://github.com/bats-core/bats-core)
for the same reason there are no runtime dependencies: it has to run unchanged
on macOS, Linux, and Git Bash on Windows without anyone installing anything
first. It gives you named tests, filtering (`./tests/run.sh quiet`) and
assertion helpers, which is all bats was going to be used for here.

Please keep `shellcheck` clean, and keep the two implementations behaviourally
in step: if you add a rule to `buzzer.sh`, add it to `buzzer.ps1` and to both
test suites. macOS is the reference platform, so when in doubt, match what it
does.

### Platform notes worth knowing before you change them

These were tested, and the comments in the code say so:

- macOS focus detection uses `osascript` against **Finder**. Not System Events
  (needs an Automation permission prompt) and not `lsappinfo` (returns empty on
  macOS 14 while looking correct).
- macOS audio uses `afplay`. Backgrounding it returns in about a millisecond.
- `find -exec ... +` has to query `ARG_MAX`, which fails in sandboxed
  environments. Use `\;`.
