# Parameterise the test harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `tests/run.sh` run against any buzzer implementation, not just `buzzer.sh`, so the Rust port can prove parity against the existing suite instead of claiming it.

**Architecture:** Replace the 22 hardcoded `bash "$BUZZER"` invocations with a single bash array `BUZZER_CMD`, defaulting to `(bash "$ROOT/buzzer.sh")` and overridable by a `BUZZER_BIN` environment variable. Behaviour-neutral: with `BUZZER_BIN` unset, every test runs exactly as it does today.

**Tech Stack:** POSIX-ish bash 3.2 (macOS system bash), shellcheck.

## Global Constraints

- **Phase 1 of 5** from `docs/superpowers/specs/2026-08-10-rust-rewrite-design.md`. No Rust in this plan.
- The suite must stay green on macOS, Linux and Git Bash: `./tests/run.sh` → `all good: 79 passed`.
- `shellcheck buzzer.sh install.sh tests/run.sh` must exit 0. CI runs Ubuntu's apt shellcheck, which is older than Homebrew's.
- **bash 3.2 compatible.** macOS ships bash 3.2 and the suite header says it is tested there. No `declare -n`, no associative arrays, no `${var^^}`. Indexed arrays and `"${arr[@]}"` are fine in 3.2.
- Do not change any test's behaviour, name, or assertion. This plan only changes *how the program under test is invoked*.
- `buzzer.sh` itself is not modified.

---

### Task 1: Introduce `BUZZER_CMD` and switch every call site to it

**Files:**
- Modify: `tests/run.sh:30-31` (declaration), `tests/run.sh:16-23` (header comment), `tests/run.sh:1156` (banner), and the 22 call sites listed in Step 3
- Test: `tests/run.sh` is itself the test; verification is running it two ways

**Interfaces:**
- Consumes: nothing.
- Produces: `BUZZER_CMD` — a bash indexed array holding the argv prefix for the program under test, always invoked as `"${BUZZER_CMD[@]}"`. `BUZZER_BIN` — optional environment variable; when non-empty it is used as a single executable path and replaces the default `bash <script>` prefix. `BUZZER` — retained, now holding the path of whatever is under test, used only for display.

**Why an array and not a string.** Several call sites read `env VAR=... bash "$BUZZER" ...`. `env(1)` execs a real program and cannot invoke a shell function, so a function is not an option. A plain string would need to be left unquoted to word-split, which breaks on any checkout path containing a space and needs a shellcheck SC2086 exemption. An indexed array expanded as `"${BUZZER_CMD[@]}"` splits on elements rather than whitespace, so it is correct for paths with spaces and needs no exemption.

- [ ] **Step 1: Write the failing test — a wrapper that stands in for "another implementation"**

This is the acceptance test for the whole task: if the suite passes while driven through an external executable that is *not* invoked as `bash <script>`, the parameterisation genuinely works.

Create `/tmp/buzzer-wrapper-test/buzzer-wrapper`:

```bash
mkdir -p /tmp/buzzer-wrapper-test
cat > /tmp/buzzer-wrapper-test/buzzer-wrapper <<EOF
#!/bin/sh
# Stands in for a compiled binary: a real executable on disk, invoked directly
# rather than as an argument to bash.
exec bash "$(cd -- "$(dirname -- "$0")" && pwd)/buzzer.sh" "\$@"
EOF
chmod +x /tmp/buzzer-wrapper-test/buzzer-wrapper
```

Note: run that snippet from the repository root, so `$(cd ... dirname $0)` resolves against the repo. If in doubt, hardcode the absolute path to `buzzer.sh` in the wrapper — it is a throwaway file.

- [ ] **Step 2: Run it to make sure it fails**

Run:

```bash
BUZZER_BIN=/tmp/buzzer-wrapper-test/buzzer-wrapper ./tests/run.sh
```

Expected: `all good: 79 passed` — but that is a **false pass**. `BUZZER_BIN` is not read by anything yet, so the suite silently ignored it and tested `buzzer.sh` as usual. Prove the variable is genuinely unwired before continuing:

```bash
BUZZER_BIN=/nonexistent/definitely-not-a-buzzer ./tests/run.sh 2>&1 | tail -3
```

Expected: `all good: 79 passed`. A suite that passes while pointed at a path that does not exist is the failing state this task fixes. Record that output; Step 6 re-runs the same command and requires the opposite.

- [ ] **Step 3: Replace the declaration and all 22 call sites**

In `tests/run.sh`, replace lines 30-31:

```bash
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
BUZZER="$ROOT/buzzer.sh"
```

with:

