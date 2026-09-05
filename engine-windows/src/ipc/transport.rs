//! NDJSON transport over stdio.
//!
//! Mirrors the Swift `StdioTransport`: a dedicated reader thread parses one
//! JSON object per line from stdin and hands each decoded [`CoreMessage`] to a
//! callback; a mutex-guarded writer serializes engine→core lines to stdout
//! (transcript, levels, and pongs originate on different threads).
//!
//! Framing notes:
//! - Unparseable / blank lines are logged to stderr and skipped, never fatal.
//! - stdout is reserved for NDJSON; all human logs go to stderr.
//! - Rust's `std::io::Stdout` writes bytes verbatim on Windows (no `\r\n`
//!   translation), so the framing stays a single `\n` per message.

use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex};
use std::thread;

use super::messages::{CoreMessage, EngineMessage};
use crate::util::log;

/// Owns the stdout write lock; cloneable so any thread can emit messages.
#[derive(Clone)]
pub struct Sender {
    out: Arc<Mutex<std::io::Stdout>>,
}

impl Sender {
    /// Encode `msg` as a single NDJSON line and flush it to stdout. A broken
    /// pipe (parent gone) is logged, not panicked — EOF on stdin drives the
    /// real shutdown.
    pub fn send(&self, msg: &EngineMessage) {
        let mut line = match serde_json::to_string(msg) {
            Ok(s) => s,
            Err(e) => {
                log(&format!("failed to encode engine message: {e}"));
                return;
            }
        };
        line.push('\n');
        let mut out = self.out.lock().expect("stdout lock poisoned");
        if let Err(e) = out.write_all(line.as_bytes()).and_then(|_| out.flush()) {
            log(&format!("stdout write failed (parent gone?): {e}"));
        }
    }
}

pub struct Transport {
    out: Arc<Mutex<std::io::Stdout>>,
}

impl Default for Transport {
    fn default() -> Self {
        Self::new()
    }
}

impl Transport {
    pub fn new() -> Self {
        Self {
            out: Arc::new(Mutex::new(std::io::stdout())),
        }
    }

    /// A cloneable handle for sending engine→core messages from any thread.
    pub fn sender(&self) -> Sender {
        Sender {
            out: self.out.clone(),
        }
    }

    /// Spawn the stdin reader thread. `on_message` runs per decoded message and
    /// `on_eof` once when stdin closes — both on the reader thread. Returns the
    /// join handle (the caller usually lets it run to EOF).
    pub fn start<M, E>(&self, on_message: M, on_eof: E) -> thread::JoinHandle<()>
    where
        M: Fn(CoreMessage) + Send + 'static,
        E: FnOnce() + Send + 'static,
    {
        thread::Builder::new()
            .name("stdin-reader".into())
            .spawn(move || {
                let stdin = std::io::stdin();
                let mut handle = stdin.lock();
                let mut line = String::new();
                loop {
                    line.clear();
                    match handle.read_line(&mut line) {
                        Ok(0) => break, // EOF — parent closed our stdin
                        Ok(_) => {
                            let trimmed = line.trim();
                            if trimmed.is_empty() {
                                continue;
                            }
                            match serde_json::from_str::<CoreMessage>(trimmed) {
                                Ok(msg) => on_message(msg),
                                // Unknown message types / malformed lines are
                                // ignored per the forward-compat rule.
                                Err(e) => log(&format!("skipping unparseable line: {e}")),
                            }
                        }
                        Err(e) => {
                            log(&format!("stdin read error, treating as EOF: {e}"));
                            break;
                        }
                    }
                }
                on_eof();
            })
            .expect("spawn stdin-reader thread")
    }
}
