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
    while (true) {
        if (key.bufferedLen(reader) > 0) return .{ .key = try key.readKeyOpt(reader, handle) };
        switch (watcher.wait(handle)) {
            .resize => return .resize,
            .input => return .{ .key = try key.readKeyOpt(reader, handle) },
        }
    }
}
