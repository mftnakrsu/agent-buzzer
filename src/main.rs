//! agent-buzzer -- plays a sound when your AI agent finishes a long turn.
//!
//! Phase 2 of the Rust port: the decision core only. Audio, focus detection and
//! the full CLI arrive in phase 3. See
//! docs/superpowers/specs/2026-08-10-rust-rewrite-design.md.

mod rules;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("version") | Some("--version") | Some("-V") => {
            println!("agent-buzzer {VERSION}");
        }
        _ => {
            eprintln!("agent-buzzer {VERSION}: the Rust port is not usable yet.");
            eprintln!("Use ./buzzer.sh. See docs/superpowers/specs/ for the plan.");
            std::process::exit(64);
        }
    }
}
