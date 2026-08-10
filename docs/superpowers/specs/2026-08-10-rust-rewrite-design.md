# Rewriting agent-buzzer as a single Rust binary

Status: proposed
Date: 2026-08-10

## Why

agent-buzzer is two programs that must agree: `buzzer.sh` and `buzzer.ps1`. Keeping
them in step is most of the maintenance cost and most of the open backlog. Eleven
issues were open when this was written, plus #7 closed the same day; eight of
those twelve exist only because there are two implementations, or because shell
cannot express something safely:

| issue | why it exists |
|---|---|
| #2 hook silence shield untested | the guarantee is one line of shell, `exec >/dev/null 2>&1` |
| #3 focus-deadline child reaping untested | the deadline is implemented by spawning and killing processes |
| #5 `buzzer.ps1` has no focus deadline | the port never got the feature |
| #7 config write races | POSIX sh has no compare-and-swap |
| #8 Windows latency unmeasured | Git Bash spawns a process per operation |
| #9 `run.ps1` missing tests | a second suite that has to be kept in step |
| #11 CI never runs `run.ps1` outside Windows | a second suite nobody can run everywhere |
| #12 CONTRIBUTING overstates CI coverage | two suites, two linters, four platform combinations |

A single binary removes the class. #7 is the sharpest example: it was fixed for
`buzzer.sh` in #13, and that fix had to give up automatic stale-lock recovery
entirely, because deciding "the owner is dead" and acting on that decision are
two steps and POSIX sh has no way to fuse them. Measured: four writers racing one
abandoned lock still lost updates in 2 runs out of 10. An OS file lock has no
such problem on Unix.

## Goals

- One implementation, one test suite, one linter.
- No external programs at run time on macOS and Windows. Linux is out of scope
  for this rewrite; see #19 and #20.
- Behaviour preserved. The silence rules are the product; none of them change.
- Install stays roughly as easy as `./install.sh`, with no toolchain required.

## Non-goals

