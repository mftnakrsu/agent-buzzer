//! The state directory: where the config, the turn marks and the log live.
//!
//! `~/.agent-buzzer` by default, overridable with `BUZZER_HOME`, which is also
//! how the test suite points at a throwaway directory. Deliberately not under
//! `~/.claude`: Claude Code is the first agent supported, not the only one
//! planned, and a Codex user should not have to create another tool's config
//! directory to set this one up.

#![allow(dead_code)]

use std::io::Write;
use std::path::{Path, PathBuf};

/// The log is a debugging aid, not an archive. Trimmed back to KEEP once it
/// grows past MAX so it can never eat disk.
const LOG_KEEP: usize = 100;
const LOG_MAX: usize = 140;

pub struct State {
    home: PathBuf,
}

impl State {
    /// `BUZZER_HOME`, else `$HOME/.agent-buzzer`.
    ///
    /// `HOME` can genuinely be unset -- cron, systemd units and some CI runners
    /// provide none. Falling back to a path that cannot exist keeps every later
    /// operation failing quietly rather than writing state somewhere
    /// surprising, which is what buzzer.sh's `${HOME:-/nonexistent}` does.
    pub fn discover() -> Self {
        if let Some(h) = std::env::var_os("BUZZER_HOME").filter(|v| !v.is_empty()) {
            return State { home: h.into() };
        }
        let base = std::env::var_os("HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/nonexistent"));
        State {
            home: base.join(".agent-buzzer"),
        }
    }

    pub fn at(home: impl Into<PathBuf>) -> Self {
        State { home: home.into() }
    }

    pub fn home(&self) -> &Path {
        &self.home
    }

    pub fn marks_dir(&self) -> PathBuf {
        self.home.join("marks")
    }

    pub fn log_path(&self) -> PathBuf {
        self.home.join("log")
    }

    // --- turn marks ---------------------------------------------------------

    /// Records that a turn started now, for `session_id`.
    ///
    /// Failure is deliberately silent and non-fatal: a mark that could not be
    /// written means the duration is unknown later, and unknown plays. Missing
    /// information must never cause a missed notification.
    pub fn write_mark(&self, session_id: &str, at_epoch: u64) {
        let Some(id) = sanitize_id(session_id) else {
            return;
        };
        let dir = self.marks_dir();
        if std::fs::create_dir_all(&dir).is_err() {
            return;
        }
        let _ = std::fs::write(dir.join(id), format!("{at_epoch}\n"));
    }

    /// How long ago the turn started, or `None` if that cannot be determined --
    /// no session id, no mark, or a mark we cannot make sense of. Every one of
    /// those is "unknown", which plays.
    pub fn turn_elapsed(&self, session_id: &str, now_epoch: u64) -> Option<u64> {
        let id = sanitize_id(session_id)?;
        let text = std::fs::read_to_string(self.marks_dir().join(id)).ok()?;
        let started: u64 = text.trim().parse().ok()?;
        // A mark from the future is a clock that moved, not a negative
        // duration. Treat it as "just started" rather than panicking on the
        // subtraction or wrapping into a very large number.
        Some(now_epoch.saturating_sub(started))
    }

    /// The turn is over, so the mark has done its job.
    pub fn clear_mark(&self, session_id: &str) {
        if let Some(id) = sanitize_id(session_id) {
            let _ = std::fs::remove_file(self.marks_dir().join(id));
        }
    }

    // --- log ----------------------------------------------------------------

    /// Appends a line, then trims if the file has grown past `LOG_MAX`.
    ///
    /// Takes no lock. This runs inside hooks, and hooks must never wait on each
    /// other. The trim writes a per-process scratch file and renames it in --
    /// a shared scratch name is exactly how buzzer.sh used to let two hooks
    /// trimming at once leave the log holding one of their partial reads, which
    /// emptied a 160-line log to zero in five runs out of eight.
    pub fn log(&self, message: &str, stamp: &str) {
        if std::fs::create_dir_all(&self.home).is_err() {
            return;
        }
        let path = self.log_path();
        let appended = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut f| writeln!(f, "{stamp} {message}"));
        if appended.is_err() {
            return;
        }

        let Ok(text) = std::fs::read_to_string(&path) else {
            return;
        };
        let lines: Vec<&str> = text.lines().collect();
        if lines.len() <= LOG_MAX {
            return;
        }
        let keep = &lines[lines.len() - LOG_KEEP..];
        let tmp = self.home.join(format!("log.trim.{}", std::process::id()));
        let wrote = std::fs::File::create(&tmp).and_then(|mut f| {
            for l in keep {
                writeln!(f, "{l}")?;
            }
            Ok(())
        });
        if wrote.is_err() || std::fs::rename(&tmp, &path).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

