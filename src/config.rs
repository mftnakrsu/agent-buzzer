//! The config file: `key=value`, one per line, `#` starts a comment.
//!
//! Same file, same keys and same parsing rules as `buzzer.sh`, because both
//! implementations read one another's files during the transition and a user's
//! existing config must keep working untouched.
//!
//! Two rules from that parser are load-bearing and easy to get wrong:
//!
//! * **The last occurrence of a key wins.** Both shell implementations resolve
//!   duplicates that way and `tests/run.sh` depends on it -- its `set_cfg`
//!   helper appends rather than rewriting.
//! * **A malformed value is not an error.** It falls back to the default, so a
//!   typo can never stop a notification. Nothing in here returns `Err` for bad
//!   content; the only errors are I/O.

// Built and tested before anything calls it; the CLI that does is the next
// step. Remove this the moment `cli/` exists -- a permanent allow(dead_code)
// is how genuinely unreachable code hides.
#![allow(dead_code)]

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How long a write waits for another writer before giving up and saying so.
/// Only CLI commands write; no hook path does, so waiting here can never delay
/// an agent turn.
const LOCK_TIMEOUT: Duration = Duration::from_secs(5);
const LOCK_RETRY_GAP: Duration = Duration::from_millis(20);

pub struct Config {
    path: PathBuf,
    lock_path: PathBuf,
}

/// A parsed view of the file. Reading is snapshot-based: parse once, answer
/// many questions, never re-read halfway through a decision.
#[derive(Debug, Default, Clone)]
pub struct Values(HashMap<String, String>);

impl Values {
    pub fn get<'a>(&'a self, key: &str) -> Option<&'a str> {
        self.0
            .get(key)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
    }

    pub fn str_or<'a>(&'a self, key: &str, fallback: &'a str) -> &'a str {
        self.get(key).unwrap_or(fallback)
    }

    /// `true`/`1`/`yes`/`on` and `false`/`0`/`no`/`off`, case-insensitively.
    /// Anything else -- including a typo, and including an empty value -- is
    /// the default. Mirrors `cfg_bool`.
    pub fn bool_or(&self, key: &str, fallback: bool) -> bool {
        match self.get(key).map(|v| v.to_ascii_lowercase()) {
            Some(v) => match v.as_str() {
                "true" | "1" | "yes" | "on" => true,
                "false" | "0" | "no" | "off" => false,
                _ => fallback,
            },
            None => fallback,
        }
    }

    /// A non-negative integer, or the default. Mirrors `cfg_num`: a negative
    /// number, a float, or anything non-numeric all fall back rather than
    /// erroring.
    pub fn u64_or(&self, key: &str, fallback: u64) -> u64 {
        match self.get(key) {
            Some(v) if !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()) => {
                v.parse().unwrap_or(fallback)
            }
            _ => fallback,
        }
    }

    /// A volume in 0.0..=1.0, or the default. Mirrors `valid_volume`: out of
    /// range falls back rather than making playback fail, because a silent
    /// failure here is a missed notification.
    pub fn volume_or(&self, key: &str, fallback: f32) -> f32 {
        match self.get(key).and_then(|v| v.parse::<f32>().ok()) {
            Some(v) if (0.0..=1.0).contains(&v) => v,
            _ => fallback,
        }
    }
}

/// Parses the file's text. Separate from any I/O so the parsing rules can be
/// tested without touching a disk.
pub fn parse(text: &str) -> Values {
    let mut map = HashMap::new();
    for line in text.lines() {
        // Strip a trailing CR so a file written on Windows, or edited there and
        // synced, parses identically. buzzer.sh does the same.
        let line = line.strip_suffix('\r').unwrap_or(line);
        let line = line.trim_start();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() {
            continue;
        }
        // Later lines overwrite earlier ones: last occurrence wins.
        map.insert(key.to_string(), value.trim().to_string());
    }
    Values(map)
}