- No new features. Not quiet-hours changes (#6), not new events, not new agents.
  Those are product decisions and belong in their own issues.
- No change to the config file format or location. Existing `~/.agent-buzzer/config`
  files keep working untouched.
- No notarised macOS distribution in the first cut. Ad-hoc signing only.

## Decisions

Made with the user, in order, each one constraining the next.

1. **Distribution: prebuilt binaries on GitHub Releases.** Three targets while
   Linux is deferred: `aarch64-apple-darwin`, `x86_64-apple-darwin`,
   `x86_64-pc-windows-msvc`. `install.sh` detects platform and downloads, and on
   Linux keeps pointing at `buzzer.sh`. Users must never need a Rust toolchain.
   The two Linux targets are added by #19.
2. **Native platform work, not shell-outs.**
3. **Coexistence until parity.** The shell implementations keep working and keep
   receiving fixes until the Rust binary passes the existing suite. Only then are
   they removed.
4. **Single crate, pure decision core.**
5. **Linux platform code is deferred** to #19 (audio) and #20 (focus). Phases
   3-5 target macOS and Windows; Linux keeps `buzzer.sh`.

## Architecture

Three rings. The inner ring does not know the outer ring exists.

```
main.rs            argv -> command, nothing else
  |
  +- cli/          human-facing commands: status doctor list set hooks sounds
  |                volume threshold quiet-hours log test
  |
  +- runtime/      the only place that touches the outside world
  |    config.rs     key=value read/write, last occurrence wins
  |    marks.rs      per-session turn-start stamps
  |    logfile.rs    the debug log
  |    audio/        decode (symphonia) + per-platform output
  |    focus/        per-platform frontmost-app detection
  |
  +- rules.rs      PURE. No files, no clock, no processes, no network.
```

### The pure core

```rust
pub fn decide(event: Event, ctx: &Context) -> Decision
```

`Context` carries already-gathered facts: `enabled`, `event_enabled`,
`quiet: Option<(NaiveTime, NaiveTime)>`, `now: NaiveTime`,
`turn_elapsed: Option<Duration>`, `threshold: Duration`,
`frontmost: Option<String>`, `terminal_app: Option<String>`.

`Decision` is `Play { sound, volume, repeat, gap }` or `Silent { reason: Reason }`.

`Reason` is an enum, not a string. Today the reason is formatted text
(`"turn too short (5s < 30s)"`) and tests match substrings of it, so the wording
is load-bearing and cannot be improved without breaking tests. As an enum,
`Reason::TurnTooShort { elapsed, threshold }` is matched exactly and the user-facing
wording lives in a `Display` impl that is free to change.

The three cardinal rules become structure rather than comments:

- **Hooks never write to stdout or stderr.** Today this is the single line
  `exec >/dev/null 2>&1`, and #2 exists because deleting it leaves the suite green.
  In Rust the hook path has no way to print: commands return a value, they do not
  print, and in hook mode that value goes to the log. `#![deny(clippy::print_stdout,
  clippy::print_stderr)]` on the hook module makes the compiler enforce it.
- **Nothing blocks.** Audio happens in a detached child (see Audio). Focus
  detection is bounded by `recv_timeout`.
- **When something is unknown, play.** `Context` fields are `Option`; `None` falls
  to the play side in `decide`, pinned by tests rather than by a comment.

A panic in hook mode is caught and turned into `exit(0)`. A bug must not print a
backtrace into someone's agent session.

## Audio

### Decoding

`symphonia` directly, on every platform. Formats to enable explicitly:
`pcm`, `wav`, `aiff`, `mp3`, `isomp4`, `aac`.

**AIFF is the trap.** macOS's four stock defaults are
`/System/Library/Sounds/{Glass,Ping,Basso,Pop}.aiff`, and they are plain AIFF,
2ch/48kHz, **24-bit big-endian PCM**. `symphonia`'s AIFF reader is not a default
feature, and `rodio` (if it were used) pins symphonia with `default-features = false`,
so nothing enables it transitively. Building without it produces a binary that
compiles, runs, and cannot open any default sound on the reference platform.

`symphonia-format-riff` maps bits-per-sample to codec explicitly — 24 →
`CODEC_TYPE_PCM_S24BE` — so the exact format these files use is supported once the
feature is on.

**Required test:** a macOS-gated test that decodes all four real system files end
to end. Not a probe — a decode. This is the only thing standing between a dropped
feature flag and silent breakage for every macOS user.

Known gap, documented not fixed: AIFF-**C** with `sowt`/`twos` is restricted to
16-bit in symphonia. Affects only user-supplied sounds in an uncommon variant.

### Output

**macOS and Windows only in this rewrite.** `cpal`, whose dependencies on those
two are system frameworks (CoreAudio, WASAPI) that are always present, so there
is nothing to fail.

**Linux platform code is deferred to #19 (audio) and #20 (focus)** and is not
part of phases 3–5. Linux users keep `buzzer.sh`, which the coexistence plan was
already keeping alive until parity — so nothing regresses for them, and the two
genuinely novel pieces of the port stop blocking the two platforms that are
ready.

Gate `cpal` so it is never a Linux dependency, which is what keeps #19 open as a
choice rather than a repair:

```toml
[target.'cfg(any(target_os = "macos", target_os = "windows"))'.dependencies]
cpal = "0.18"
```

This does change what "parity" means at the phase 3 gate. It stays a
measurement, because `tests/run.sh` runs everything under `BUZZER_DRY_RUN=1`,
which records what *would* play rather than playing it — so the Linux CI leg
still exercises every silence rule and every decision, and only real playback is
absent. What it cannot claim is that a Linux user hears anything. Phase 5 must
not remove `buzzer.sh` until #19 and #20 land, or Linux users lose the tool.

**Why not just use cpal everywhere.** `cpal` declares `alsa` as a non-optional
Linux dependency, and `alsa-sys`'s build script resolves it with
`pkg_config::probe("alsa")` — no vendored, static or dlopen fallback. The produced
binary carries `DT_NEEDED libasound.so.2`, so on a host without libasound2 the
dynamic loader fails at `exec` and **the entire CLI dies at startup** — `buzzer
--version`, `buzzer hooks`, `buzzer doctor`, everything. That is strictly worse
than today, where the shell version still runs and `doctor` reports the problem
honestly. Runtime `dlopen` keeps the binary starting everywhere and degrades to
"no audio, and `doctor` says so", which is the behaviour being preserved.

Volume is a sample multiply. Repeat-N-with-gap is: decode once into memory, play,
sleep the gap, play again — blocking is fine in the child.

### Playback must outlive the hook

**Audio cannot be handed to the OS and abandoned.** `cpal` pulls samples from a
callback inside the process; when the process exits, the OS tears the client down
and the sound is cut off mid-play. (`rodio`'s `detach()` does not help — it only
survives dropping the sink inside a still-running process. Several widely-cited
answers get this wrong.)

So the hook re-execs itself detached:

```
buzzer hook done                    <- returns immediately
  └─ spawns: buzzer __play --file X --volume V --repeat N --gap MS
             stdio -> null, setsid() on Unix,
             DETACHED_PROCESS | CREATE_NO_WINDOW on Windows
```

The child initialises audio and plays; the parent exits. This is **not** a
regression: today the hook already spawns `afplay` and disowns it. Same process
count, minus the external dependency.

Spawn *before* initialising audio, and use `Command::spawn`, never `fork()` — see
the lock rule below.

## Config writes

The bug from #7, solved properly this time.

Take an exclusive OS lock, read, modify, write to a temp file, `fsync`, rename,
release.

**Lock a sidecar file, never the config itself.** On Windows `LockFileEx` locks are
*mandatory*, enforced by the kernel: an exclusive lock "denies all other processes
both read and write access". The README tells users to hand-edit
`~/.agent-buzzer/config`, so locking that file would give Windows users
`ERROR_LOCK_VIOLATION` in their editor whenever buzzer held it. Locking
`~/.agent-buzzer/.config.lock` makes the Unix-advisory / Windows-mandatory
asymmetry unobservable.

**Never delete the lock file.** `flock` locks live on the inode, not the path.
Unlinking and recreating lets a second process lock a fresh inode and proceed —
silently destroying mutual exclusion, with no error and no failing test. Create it
once with `create(true)` and leave it; it is zero bytes. An explicit test asserts
this, because a future "buzzer reset" or uninstall path is exactly where someone
would add the deletion.

**Open the lock file once per process and thread the handle through.** `flock`
locks live on the open file description, so every duplicate shares one lock: a
`fork()`ed child releasing it releases the parent's. Two `File::open` calls on the
same path within one process contend with each other and self-deadlock.

**Still use a bounded retry.** The claim "the kernel releases the lock when the
process dies, so there is no stale lock" is true on Unix but too strong on Windows:
Microsoft documents that OS-released locks are *not* released promptly and
recommends explicit unlocking. So: `try_lock` in a loop with a short deadline and
backoff, and unlock explicitly on the happy path rather than relying on `Drop`.

Readers take no lock — they see either the old file or the new one, both complete.

Format is unchanged: `key=value`, `#` comments, **last occurrence wins** (both
current implementations already resolve duplicates this way, and the test suite
depends on it).

## Focus detection

| platform | mechanism | phase |
|---|---|---|
| macOS | `NSWorkspace.frontmostApplication` via `objc2` + `objc2-app-kit` | 3 |
| Windows | `GetForegroundWindow` + `GetWindowThreadProcessId` + `QueryFullProcessImageName` | 3 |
| Linux X11 / sway | `x11rb`, and the sway socket spoken directly | deferred, #20 |

Bounded by a thread plus `recv_timeout(2s)`. A wedged call leaks a thread, which is
acceptable because the process is short-lived — and unlike the shell version there
is no child process to reap, which is what #3 and #5 are about.

**Behaviour note that must be handled:** `NSWorkspace` returns `localizedName`,
which is not the bundle filename. AppleScript reports `Visual Studio Code.app`
where `localizedName` is `Code`. A user who set `terminal_app` by hand against the
old string would silently stop matching, and would experience it as "buzzer started
beeping while I'm looking at the terminal". Match against `localizedName` **and**
the bundle filename minus `.app`, accepting either. This is a strict superset of
today's behaviour.

## Testing

Three layers.

1. **Unit tests on `rules.rs`.** Pure function, microseconds. The rule matrix is
   swept exhaustively rather than sampled by hand.
2. **The existing `tests/run.sh`, run against the Rust binary.** This is the parity
   proof, and it is why the shell suite is kept. It drives the program entirely
   from outside — argv, JSON on stdin, `BUZZER_HOME` / `BUZZER_DRY_RUN` /
   `BUZZER_FAKE_NOW` / `BUZZER_FAKE_FRONTMOST`, and files — so it can point at any
   binary. **Prerequisite:** the harness hardcodes `bash "$BUZZER"` in 22 places,
   most of them as `env VAR=... bash "$BUZZER"`. Those become a `$BUZZER_CMD`
   variable (a variable, not a shell function, because `env` cannot invoke a
   function; deliberately unquoted, so it needs a targeted shellcheck SC2086
   exemption). Behaviour-neutral, and it lands as its own PR before any Rust.
3. **Rust integration tests** for what layer 2 cannot reach: concurrent config
   writes, lock semantics, detached playback, decode of real AIFF files.

Every new test is mutation-checked — flip the behaviour it claims to protect and
confirm it fails — following the practice established in #13, where measurement
showed one intended test caught its bug only 6 times in 10 and had to be redesigned.

## Release

CI matrix, per researched constraints:

| target | runner | notes |
|---|---|---|
| aarch64-apple-darwin | `macos-latest` | nothing to install |
| x86_64-apple-darwin | `macos-13` | nothing to install |
| x86_64-pc-windows-msvc | `windows-latest` | |

Deferred with #19, recorded here so the research is not lost: Linux wants
`ubuntu-22.04` for a glibc 2.35 floor, and `ubuntu-22.04-arm` — a native runner,
free for public repos — rather than cross-compiling aarch64, which is painful
once a C library is involved.

**macOS binaries must be signed after the final post-link step.** Apple silicon
refuses to execute arm64 code without a valid signature — failure is `Killed: 9`,
exit 137, no diagnostic. Any `strip`, `objcopy` or patch step invalidates the
signature. So: no `strip` in the release profile, then `codesign -s - -f` followed
by `codesign --verify` as a CI step that fails the job. CI must also *run* the
binary it produced, since a job that only builds cannot notice this.

**`install.sh` is hand-written, not generated.** `dist`'s generated installer skips
checksum verification on macOS: it only knows `sha256sum`, which stock macOS does
not have, and on absence prints "skipping" and returns success. Ours tries
`sha256sum`, then `shasum -a 256`, then `openssl dgst -sha256`, and **aborts** if
none is available.

Quarantine only matters for browser downloads: a `curl`-fetched binary is not
quarantined, so the `install.sh` path is friction-free. Manual download plus
Archive Utility extraction *is* blocked even with an ad-hoc signature. Document
`tar xzf` from a terminal as the manual path.

**`THIRD-PARTY-NOTICES` is required.** `symphonia` is MPL-2.0. Shipping prebuilt
binaries brings notice and source-availability obligations the shell scripts never
had. Per-file copyleft does not reach our code as long as symphonia's files are not
modified.

Bundled sounds stay as files installed to `~/.agent-buzzer/sounds`, not
`include_bytes!`, because `buzzer sounds` lists them and users are meant to add
their own alongside.

## Migration

1. Harness change: `$BUZZER_CMD` in `tests/run.sh`. Own PR, no behaviour change.
2. Rust skeleton: `config`, `rules`, CLI scaffolding. `rules` unit-tested from the
   start.
3. Platform layers behind traits: audio, focus. Fakes for tests.
4. `tests/run.sh` green against the Rust binary. This is the parity gate.
5. Release pipeline, `install.sh`, `THIRD-PARTY-NOTICES`.
6. Remove `buzzer.ps1`, `tests/run.ps1`, and the PowerShell CI jobs. Tag v2.0.
   Close #5, #9, #11, #14 as superseded; revisit #2, #3, #8, #12.
   **`buzzer.sh` stays** until #19 and #20 land -- it is the only Linux
   implementation until then.

Until step 6, `buzzer.sh` remains the shipping implementation and keeps taking
fixes.

## Risks

- **Unverified platform claims.** Everything about Windows and Linux here comes
  from documentation, not measurement — no Rust toolchain and no non-macOS host was
  available while writing this. That is the same failure mode that produced three
  CI failures earlier in this project's life. The Windows lock-release timing and
  the Windows lock-release timing gets a dedicated CI test before anything
  depends on it.
- **Linux is deferred, not solved.** #19 and #20 are the two genuinely novel
  pieces of the port and they are now out of the critical path, which is the
  point -- but it means v2.0 cannot retire `buzzer.sh` until they land, and a
  half-finished port that ships anyway is how a project ends up maintaining
  three implementations instead of two.
- **Scope.** A rewrite is the classic place to lose a year. The parity gate exists
  to make "are we done" a measurement rather than an opinion.
