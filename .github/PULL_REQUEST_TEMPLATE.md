<!-- Adding a sound? Delete the "Code" section. Changing code? Delete the
     "Sound" section. Both? Keep both. -->

## What this changes

<!-- One or two sentences. -->

## Sound

- **File:** `sounds/community/`
- **Origin:** <!-- your own recording / your own synthesis / link to the source -->
- **License:** <!-- e.g. CC0, public domain, MIT. Link the exact page for anything you didn't make. -->
- **Length:**
- **Why it wears well on the fortieth listen:**

- [ ] Under 2 seconds
- [ ] Normalised, peaking around -3 dBFS, not clipping
- [ ] Starts and ends near zero amplitude, so it doesn't click
- [ ] WAV or MP3
- [ ] Added a row to the table in `sounds/community/README.md`

## Code

- [ ] `./tests/run.sh` passes
- [ ] New or changed behaviour in the silence rules has a test
- [ ] `shellcheck buzzer.sh install.sh tests/run.sh` is clean
- [ ] `buzzer.ps1` kept behaviourally in step (and `tests/run.ps1` if the rules changed)

Confirm none of these got broken — they matter more than any feature:

- [ ] Hooks still return immediately; playback is still fire-and-forget
- [ ] Hooks still print nothing to stdout or stderr
- [ ] Hooks still exit 0 on every path, including failures
- [ ] Unknown focus and unknown turn duration still mean **play**, not silence
- [ ] Nothing writes `~/.claude/settings.json`
- [ ] No new runtime dependencies

## How you tested it

<!-- Real output beats a description. Which OS and terminal? -->