impl Config {
    pub fn new(dir: &Path) -> Self {
        Config {
            path: dir.join("config"),
            // The lock is a sidecar, never the config itself. On Windows,
            // LockFileEx locks are mandatory rather than advisory -- an
            // exclusive lock denies all other processes read and write access
            // -- so locking the config would hand ERROR_LOCK_VIOLATION to any
            // user hand-editing it, which the README tells them to do.
            lock_path: dir.join(".config.lock"),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Reads and parses. A missing or unreadable file is empty defaults, not an
    /// error -- an unreadable config must not stop a notification.
    pub fn read(&self) -> Values {
        let mut text = String::new();
        match File::open(&self.path) {
            Ok(mut f) => {
                let _ = f.read_to_string(&mut text);
            }
            Err(_) => return Values::default(),
        }
        parse(&text)
    }

    /// Sets one key, preserving everything else.
    ///
    /// Replaces the first occurrence in place and drops any later ones, so the
    /// file ends up with exactly one, at the original position. That is what
    /// `cfg_set` does, and it is why reading takes the last occurrence while
    /// writing rewrites the first: after any write there is only one.
    pub fn set(&self, key: &str, value: &str) -> Result<(), WriteError> {
        let _guard = self.lock()?;

        let mut text = String::new();
        if let Ok(mut f) = File::open(&self.path) {
            let _ = f.read_to_string(&mut text);
        }

        let mut out = String::with_capacity(text.len() + key.len() + value.len() + 2);
        let mut written = false;
        for line in text.lines() {
            let bare = line.strip_suffix('\r').unwrap_or(line);
            if key_of(bare) == Some(key) {
                if !written {
                    out.push_str(&format!("{key}={value}\n"));
                    written = true;
                }
                continue;
            }
            out.push_str(bare);
            out.push('\n');
        }
        if !written {
            out.push_str(&format!("{key}={value}\n"));
        }

        self.replace_atomically(out.as_bytes())
    }

    /// Writes `contents` so a reader sees either the old file or the new one,
    /// never a half-written mixture: write a private temp file beside the
    /// target, flush it, then rename over.
    fn replace_atomically(&self, contents: &[u8]) -> Result<(), WriteError> {
        let dir = self.path.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(dir).map_err(WriteError::Io)?;
        // Per-process name. A shared one is how the shell version used to let
        // two log trims clobber each other.
        let tmp = dir.join(format!("config.tmp.{}", std::process::id()));

        let write = || -> std::io::Result<()> {
            let mut f = File::create(&tmp)?;
            f.write_all(contents)?;
            // Without this the rename can be durable while the contents are
            // not, which after a crash leaves an empty config -- worse than
            // the old one.
            f.sync_all()?;
            Ok(())
        };
        if let Err(e) = write() {
            let _ = std::fs::remove_file(&tmp);
            return Err(WriteError::Io(e));
        }
        if let Err(e) = std::fs::rename(&tmp, &self.path) {
            let _ = std::fs::remove_file(&tmp);
            return Err(WriteError::Io(e));
        }
        Ok(())
    }

    /// Takes the exclusive lock, or gives up after `LOCK_TIMEOUT`.
    ///
    /// A bounded retry rather than a blocking lock, for two reasons. A blocking
    /// lock has no way to report "someone else is holding this" to a user who
    /// would rather know than wait forever. And on Windows the OS does not
    /// release locks promptly when a holder dies -- Microsoft documents that
    /// explicitly -- so a single `try_lock` immediately after a sibling was
    /// killed can fail even though nobody holds it.
    fn lock(&self) -> Result<LockGuard, WriteError> {
        if let Some(dir) = self.lock_path.parent() {
            std::fs::create_dir_all(dir).map_err(WriteError::Io)?;
        }
        // create(true) without truncate: the lock file is created once and then
        // never removed. Deleting it would destroy mutual exclusion silently --
        // the lock lives on the inode, so unlink-and-recreate lets a second
        // process lock a different inode and walk straight in.
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&self.lock_path)
            .map_err(WriteError::Io)?;

        let deadline = Instant::now() + LOCK_TIMEOUT;
        loop {
            match file.try_lock() {
                Ok(()) => return Ok(LockGuard { file }),
                // WouldBlock is somebody else holding it. A real error is
                // treated the same way rather than propagated, because the
                // filesystems where locking errors outright -- some network
                // mounts -- are exactly the ones where refusing to write at all
                // would be worse than retrying and then reporting Busy.
                Err(_) => {
                    if Instant::now() >= deadline {
                        return Err(WriteError::Busy {
                            lock: self.lock_path.clone(),
                        });
                    }
                    std::thread::sleep(LOCK_RETRY_GAP);
                }
            }
        }
    }
}

/// Releases on drop, including when a panic unwinds past it.
struct LockGuard {
    file: File,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        // Explicit rather than relying on close, because Windows is documented
        // not to release promptly on handle close.
        let _ = self.file.unlock();
    }
}

