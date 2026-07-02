//! Policy caps applied to untrusted argv during option parsing.
//!
//! These are sanity bounds, not memory protection — parsing work and
//! allocation are linear in argv, which the OS already caps (ARG_MAX). The
//! two limits below are the ones the options parser actually enforces;
//! everything else is bounded transitively:
//!
//! - Accumulated array options grow by one element per flag occurrence, so
//!   they can never exceed `max_total_options` elements.
//! - Positional-argument count is bounded by argv itself (positionals are
//!   borrowed slices; no per-argument allocation).
//! - Command nesting depth is fixed at compile time by the registry; runtime
//!   input cannot deepen it.
//!
//! Earlier versions of this module advertised caps for those cases too, but
//! never enforced them — a documented-vs-actual gap flagged in the security
//! audit. What is declared here is what runs.

const std = @import("std");

/// Limits enforced by the options parser on each parse.
pub const ResourceLimits = struct {
    /// Maximum length of an option name in argv (`--<name>`), rejecting
    /// absurd flags before any lookup work.
    max_option_name_length: usize = 256,

    /// Maximum total number of option occurrences on one command line.
    max_total_options: usize = 100,

    pub fn getDefault() @This() {
        return .{};
    }
};

/// Error types for resource limit violations
pub const ResourceLimitError = error{
    OptionNameTooLong,
    TooManyOptions,
};

/// Tracks resource usage across one parse.
pub const ResourceTracker = struct {
    limits: ResourceLimits,
    option_count: usize = 0,

    pub fn init(limits: ResourceLimits) @This() {
        return .{ .limits = limits };
    }

    pub fn checkOptionCount(self: *@This()) ResourceLimitError!void {
        self.option_count += 1;
        if (self.option_count > self.limits.max_total_options) {
            return ResourceLimitError.TooManyOptions;
        }
    }

    pub fn checkOptionNameLength(self: @This(), name: []const u8) ResourceLimitError!void {
        if (name.len > self.limits.max_option_name_length) {
            return ResourceLimitError.OptionNameTooLong;
        }
    }
};

test "ResourceLimits default values" {
    const limits = ResourceLimits.getDefault();
    try std.testing.expectEqual(@as(usize, 256), limits.max_option_name_length);
    try std.testing.expectEqual(@as(usize, 100), limits.max_total_options);
}

test "ResourceTracker option counting" {
    var tracker = ResourceTracker.init(ResourceLimits{ .max_total_options = 2 });

    try tracker.checkOptionCount(); // 1st option - OK
    try tracker.checkOptionCount(); // 2nd option - OK

    try std.testing.expectError(ResourceLimitError.TooManyOptions, tracker.checkOptionCount()); // 3rd option - should fail
}

test "ResourceTracker option name length checking" {
    const tracker = ResourceTracker.init(ResourceLimits{ .max_option_name_length = 10 });

    try tracker.checkOptionNameLength("short"); // OK
    try tracker.checkOptionNameLength("exactly10c"); // OK (exactly at limit)

    try std.testing.expectError(ResourceLimitError.OptionNameTooLong, tracker.checkOptionNameLength("this-is-too-long")); // Should fail
}
