//! The silence rules. This module is the product.
//!
//! It is deliberately pure: no files, no clock, no processes, no environment.
//! Everything the decision needs arrives in a `Context` that somebody else
//! gathered. That is what lets the whole rule matrix be swept in milliseconds
//! instead of spawning a process per case, and it is why a rule can never
//! accidentally depend on something nobody wrote a test for.
//!
//! Ported from `decide()` in buzzer.sh. The order of the gates is part of the
//! contract -- `buzzer status` reports on this same function, so what status
//! says is by construction what the hook will do.

// Phase 2 builds and tests this module before anything calls it; the CLI that
// does is phase 3. Remove this the moment `runtime/` exists -- a permanent
// allow(dead_code) is how genuinely unreachable code hides.
#![allow(dead_code)]

/// Minutes since midnight. The shell version compares "HH:MM" strings; this is
/// the same idea with the parsing done once, at the edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Minutes(pub u16);

impl Minutes {
    /// Parses "HH:MM". Returns `None` for anything else, which callers treat as
    /// "use the default" -- never as an error, because a typo in the config must
    /// not stop a notification.
    pub fn parse(s: &str) -> Option<Self> {
        let (h, m) = s.split_once(':')?;
        let h: u16 = h.parse().ok()?;
        let m: u16 = m.parse().ok()?;
        if h > 23 || m > 59 {
            return None;
        }
        Some(Minutes(h * 60 + m))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    Done,
    Waiting,
    Error,
    Subagent,
}

impl Event {
    /// Only turn-scoped events are subject to the short-turn rule. Being asked
    /// for permission two seconds in is exactly when you want to know, so
    /// `waiting` and `subagent` skip it entirely.
    fn is_turn_scoped(self) -> bool {
        matches!(self, Event::Done | Event::Error)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Event::Done => "done",
            Event::Waiting => "waiting",
            Event::Error => "error",
            Event::Subagent => "subagent",
        }
    }
}