```bash
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)

# The program under test. Set BUZZER_BIN to run this same suite against a
# different implementation — that is how the Rust port proves parity instead of
# claiming it. Unset, everything behaves exactly as before.
#
# An array rather than a string: paths can contain spaces, and several call
# sites invoke this through env(1), which execs a real program and cannot call
# a shell function.
if [ -n "${BUZZER_BIN:-}" ]; then
  BUZZER="$BUZZER_BIN"
  BUZZER_CMD=("$BUZZER_BIN")
else
  BUZZER="$ROOT/buzzer.sh"
  BUZZER_CMD=(bash "$BUZZER")
fi
```

Then replace every occurrence of `bash "$BUZZER"` with `"${BUZZER_CMD[@]}"`. There are 22, at lines 128, 134, 527, 556, 605, 627, 638, 647, 656, 912, 913, 914, 915, 916, 917, 919, 977, 987, 1005, 1027, 1061, 1120.

**Do the substitution BEFORE inserting the declaration block, not after.** The
declaration in the `else` branch above is written as `(bash "$ROOT/buzzer.sh")`
rather than `(bash "$BUZZER")` for the same reason. Get either wrong and the
substitution rewrites the declaration into `BUZZER_CMD=("${BUZZER_CMD[@]}")` —
an array defined in terms of itself. Under `set -u` that fails at start-up with
`BUZZER_CMD[@]: unbound variable`, and the substitution count comes out at 23
instead of 22, which is the tell.

```bash
perl -pi -e 's/bash "\$BUZZER"/"\$\{BUZZER_CMD\[\@\]\}"/g' tests/run.sh
```

Verify the count:

```bash
grep -Fc '"${BUZZER_CMD[@]}"' tests/run.sh   # expect exactly 22, not 23
grep -Fc 'bash "$BUZZER"' tests/run.sh       # expect 0
```

`-F` matters: without it `grep` treats the pattern as a basic regular expression, `${...[@]}` does not match literally, and you get a confident `0` for a line that is present 22 times.

- [ ] **Step 4: Update the header comment**

The header at `tests/run.sh:16-23` lists the environment variables the suite uses to fake the outside world. `BUZZER_BIN` belongs there. Replace the line:

```
# How it fakes the outside world (all of these are read by buzzer.sh itself):
```

with:

```
# BUZZER_BIN            the implementation under test; unset means buzzer.sh
#
# How it fakes the outside world (all of these are read by buzzer.sh itself):
```

- [ ] **Step 5: Run the default path — must be unchanged**

Run:

```bash
./tests/run.sh
```

Expected: `all good: 79 passed`. Identical to before the change.

- [ ] **Step 6: Run the two BUZZER_BIN cases**

Run:

```bash
BUZZER_BIN=/tmp/buzzer-wrapper-test/buzzer-wrapper ./tests/run.sh 2>&1 | tail -2
```

Expected: `all good: 79 passed` — and this time it means something, because the wrapper is a real executable invoked directly.

Run:

```bash
BUZZER_BIN=/nonexistent/definitely-not-a-buzzer ./tests/run.sh 2>&1 | grep -E 'passed|failed' | tail -2
```

Expected: `failures: 14 passed, 65 failed`. This is the assertion that Step 2 recorded as broken. If it still reports `79 passed`, a call site was missed — re-run the two `grep -c` commands from Step 3.

The 14 that still pass are worth knowing about rather than treating as noise: they are tests that either never invoke the program or assert silence, and a program that cannot be executed produces no sound, which satisfies `assert_silent`. They are weak against a completely absent implementation. That is not a problem for this task, but it matters at the phase 3 parity gate — a Rust binary that crashed on start-up would still collect those 14.

- [ ] **Step 7: Run shellcheck**

Run:

```bash
shellcheck buzzer.sh install.sh tests/run.sh
```

Expected: no output, exit 0. In particular there must be no SC2086 (unquoted expansion) — the array form avoids it. If shellcheck reports SC2068 (`"${arr[@]}"` vs `${arr[@]}`), a replacement lost its quotes; fix the quoting rather than adding a disable comment.

- [ ] **Step 8: Commit**

```bash
git add tests/run.sh
git commit -m "Let the suite run against any buzzer implementation

The silence rules are the specification, and the suite already drives the
program entirely from outside -- argv, JSON on stdin, BUZZER_HOME and the
BUZZER_FAKE_* variables, and files. The one thing stopping it testing a
different implementation was 22 hardcoded 'bash \$BUZZER' invocations.

Those become a BUZZER_CMD array, overridable with BUZZER_BIN. Unset, nothing
changes: 79 passed before and after.

An array rather than a string because several call sites go through env(1),
which execs a real program and cannot call a shell function, and because a
word-split string would break on any checkout path containing a space."
```

- [ ] **Step 9: Clean up the throwaway wrapper**

```bash
rm -rf /tmp/buzzer-wrapper-test
```

---

### Task 2: Prove the parity gate in CI

**Files:**
- Modify: `.github/workflows/ci.yml` (the `test` job, after the existing "Silence rules (bash)" step)

**Interfaces:**
- Consumes: `BUZZER_BIN` from Task 1.
- Produces: a CI step that fails if `BUZZER_BIN` ever stops being honoured.

