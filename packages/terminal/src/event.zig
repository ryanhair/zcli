//! Input event multiplexing.
//!
//! `key.zig` turns a byte stream into a `Key`. A terminal resize, by contrast,
//! isn't a key and doesn't arrive in the byte stream — it comes out-of-band from
//! a `ResizeWatcher` (a SIGWINCH signal on POSIX, a console-size poll on
//! Windows). `readEvent` composes those two input sources: it blocks until the
//! next input of *any* kind and reports it as an `Event`. Future out-of-band
//! inputs (mouse, focus, bracketed paste) would join `Event` here rather than in
//! the key parser.

const key = @import("key.zig");
const backend = @import("backend.zig");

/// An input event: a parsed key press or a terminal resize.
pub const Event = union(enum) {
    key: key.Key,
    resize,
};

/// Block until a key is read from `reader` or the terminal is resized, reported
/// via `watcher`. `handle` is the stdin handle — used both for escape-sequence
/// disambiguation and by the watcher's poll. Bytes already buffered in `reader`
/// are consumed before polling, so no keypress is missed.
pub fn readEvent(reader: anytype, handle: backend.Handle, watcher: *backend.ResizeWatcher) !Event {
    return (try readEventTimeout(reader, handle, watcher, null)).?;
}

/// Like `readEvent`, but return `null` if neither a key nor a resize arrives
/// within `timeout_ms`. `null` blocks indefinitely (never times out). The
/// finite-timeout form is what lets a full-screen App repaint on a tick with
/// no input — a `top`-style refresh — without a background thread.
pub fn readEventTimeout(
    reader: anytype,
    handle: backend.Handle,
    watcher: *backend.ResizeWatcher,
    timeout_ms: ?u32,
) !?Event {
    // Bytes already buffered are input regardless of the deadline.
    if (key.bufferedLen(reader) > 0) return Event{ .key = try key.readKeyOpt(reader, handle) };
    return switch (watcher.waitTimeout(handle, timeout_ms)) {
        .resize => .resize,
        .input => Event{ .key = try key.readKeyOpt(reader, handle) },
        .timeout => null,
    };
}