/// Everything `decide` is allowed to look at. Fields that can genuinely be
/// unknown are `Option`, and every one of them resolves towards playing --
/// missing information must never cause a missed notification.
#[derive(Debug, Clone)]
pub struct Context {
    pub enabled: bool,
    pub event_enabled: bool,
    /// `None` when quiet hours are off. `Some((from, to))` may wrap midnight.
    pub quiet_window: Option<(Minutes, Minutes)>,
    pub now: Minutes,
    /// `None` means the turn duration could not be determined.
    pub turn_elapsed_secs: Option<u64>,
    pub threshold_secs: u64,
    /// `None` means focus could not be detected.
    pub frontmost: Option<String>,
    /// Comma-separated substrings from `terminal_app`, already split and
    /// lowercased. Empty means "fall back to TERM_PROGRAM", which the caller
    /// has already resolved into this list.
    pub terminal_names: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reason {
    DisabledGlobally,
    EventOff(Event),
    QuietHours {
        from: Minutes,
        to: Minutes,
        now: Minutes,
    },
    TurnTooShort {
        elapsed_secs: u64,
        threshold_secs: u64,
    },
    TerminalFrontmost {
        app: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Play,
    Silent(Reason),
}

impl Decision {
    pub fn plays(&self) -> bool {
        matches!(self, Decision::Play)
    }
}

/// Is `now` inside the window `[from, to)`? The window may wrap midnight, which
/// is the normal case for quiet hours (23:00 -> 08:00).
///
/// `from == to` is the case #6 is about. It currently means "never quiet" here,
/// matching both shell implementations; that issue is a product decision and
/// this port deliberately does not change behaviour while porting.
pub fn in_quiet_window(now: Minutes, from: Minutes, to: Minutes) -> bool {
    if from <= to {
        now >= from && now < to
    } else {
        now >= from || now < to
    }
}

/// The whole point of the tool.
///
/// Gates are checked in order and the first match wins. Adding a gate means
/// adding it to the README table too -- the order is documented behaviour.
pub fn decide(event: Event, ctx: &Context) -> Decision {
    // 1. Global switch.
    if !ctx.enabled {
        return Decision::Silent(Reason::DisabledGlobally);
    }

    // 1b. Per-event switch.
    if !ctx.event_enabled {
        return Decision::Silent(Reason::EventOff(event));
    }

    // 2. Quiet hours. Off by default; `quiet_window` is None when off.
    if let Some((from, to)) = ctx.quiet_window {
        if in_quiet_window(ctx.now, from, to) {
            return Decision::Silent(Reason::QuietHours {
                from,
                to,
                now: ctx.now,
            });
        }
    }

    // 3. Short turns stay silent, but only for turn-scoped events.
    if event.is_turn_scoped() {
        // A duration we could not measure is not a short turn. Unknown plays.
        if let Some(elapsed) = ctx.turn_elapsed_secs {
            if elapsed < ctx.threshold_secs {
                return Decision::Silent(Reason::TurnTooShort {
                    elapsed_secs: elapsed,
                    threshold_secs: ctx.threshold_secs,
                });
            }
        }
    }

    // 4. You are already looking at it. Undetectable focus plays.
    if let Some(app) = &ctx.frontmost {
        if is_terminal(app, &ctx.terminal_names) {
            return Decision::Silent(Reason::TerminalFrontmost { app: app.clone() });
        }
    }

    // 5. Play.
    Decision::Play
}

/// Substring match, case-insensitive, ".app" ignored -- the same shape as the
/// shell version's comparison. Kept separate from `decide` so the matching rule
/// can be tested on its own.
fn is_terminal(frontmost: &str, terminal_names: &[String]) -> bool {
    let hay = normalise(frontmost);
    terminal_names
        .iter()
        .map(|n| normalise(n))
        .filter(|n| !n.is_empty())
        .any(|n| hay.contains(&n))
}

fn normalise(s: &str) -> String {
    s.trim()
        .trim_end_matches(".app")
        .to_lowercase()
        .replace(' ', "")
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL_EVENTS: [Event; 4] = [Event::Done, Event::Waiting, Event::Error, Event::Subagent];

    /// A context that plays. Every test starts here and breaks exactly one
    /// thing, so a test's name and its diff say the same thing.
    fn playing() -> Context {
        Context {
            enabled: true,
            event_enabled: true,
            quiet_window: None,
            now: Minutes::parse("12:00").unwrap(),
            turn_elapsed_secs: Some(120),
            threshold_secs: 30,
            frontmost: None,
            terminal_names: vec![],
        }
    }

    #[test]
    fn the_baseline_context_plays_for_every_event() {
        for e in ALL_EVENTS {
            assert_eq!(decide(e, &playing()), Decision::Play, "event {:?}", e);
        }
    }

    // --- rule 1: switches ---------------------------------------------------

    #[test]
    fn disabled_globally_silences_every_event() {
        let ctx = Context {
            enabled: false,
            ..playing()
        };
        for e in ALL_EVENTS {
            assert_eq!(
                decide(e, &ctx),
                Decision::Silent(Reason::DisabledGlobally),
                "event {:?}",
                e
            );
        }
    }

    #[test]
    fn per_event_disable_silences_only_that_event() {
        let ctx = Context {
            event_enabled: false,
            ..playing()
        };
        for e in ALL_EVENTS {
            assert_eq!(decide(e, &ctx), Decision::Silent(Reason::EventOff(e)));
        }
        // ...and with the per-event switch on, the same context plays.
        for e in ALL_EVENTS {
            assert!(decide(e, &playing()).plays());
        }
    }

    #[test]
    fn the_global_switch_outranks_the_per_event_switch() {
        // Both off: the reason must name the global one, because that is what
        // the user has to fix first and what `status` will tell them.
        let ctx = Context {
            enabled: false,
            event_enabled: false,
            ..playing()
        };
        assert_eq!(
            decide(Event::Done, &ctx),
            Decision::Silent(Reason::DisabledGlobally)
        );
    }

    // --- rule 2: quiet hours ------------------------------------------------

    #[test]
    fn quiet_hours_off_ignores_the_window() {
        let ctx = Context {
            quiet_window: None,
            now: Minutes::parse("23:30").unwrap(),
            ..playing()
        };
        assert!(decide(Event::Done, &ctx).plays());
    }

    #[test]
    fn a_window_that_wraps_midnight_covers_both_sides() {
        let from = Minutes::parse("23:00").unwrap();
        let to = Minutes::parse("08:00").unwrap();
        for (clock, inside) in [
            ("22:59", false),
            ("23:00", true),
            ("23:30", true),
            ("00:00", true),
            ("03:00", true),
            ("07:59", true),
            ("08:00", false), // exclusive upper bound: you are allowed to wake up
            ("12:00", false),
        ] {
            let ctx = Context {
                quiet_window: Some((from, to)),
                now: Minutes::parse(clock).unwrap(),
                ..playing()
            };
            assert_eq!(
                decide(Event::Done, &ctx).plays(),
                !inside,
                "at {clock}, expected inside={inside}"
            );
        }
    }

    #[test]
    fn a_window_that_does_not_wrap_behaves_the_same_way() {
        let from = Minutes::parse("09:00").unwrap();
        let to = Minutes::parse("17:00").unwrap();
        for (clock, inside) in [
            ("08:59", false),
            ("09:00", true),
            ("12:00", true),
            ("16:59", true),
            ("17:00", false),
            ("23:00", false),
        ] {
            let ctx = Context {
                quiet_window: Some((from, to)),
                now: Minutes::parse(clock).unwrap(),
                ..playing()
            };
            assert_eq!(
                decide(Event::Done, &ctx).plays(),
                !inside,
                "at {clock}, expected inside={inside}"
            );
        }
    }

    #[test]
    fn quiet_hours_silences_every_event_including_the_untimed_ones() {
        let ctx = Context {
            quiet_window: Some((
                Minutes::parse("23:00").unwrap(),
                Minutes::parse("08:00").unwrap(),
            )),
            now: Minutes::parse("23:30").unwrap(),
            ..playing()
        };
        for e in ALL_EVENTS {
            assert!(!decide(e, &ctx).plays(), "event {:?} should be quiet", e);
        }
    }

    // --- rule 3: short turns ------------------------------------------------

    #[test]
    fn the_threshold_boundary_is_inclusive_above() {
        // Exactly threshold plays; one second under does not. This is the pair
        // the shell suite pins, and the pair a refactor most easily inverts.
        for (elapsed, plays) in [(29, false), (30, true), (31, true)] {
            let ctx = Context {
                turn_elapsed_secs: Some(elapsed),
                threshold_secs: 30,
                ..playing()
            };
            assert_eq!(
                decide(Event::Done, &ctx).plays(),
                plays,
                "elapsed {elapsed}s against a 30s threshold"
            );
        }
    }

    #[test]
    fn an_unknown_duration_plays() {
        let ctx = Context {
            turn_elapsed_secs: None,
            threshold_secs: 99_999,
            ..playing()
        };
        assert!(
            decide(Event::Done, &ctx).plays(),
            "unknown duration must never mean silence"
        );
    }

    #[test]
    fn the_threshold_applies_only_to_turn_scoped_events() {
        let ctx = Context {
            turn_elapsed_secs: Some(1),
            threshold_secs: 30,
            ..playing()
        };
        assert!(!decide(Event::Done, &ctx).plays());
        assert!(!decide(Event::Error, &ctx).plays());
        assert!(
            decide(Event::Waiting, &ctx).plays(),
            "being asked for permission 1s in is exactly when you want to know"
        );
        assert!(decide(Event::Subagent, &ctx).plays());
    }

    #[test]
    fn a_zero_threshold_lets_everything_through() {
        let ctx = Context {
            turn_elapsed_secs: Some(0),
            threshold_secs: 0,
            ..playing()
        };
        assert!(decide(Event::Done, &ctx).plays());
    }

    // --- rule 4: frontmost --------------------------------------------------

    #[test]
    fn undetectable_focus_plays() {
        let ctx = Context {
            frontmost: None,
            terminal_names: vec!["ghostty".into()],
            ..playing()
        };
        assert!(decide(Event::Done, &ctx).plays());
    }

    #[test]
    fn the_terminal_being_frontmost_silences() {
        let ctx = Context {
            frontmost: Some("Ghostty".into()),
            terminal_names: vec!["ghostty".into()],
            ..playing()
        };
        assert_eq!(
            decide(Event::Done, &ctx),
            Decision::Silent(Reason::TerminalFrontmost {
                app: "Ghostty".into()
            })
        );
    }

    #[test]
    fn another_app_being_frontmost_plays() {
        let ctx = Context {
            frontmost: Some("Safari".into()),
            terminal_names: vec!["ghostty".into()],
            ..playing()
        };
        assert!(decide(Event::Done, &ctx).plays());
    }

    #[test]
    fn app_matching_ignores_case_spaces_and_the_app_suffix() {
        // The same application, spelled the four ways the platforms report it.
        for spelling in [
            "Visual Studio Code",
            "Visual Studio Code.app",
            "visual studio code",
            "VisualStudioCode",
        ] {
            let ctx = Context {
                frontmost: Some(spelling.into()),
                terminal_names: vec!["Visual Studio Code".into()],
                ..playing()
            };
            assert!(
                !decide(Event::Done, &ctx).plays(),
                "{spelling} should match the configured terminal"
            );
        }
    }

    #[test]
    fn an_empty_terminal_list_never_matches() {
        // Otherwise an empty `terminal_app` would silence everything, which is
        // the fail-closed direction and therefore the wrong one.
        let ctx = Context {
            frontmost: Some("Ghostty".into()),
            terminal_names: vec![],
            ..playing()
        };
        assert!(decide(Event::Done, &ctx).plays());
    }

    #[test]
    fn a_blank_terminal_name_never_matches() {
        // `terminal_app=,,` splits into empty strings; every string contains
        // the empty string, so without filtering this silences everything.
        let ctx = Context {
            frontmost: Some("Safari".into()),
            terminal_names: vec!["".into(), "   ".into()],
            ..playing()
        };
        assert!(decide(Event::Done, &ctx).plays());
    }

    // --- ordering -----------------------------------------------------------

    #[test]
    fn the_gates_short_circuit_in_the_documented_order() {
        // Everything wrong at once. Each gate, from the top, must be the one
        // that reports -- that is what makes `status` diagnostic rather than
        // merely correct.
        let all_bad = Context {
            enabled: false,
            event_enabled: false,
            quiet_window: Some((
                Minutes::parse("00:00").unwrap(),
                Minutes::parse("23:59").unwrap(),
            )),
            now: Minutes::parse("12:00").unwrap(),
            turn_elapsed_secs: Some(0),
            threshold_secs: 30,
            frontmost: Some("Ghostty".into()),
            terminal_names: vec!["ghostty".into()],
        };

        assert_eq!(
            decide(Event::Done, &all_bad),
            Decision::Silent(Reason::DisabledGlobally)
        );

        let ctx = Context {
            enabled: true,
            ..all_bad.clone()
        };
        assert_eq!(
            decide(Event::Done, &ctx),
            Decision::Silent(Reason::EventOff(Event::Done))
        );

        let ctx = Context {
            event_enabled: true,
            ..ctx
        };
        assert!(matches!(
            decide(Event::Done, &ctx),
            Decision::Silent(Reason::QuietHours { .. })
        ));

        let ctx = Context {
            quiet_window: None,
            ..ctx
        };
        assert!(matches!(
            decide(Event::Done, &ctx),
            Decision::Silent(Reason::TurnTooShort { .. })
        ));

        let ctx = Context {
            turn_elapsed_secs: Some(120),
            ..ctx
        };
        assert!(matches!(
            decide(Event::Done, &ctx),
            Decision::Silent(Reason::TerminalFrontmost { .. })
        ));

        let ctx = Context {
            frontmost: None,
            ..ctx
        };
        assert!(decide(Event::Done, &ctx).plays());
    }

    // --- the whole matrix ---------------------------------------------------

    #[test]
    // The expectation below is one branch per row of the README's rules table,
    // in the table's order, several of which return the same `false`. Clippy is
    // right that it collapses; collapsing it is the point being avoided. An
    // expectation that mirrors the documentation catches a reordered gate,
    // whereas a tidy boolean expression is just `decide` written twice and
    // agrees with any bug it happens to share.
    #[allow(clippy::if_same_then_else, clippy::needless_bool)]
    fn every_combination_of_every_gate_agrees_with_the_rules_table() {
        // 4 events x 2 x 2 x 2 x 3 x 2 = 384 cases, swept rather than sampled.
        let quiet_from = Minutes::parse("23:00").unwrap();
        let quiet_to = Minutes::parse("08:00").unwrap();
        let mut checked = 0;

        for event in ALL_EVENTS {
            for enabled in [true, false] {
                for event_enabled in [true, false] {
                    for quiet_on in [true, false] {
                        for elapsed in [None, Some(5u64), Some(120u64)] {
                            for focused in [true, false] {
                                let ctx = Context {
                                    enabled,
                                    event_enabled,
                                    quiet_window: quiet_on.then_some((quiet_from, quiet_to)),
                                    now: Minutes::parse("23:30").unwrap(),
                                    turn_elapsed_secs: elapsed,
                                    threshold_secs: 30,
                                    frontmost: focused.then(|| "Ghostty".to_string()),
                                    terminal_names: vec!["ghostty".into()],
                                };

                                let expected = if !enabled {
                                    false
                                } else if !event_enabled {
                                    false
                                } else if quiet_on {
                                    // 23:30 is inside 23:00-08:00
                                    false
                                } else if event.is_turn_scoped()
                                    && matches!(elapsed, Some(e) if e < 30)
                                {
                                    false
                                } else if focused {
                                    false
                                } else {
                                    true
                                };

                                assert_eq!(
                                    decide(event, &ctx).plays(),
                                    expected,
                                    "event={:?} enabled={} event_enabled={} quiet={} elapsed={:?} focused={}",
                                    event, enabled, event_enabled, quiet_on, elapsed, focused
                                );
                                checked += 1;
                            }
                        }
                    }
                }
            }
        }
        assert_eq!(checked, 4 * 2 * 2 * 2 * 3 * 2);
    }

    // --- parsing ------------------------------------------------------------

    #[test]
    fn minutes_parses_valid_clock_times() {
        assert_eq!(Minutes::parse("00:00"), Some(Minutes(0)));
        assert_eq!(Minutes::parse("23:59"), Some(Minutes(23 * 60 + 59)));
        assert_eq!(Minutes::parse("08:00"), Some(Minutes(480)));
    }

    #[test]
    fn minutes_rejects_everything_else() {
        for bad in [
            "", "24:00", "12:60", "12", "12:", ":30", "ab:cd", "-1:00", "12:00:00",
        ] {
            assert_eq!(Minutes::parse(bad), None, "{bad:?} should not parse");
        }
    }
}
