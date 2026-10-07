const std = @import("std");

pub const Zone = enum { primary, secondary, canary };

/// A custom `parse` type: any struct/union declaring `pub fn parse(s: []const
/// u8) !@This()` can be used as an option (or arg) field type, and the CLI,
/// env, and config sources all funnel through the same parser.
pub const Duration = struct {
    seconds: u32,

    pub fn parse(s: []const u8) !Duration {
        if (s.len < 2) return error.InvalidDuration;
        const unit = s[s.len - 1];
        const digits = s[0 .. s.len - 1];
        const n = try std.fmt.parseInt(u32, digits, 10);
        const multiplier: u32 = switch (unit) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            else => return error.InvalidDuration,
        };
        return .{ .seconds = n * multiplier };
    }
};

test "Duration.parse: seconds, minutes, hours" {
    try std.testing.expectEqual(@as(u32, 30), (try Duration.parse("30s")).seconds);
    try std.testing.expectEqual(@as(u32, 120), (try Duration.parse("2m")).seconds);
    try std.testing.expectEqual(@as(u32, 3600), (try Duration.parse("1h")).seconds);
}

test "Duration.parse: rejects an unknown unit" {
    try std.testing.expectError(error.InvalidDuration, Duration.parse("30x"));
}