#[derive(Debug)]
pub enum WriteError {
    Io(std::io::Error),
    Busy { lock: PathBuf },
}

impl std::fmt::Display for WriteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WriteError::Io(e) => write!(f, "could not write the config: {e}"),
            WriteError::Busy { lock } => write!(
                f,
                "another buzzer is writing the config; gave up after {}s. \
                 If nothing else is running, remove {}",
                LOCK_TIMEOUT.as_secs(),
                lock.display()
            ),
        }
    }
}

/// The key a config line sets, if it is a setting line at all.
fn key_of(line: &str) -> Option<&str> {
    let line = line.trim_start();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let (key, _) = line.split_once('=')?;
    let key = key.trim();
    (!key.is_empty()).then_some(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- parsing ------------------------------------------------------------

    #[test]
    fn parses_the_shipped_config_shape() {
        let v = parse(
            "# a comment\n\
             enabled=true\n\
             threshold_seconds=30\n\
             \n\
             volume=0.7\n",
        );
        assert_eq!(v.str_or("enabled", "?"), "true");
        assert_eq!(v.u64_or("threshold_seconds", 99), 30);
        assert_eq!(v.volume_or("volume", 0.1), 0.7);
    }

    #[test]
    fn the_last_occurrence_of_a_key_wins() {
        // tests/run.sh's set_cfg helper appends rather than rewriting, so the
        // whole suite depends on this.
        let v = parse("volume=0.1\nvolume=0.5\nvolume=0.9\n");
        assert_eq!(v.str_or("volume", "?"), "0.9");
    }

    #[test]
    fn comments_blank_lines_and_junk_are_skipped() {
        let v = parse("# volume=0.1\n\n   \nthis is not a setting\n[weird]\nvolume=0.5\n");
        assert_eq!(v.str_or("volume", "?"), "0.5");
        assert_eq!(v.str_or("this is not a setting", "?"), "?");
    }

    #[test]
    fn surrounding_whitespace_and_carriage_returns_are_stripped() {
        // A config edited on Windows, or synced from there, must parse the same.
        let v = parse("  volume  =  0.5  \r\ndone_repeat=2\r\n");
        assert_eq!(v.str_or("volume", "?"), "0.5");
        assert_eq!(v.u64_or("done_repeat", 1), 2);
    }

    #[test]
    fn a_value_containing_equals_survives() {
        // Sound paths are the realistic case, but only the first = splits.
        let v = parse("done_sound=/tmp/a=b/c.wav\n");
        assert_eq!(v.str_or("done_sound", "?"), "/tmp/a=b/c.wav");
    }

    #[test]
    fn an_empty_value_means_absent() {
        // `done_volume=` in the shipped default config means "inherit", not
        // "zero". Treating it as a value would make every event silent.
        let v = parse("done_volume=\n");
        assert_eq!(v.volume_or("done_volume", 0.7), 0.7);
        assert_eq!(v.get("done_volume"), None);
    }

    // --- typed accessors ----------------------------------------------------

    #[test]
    fn bool_accepts_every_spelling_both_ways() {
        for t in ["true", "TRUE", "1", "yes", "On"] {
            assert!(parse(&format!("k={t}")).bool_or("k", false), "{t}");
        }
        for f in ["false", "FALSE", "0", "no", "Off"] {
            assert!(!parse(&format!("k={f}")).bool_or("k", true), "{f}");
        }
    }

    #[test]
    fn a_malformed_bool_is_the_default_not_an_error() {
        // Both directions, because a fail-closed default here silences the tool.
        assert!(parse("k=banana").bool_or("k", true));
        assert!(!parse("k=banana").bool_or("k", false));
        assert!(parse("").bool_or("k", true));
    }

    #[test]
    fn a_malformed_number_is_the_default() {
        for bad in ["", "-5", "3.5", "abc", "30s", " 30", "0x1e", "1_0"] {
            assert_eq!(parse(&format!("k={bad}")).u64_or("k", 30), 30, "{bad:?}");
        }

        // These pin parity rather than taste, and the fallback deliberately is
        // not the number they would parse to. Rust's u64::from_str accepts a
        // leading plus and leading zeros; buzzer.sh's `case *[!0-9]*` rejects
        // the plus and treats "030" as the decimal 30. Reading one file must
        // give one answer, so this follows the shell.
        //
        // Using 30 as the fallback here would make the test pass either way --
        // which it did, until a mutation of `u64_or` survived and said so.
        assert_eq!(
            parse("k=+30").u64_or("k", 99),
            99,
            "a leading plus is not a number"
        );
        assert_eq!(
            parse("k=030").u64_or("k", 99),
            30,
            "leading zeros are decimal"
        );
        assert_eq!(parse("k=0").u64_or("k", 30), 0);
        assert_eq!(parse("k=99999").u64_or("k", 30), 99999);
    }

    #[test]
    fn an_out_of_range_volume_falls_back() {
        for bad in ["-0.1", "1.5", "abc", "", "0.5.5"] {
            assert_eq!(
                parse(&format!("k={bad}")).volume_or("k", 0.7),
                0.7,
                "{bad:?}"
            );
        }
        assert_eq!(parse("k=0").volume_or("k", 0.7), 0.0);
        assert_eq!(parse("k=1").volume_or("k", 0.7), 1.0);
    }

    // --- writing ------------------------------------------------------------

    fn tmpdir() -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "buzzer-cfg-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn set_creates_the_file_when_absent() {
        let d = tmpdir();
        let c = Config::new(&d);
        c.set("volume", "0.5").unwrap();
        assert_eq!(c.read().str_or("volume", "?"), "0.5");
    }

    #[test]
    fn set_preserves_every_other_line_including_comments() {
        let d = tmpdir();
        let c = Config::new(&d);
        std::fs::write(c.path(), "# keep me\nenabled=true\nvolume=0.7\n").unwrap();
        c.set("volume", "0.3").unwrap();
        let text = std::fs::read_to_string(c.path()).unwrap();
        assert!(text.contains("# keep me"), "comment was dropped: {text:?}");
        assert!(text.contains("enabled=true"), "other key lost: {text:?}");
        assert!(text.contains("volume=0.3"));
    }

    #[test]
    fn set_replaces_in_place_and_collapses_duplicates() {
        // Matches cfg_set: the first occurrence is rewritten, later ones are
        // dropped, so exactly one remains and it keeps its original position.
        let d = tmpdir();
        let c = Config::new(&d);
        std::fs::write(c.path(), "volume=0.1\nenabled=true\nvolume=0.9\n").unwrap();
        c.set("volume", "0.5").unwrap();
        let text = std::fs::read_to_string(c.path()).unwrap();
        assert_eq!(text, "volume=0.5\nenabled=true\n", "got {text:?}");
    }

    #[test]
    fn set_appends_a_key_that_was_missing() {
        let d = tmpdir();
        let c = Config::new(&d);
        std::fs::write(c.path(), "enabled=true\n").unwrap();
        c.set("threshold_seconds", "60").unwrap();
        assert_eq!(
            std::fs::read_to_string(c.path()).unwrap(),
            "enabled=true\nthreshold_seconds=60\n"
        );
    }

    #[test]
    fn set_leaves_no_temp_file_behind() {
        let d = tmpdir();
        let c = Config::new(&d);
        c.set("volume", "0.5").unwrap();
        let strays: Vec<_> = std::fs::read_dir(&d)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with("config.tmp."))
            .collect();
        assert!(strays.is_empty(), "left behind: {strays:?}");
    }

    #[test]
    fn the_lock_file_survives_a_write() {
        // It must be created once and never removed: the lock lives on the
        // inode, so deleting and recreating it lets a second process lock a
        // different inode and walk straight into the critical section.
        let d = tmpdir();
        let c = Config::new(&d);
        c.set("volume", "0.5").unwrap();
        assert!(d.join(".config.lock").exists(), "lock file was removed");
        c.set("volume", "0.6").unwrap();
        assert!(d.join(".config.lock").exists());
    }

    #[test]
    fn the_lock_is_a_sidecar_never_the_config_itself() {
        // On Windows the lock is mandatory, so locking the config would break
        // the hand-editing the README tells users to do.
        let d = tmpdir();
        let c = Config::new(&d);
        c.set("volume", "0.5").unwrap();
        assert_ne!(c.path(), d.join(".config.lock"));
        assert!(d.join("config").exists());
    }

    #[test]
    fn a_held_lock_makes_a_write_fail_rather_than_corrupt() {
        let d = tmpdir();
        let c = Config::new(&d);
        c.set("volume", "0.5").unwrap();

        // Hold the lock the way another process would.
        let held = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(d.join(".config.lock"))
            .unwrap();
        held.try_lock().expect("test could not take the lock");

        let start = Instant::now();
        let err = c.set("volume", "0.9").unwrap_err();
        let waited = start.elapsed();

        assert!(
            matches!(err, WriteError::Busy { .. }),
            "expected Busy, got {err:?}"
        );
        assert!(
            waited >= LOCK_TIMEOUT,
            "gave up after {waited:?}, before the timeout"
        );
        // The refusal must say what to do about it.
        let msg = err.to_string();
        assert!(msg.contains(".config.lock"), "message names no lock: {msg}");
        // And the old value must be untouched.
        assert_eq!(c.read().str_or("volume", "?"), "0.5");

        held.unlock().unwrap();
    }

    #[test]
    fn concurrent_writers_do_not_lose_each_others_keys() {
        // The bug this whole design exists for. Every thread writes a distinct
        // key, so nothing legitimately overwrites anything: whatever is missing
        // at the end was silently dropped. Without the lock, the shell version
        // landed 5 of 16.
        let d = tmpdir();
        let c = Config::new(&d);
        c.set("seed", "1").unwrap();

        let n = 12;
        std::thread::scope(|s| {
            for i in 0..n {
                let dir = d.clone();
                s.spawn(move || {
                    let c = Config::new(&dir);
                    c.set(&format!("key{i}"), &format!("value{i}")).unwrap();
                });
            }
        });

        let v = c.read();
        let missing: Vec<_> = (0..n)
            .filter(|i| v.get(&format!("key{i}")) != Some(&format!("value{i}")[..]))
            .collect();
        assert!(missing.is_empty(), "lost writes for keys {missing:?}");
        assert_eq!(v.str_or("seed", "?"), "1", "the seeded key was lost");
    }

    #[test]
    fn a_reader_never_sees_a_half_written_file() {
        // The rename is what guarantees this. A reader either gets the old file
        // or the new one; there is no moment where it is partially rewritten.
        let d = tmpdir();
        let c = Config::new(&d);
        let big = "x".repeat(4096);
        c.set("pad", &big).unwrap();
        // Both keys must exist before the reader starts, or it will report a
        // torn read for a file that is merely young.
        c.set("volume", "0.0").unwrap();

        std::thread::scope(|s| {
            let dir = d.clone();
            s.spawn(move || {
                let c = Config::new(&dir);
                for i in 0..40 {
                    c.set("volume", &format!("0.{i}")).unwrap();
                }
            });
            let dir = d.clone();
            s.spawn(move || {
                let c = Config::new(&dir);
                for _ in 0..200 {
                    // Every read must find both keys intact, whichever version
                    // it lands on.
                    let v = c.read();
                    assert_eq!(v.get("pad").map(str::len), Some(4096), "torn read");
                    assert!(v.get("volume").is_some(), "torn read: volume missing");
                }
            });
        });
    }
}