Task 1's wiring is only load-bearing later, when the Rust binary exists. Between now and then nothing exercises it, so it can rot silently — and the day it is needed is the worst day to discover it broke. This step keeps it honest for the cost of one extra suite run.

- [ ] **Step 1: Write the failing test — add the CI step**

In `.github/workflows/ci.yml`, immediately after the existing step:

```yaml
      - name: Silence rules (bash)
        shell: bash
        run: ./tests/run.sh
```

add:

```yaml
      # The same suite, driven through an external executable rather than as an
      # argument to bash. This is the mechanism the Rust port will use to prove
      # parity, so it has to keep working long before anything depends on it.
      - name: Silence rules (bash, via BUZZER_BIN)
        shell: bash
        run: |
          set -eu
          wrapper="$RUNNER_TEMP/buzzer-wrapper"
          printf '#!/bin/sh\nexec bash "%s/buzzer.sh" "$@"\n' "$PWD" > "$wrapper"
          chmod +x "$wrapper"
          BUZZER_BIN="$wrapper" ./tests/run.sh
```

- [ ] **Step 2: Verify the workflow file is valid YAML**

Run:

```bash
ruby -ryaml -e "YAML.load_file('.github/workflows/ci.yml'); puts 'valid'"
```

Expected: `valid`. Ruby is used rather than `python3 -c "import yaml"` because PyYAML is not in the standard library and is absent on a stock macOS, where that command dies with `ModuleNotFoundError` and reads like a broken workflow file. If Ruby is also unavailable, skip this step — GitHub rejects an unparseable workflow immediately, so the next step catches it anyway.

- [ ] **Step 3: Verify the step locally, exactly as CI will run it**

Run from the repository root:

```bash
RUNNER_TEMP=$(mktemp -d) bash -c '
  set -eu
  wrapper="$RUNNER_TEMP/buzzer-wrapper"
  printf "#!/bin/sh\nexec bash \"%s/buzzer.sh\" \"\$@\"\n" "$PWD" > "$wrapper"
  chmod +x "$wrapper"
  BUZZER_BIN="$wrapper" ./tests/run.sh
' 2>&1 | tail -2
```

Expected: `all good: 79 passed`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "CI: run the suite through BUZZER_BIN as well

The BUZZER_BIN path has no user until the Rust binary exists, which means it
can rot unnoticed and will be discovered broken on exactly the day it matters.
One extra suite run per platform keeps it honest."
```

- [ ] **Step 5: Open the pull request**

```bash
git push -u origin docs/rust-rewrite-plan-1
gh pr create --title "Let the suite run against any buzzer implementation" --base main
```

Wait for all five CI jobs to pass — including `tests (windows-latest)`, which is where Git Bash differences surface. Do not merge on four green jobs.

---

## Remaining phases

Each gets its own plan, written when its predecessor lands, because each one's
detail depends on what the previous phase actually produced.

| phase | scope | done when |
|---|---|---|
| 2 | Rust skeleton: `config.rs`, `rules.rs` (pure, exhaustively unit-tested), CLI dispatch, `status`/`list`/`config`/`version`/`hooks`. No audio, no focus. | `cargo test` green; the subset of `tests/run.sh` that does not need audio or focus passes under `BUZZER_BIN` |
| 3 | Platform layers: `symphonia` decode with `aiff` enabled, `cpal` output on macOS/Windows, `dlopen`'d ALSA on Linux, detached `__play`, focus detection on four platforms | all 79 tests pass under `BUZZER_BIN` on all three CI platforms — **this is the parity gate** |
| 4 | Release: five-target matrix, ad-hoc `codesign` plus verification, hand-written `install.sh` with a real checksum fallback chain, `THIRD-PARTY-NOTICES` | a tagged release installs and runs on a clean machine per platform |
| 5 | Remove `buzzer.ps1`, `tests/run.ps1` and the PowerShell CI jobs; tag v2.0; close #5, #9, #11, #14; revisit #2, #3, #8, #12 | `main` has one implementation |

## Known wrinkle for phase 3

Not every test is implementation-neutral. `test_hook_returns_when_focus_detection_hangs`
(`tests/run.sh:1104`) puts fake `osascript`, `xdotool`, `xprop` and `swaymsg`
executables on `PATH` and asserts the hook still returns quickly. That test
encodes *how* the shell version detects focus, not *what* the product does — a
Rust binary using platform APIs never consults `PATH` at all, so the test would
pass for the wrong reason.

Do not "fix" it by deleting it during phase 3. The behaviour it protects — a
wedged focus detector must not stall the hook — is real and applies to both
implementations. It needs a Rust-side equivalent (a fake `Frontmost` that sleeps,
asserting the 2s deadline fires) before the shell-specific version is retired in
phase 5. Audit the full suite for the same pattern at the start of phase 3
rather than discovering it at the gate.
