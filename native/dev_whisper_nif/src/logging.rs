//! Simple thread-safe logging to stdout - mirrors the style used by dev_snp_nif.

use std::thread;
use std::time::SystemTime;

/// Log a message with thread ID, timestamp, file, and line number.
pub fn log_message(log_level: &str, file: &str, line: u32, message: &str) {
    let thread_id = thread::current().id();
    let now = SystemTime::now();
    let timestamp = now
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    println!(
        "[{}#{:?} @ {}:{}] [{}] {}",
        log_level, thread_id, file, line, timestamp, message
    );
}