/// A session id becomes a filename, so it must not be able to escape the marks
/// directory or name something else. buzzer.sh strips everything outside
/// `[A-Za-z0-9._-]` for the same reason; an id that reduces to nothing, or to a
/// path component like `..`, is treated as no id at all.
pub fn sanitize_id(raw: &str) -> Option<String> {
    let cleaned: String = raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(128)
        .collect();
    if cleaned.is_empty() || cleaned.chars().all(|c| c == '.') {
        return None;
    }
    Some(cleaned)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("buzzer-state-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    // --- session ids --------------------------------------------------------

    #[test]
    fn a_session_id_cannot_escape_the_marks_directory() {
        // The whole point of sanitising: these must never produce a path that
        // leaves marks/, and must never name a file outside it.
        for hostile in [
            "../../etc/passwd",
            "a/b/c",
            "..",
            ".",
            "/etc/passwd",
            "..\\..\\x",
        ] {
            match sanitize_id(hostile) {
                None => {}
                Some(id) => {
                    assert!(!id.contains('/'), "{hostile:?} kept a slash: {id:?}");
                    assert!(!id.contains('\\'), "{hostile:?} kept a backslash: {id:?}");
                    assert_ne!(id, "..", "{hostile:?} reduced to a parent reference");
                    assert!(
                        !Path::new(&id).components().any(|c| matches!(
                            c,
                            std::path::Component::ParentDir | std::path::Component::RootDir
                        )),
                        "{hostile:?} produced a traversing component: {id:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn an_ordinary_session_id_is_kept_intact() {
        assert_eq!(sanitize_id("abc123").as_deref(), Some("abc123"));
        assert_eq!(
            sanitize_id("9f8e-4c2a_11.2").as_deref(),
            Some("9f8e-4c2a_11.2")
        );
    }

    #[test]
    fn an_empty_or_dot_only_id_is_no_id_at_all() {
        for none in ["", "   ", "..", ".", "...", "///"] {
            assert_eq!(sanitize_id(none), None, "{none:?}");
        }
    }

    // --- marks --------------------------------------------------------------

    #[test]
    fn a_marked_turn_reports_its_elapsed_time() {
        let s = State::at(tmpdir("mark"));
        s.write_mark("abc", 1000);
        assert_eq!(s.turn_elapsed("abc", 1120), Some(120));
    }

    #[test]
    fn every_unknowable_duration_is_none_rather_than_zero() {
        // None means "unknown", which plays. Zero would mean "instant", which
        // is below any threshold and would silence -- the fail-closed direction
        // and therefore the wrong one.
        let s = State::at(tmpdir("unknown"));
        assert_eq!(s.turn_elapsed("", 1000), None, "no session id");
        assert_eq!(s.turn_elapsed("never-marked", 1000), None, "no mark file");

        std::fs::create_dir_all(s.marks_dir()).unwrap();
        std::fs::write(s.marks_dir().join("garbage"), "not-a-timestamp").unwrap();
        assert_eq!(s.turn_elapsed("garbage", 1000), None, "unparseable mark");
    }

    #[test]
    fn a_mark_from_the_future_does_not_wrap_around() {
        // A clock that moved backwards, or an NTP correction. Saturating gives
        // 0, which is honest -- "just started" -- rather than a duration near
        // u64::MAX that would sail past any threshold and always play.
        let s = State::at(tmpdir("future"));
        s.write_mark("abc", 2000);
        assert_eq!(s.turn_elapsed("abc", 1000), Some(0));
    }

    #[test]
    fn clearing_a_mark_makes_the_duration_unknown_again() {
        let s = State::at(tmpdir("clear"));
        s.write_mark("abc", 1000);
        assert!(s.turn_elapsed("abc", 1100).is_some());
        s.clear_mark("abc");
        assert_eq!(s.turn_elapsed("abc", 1100), None);
    }

    #[test]
    fn an_unusable_session_id_writes_no_file_at_all() {
        let s = State::at(tmpdir("nofile"));
        s.write_mark("..", 1000);
        s.write_mark("", 1000);
        let n = std::fs::read_dir(s.marks_dir())
            .map(|d| d.count())
            .unwrap_or(0);
        assert_eq!(n, 0, "a hostile id created a file");
    }

    // --- log ----------------------------------------------------------------

    #[test]
    fn the_log_records_what_it_is_given() {
        let s = State::at(tmpdir("log"));
        s.log("decision=play event=done", "2026-01-01T00:00:00+0000");
        let text = std::fs::read_to_string(s.log_path()).unwrap();
        assert!(text.contains("decision=play event=done"), "got {text:?}");
    }

    #[test]
    fn the_log_is_capped() {
        let s = State::at(tmpdir("cap"));
        for i in 0..200 {
            s.log(&format!("line {i}"), "2026-01-01T00:00:00+0000");
        }
        let n = std::fs::read_to_string(s.log_path())
            .unwrap()
            .lines()
            .count();
        assert!(n <= LOG_MAX, "log grew to {n} lines");
        assert!(
            n >= LOG_KEEP - 1,
            "log was cut to {n} lines, well under KEEP"
        );
    }

    #[test]
    fn trimming_keeps_the_newest_lines_not_the_oldest() {
        // Trimming to the wrong end would leave a log full of ancient history
        // and none of the decision you are actually debugging.
        let s = State::at(tmpdir("newest"));
        for i in 0..200 {
            s.log(&format!("line {i}"), "2026-01-01T00:00:00+0000");
        }
        let text = std::fs::read_to_string(s.log_path()).unwrap();
        assert!(
            text.contains("line 199"),
            "the newest line was trimmed away"
        );
        assert!(!text.contains("line 0\n"), "the oldest line survived");
    }

    #[test]
    fn log_trimming_uses_a_private_scratch_file() {
        // The property behind a race that cannot be provoked on demand: the
        // scratch file must belong to this process alone. Wedging the name a
        // shared implementation would use proves which one is in play.
        let dir = tmpdir("scratch");
        let s = State::at(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::create_dir_all(dir.join("log.trim")).unwrap();
        for i in 0..200 {
            s.log(&format!("line {i}"), "2026-01-01T00:00:00+0000");
        }
        let n = std::fs::read_to_string(s.log_path())
            .unwrap()
            .lines()
            .count();
        assert!(
            n <= LOG_MAX,
            "log at {n} lines: the trim used a shared name"
        );
    }

    #[test]
    fn concurrent_logging_never_truncates_the_log() {
        // Hooks log without a lock, on purpose, so this has to hold anyway.
        let dir = tmpdir("concurrent-log");
        std::thread::scope(|sc| {
            for t in 0..8 {
                let d = dir.clone();
                sc.spawn(move || {
                    let s = State::at(&d);
                    for i in 0..60 {
                        s.log(&format!("t{t} line {i}"), "2026-01-01T00:00:00+0000");
                    }
                });
            }
        });
        let s = State::at(&dir);
        let n = std::fs::read_to_string(s.log_path())
            .unwrap()
            .lines()
            .count();
        assert!(
            n >= LOG_KEEP - 1,
            "concurrent trims cut the log to {n} lines"
        );
        assert!(n <= LOG_MAX + 8, "log grew to {n} lines without trimming");
        let strays: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with("log.trim."))
            .collect();
        assert!(strays.is_empty(), "left behind: {strays:?}");
    }

    // --- discovery ----------------------------------------------------------

    #[test]
    fn buzzer_home_wins_over_everything() {
        let d = tmpdir("discover");
        // Safe here: this test does not run concurrently with another that
        // reads the same variables, and it restores nothing because each test
        // process is short-lived.
        unsafe { std::env::set_var("BUZZER_HOME", &d) };
        assert_eq!(State::discover().home(), d.as_path());
        unsafe { std::env::remove_var("BUZZER_HOME") };
    }
}
