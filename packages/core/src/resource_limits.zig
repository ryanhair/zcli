//! Policy cap applied to untrusted input during option parsing.
//!
//! There is exactly one, and it is a sanity bound rather than memory
//! protection. The property that makes that safe is **linearity**: parsing
//! work and allocation are linear in the input, and argument values are
//! borrowed slices into it rather than copies. The one place that is not
//! linear is the "did you mean" suggestion list, whose edit-distance scoring
//! is O(name x fields) — so the option name is capped, and with it the only
//! superlinear path. No real CLI has a flag anywhere near 256 bytes.
//!
//! Note the reasoning deliberately does **not** rest on ARG_MAX. That bounds a
//! real process's argv, but `options/parser.zig` is public API and a library
//! caller can hand it an arbitrarily long slice built in memory, where no OS
//! limit applies at all — the same class of caller parser.zig already reasons
//! about explicitly where it handles partial array conversion for
//! caller-supplied allocators. Linear work is what holds for both.
//!
//! A `max_total_options = 100` cap used to live here too. It was removed in
//! #741 because it defended against nothing (option occurrences cost linear
//! work, exactly like positionals) while breaking legitimate command lines: a
//! `docker run --env`-style or compiler-style (`-I`, `-D`) invocation died at
//! the 101st occurrence with no way for the app author to raise it. Worse,
//! comma-separated array values were charged per element, so a *single*
//! `--tags a,b,c,…` flag could trip it. It was never applied symmetrically
//! either — the global-option layer (registry/compiled.zig) never counted, so
//! globals repeated freely while command options capped.
//!
//! What is declared here is what runs.

const std = @import("std");

/// Maximum length of an option name (`--<name>`), rejecting absurd flags
/// before the superlinear suggestion scoring runs over them. Documented in
/// docs/DESIGN.md ("Option Parsing Behavior") and on the website's args &
/// options guide.
pub const max_option_name_length: usize = 256;

/// Error types for resource limit violations
pub const ResourceLimitError = error{
    OptionNameTooLong,
};

/// Reject an option name that exceeds `max_option_name_length`.
pub fn checkOptionNameLength(name: []const u8) ResourceLimitError!void {
    if (name.len > max_option_name_length) {
        return ResourceLimitError.OptionNameTooLong;
    }
}

test "option name length checking" {
    try checkOptionNameLength("short"); // OK
    try checkOptionNameLength("a" ** max_option_name_length); // OK (exactly at limit)

    try std.testing.expectError(
        ResourceLimitError.OptionNameTooLong,
        checkOptionNameLength("a" ** (max_option_name_length + 1)),
    );
}
