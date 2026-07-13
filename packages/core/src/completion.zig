//! Dynamic shell-completion contract (ADR-0026).
//!
//! A command declares a per-field completion source through `meta` — a sibling of
//! the `validate`/`parse` hooks — either a builtin tag (`.file`/`.dir`, resolved
//! to native shell completion at generation time) or a function that produces
//! candidates at runtime:
//!
//! ```zig
//! pub const meta = .{
//!     .args = .{ .id = .{ .description = "Task ID", .complete = completeTaskId } },
//! };
//!
//! fn completeTaskId(req: *zcli.completion.Request) !zcli.completion.Result {
//!     // ...read runtime data, filter by req.partial...
//!     return .{ .candidates = list };
//! }
//! ```
//!
//! At `<TAB>` the generated shell script calls the hidden `__complete` command,
//! which resolves the command + field the cursor is on and runs the function
//! hook. The request is deliberately NOT the full command `Context`: a hook reads
//! inputs and returns candidates, and must not be able to write to stdout — that
//! is the byte stream the completion protocol travels on.

const std = @import("std");

/// The state of the command line handed to a completion hook. The shape is
/// identical for a positional arg and an option value — the hook already *is* the
/// field, so it only needs to know the line, not "which field am I".
pub const Request = struct {
    /// Arena for the hook's allocations; freed after the callback returns.
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    /// The word being completed (may be empty). Offer only values with this prefix.
    partial: []const u8,
    /// Positional tokens already entered for this command, options stripped, in
    /// order — for context-dependent completion. Excludes `partial`.
    args: []const []const u8,
};

/// One completion candidate. `description` is shown by zsh/fish beside the value
/// and ignored by bash.
pub const Candidate = struct {
    value: []const u8,
    description: ?[]const u8 = null,
};

/// What the shell should do *in addition* to the returned candidates.
pub const Directive = enum {
    /// Just the candidates.
    default,
    /// Also offer native file completion (increment 3).
    also_files,
    /// Also offer native directory completion (increment 3).
    also_dirs,
};

/// A completion hook's return value.
pub const Result = struct {
    candidates: []const Candidate = &.{},
    directive: Directive = .default,
};

/// A per-field completion function. Errors are swallowed by `__complete` (a
/// failing hook yields zero candidates, never a broken shell); `ZCLI_COMPLETE_DEBUG`
/// surfaces the error on stderr.
pub const Hook = *const fn (req: *Request) anyerror!Result;

/// A field's completion source, as introspected from `meta.<field>.complete`.
/// `.file`/`.dir` are resolved to native shell completion at script-generation
/// time and never reach `__complete`; `.hook` is run at `<TAB>`.
pub const Spec = union(enum) {
    hook: Hook,
    file,
    dir,
};
