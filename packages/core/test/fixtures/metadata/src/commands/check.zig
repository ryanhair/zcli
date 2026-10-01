const std = @import("std");
const case = @import("fixture_case").case;
pub const Args = struct {};
pub const Options = if (std.mem.eql(u8, case, "stdin_nontext") or std.mem.eql(u8, case, "delimiter_scalar")) struct {
    value: u32 = 0,
} else struct {
    value: []const u8 = "",
};
pub const meta = if (std.mem.eql(u8, case, "unknown_namespace")) .{
    .plugins = .{ .missing = .{ .record = false } },
} else if (std.mem.eql(u8, case, "unknown_plugin_field")) .{
    .plugins = .{ .audit = .{ .typo = false } },
} else if (std.mem.eql(u8, case, "wrong_plugin_value")) .{
    .plugins = .{ .audit = .{ .record = "yes" } },
} else if (std.mem.eql(u8, case, "stdin_nontext")) .{
    .options = .{ .value = .{ .stdin = true } },
} else if (std.mem.eql(u8, case, "delimiter_scalar")) .{
    .options = .{ .value = .{ .delimiter = ',' } },
} else if (std.mem.eql(u8, case, "unknown_top_level")) .{
    .typo = true,
} else if (std.mem.eql(u8, case, "unknown_option_field")) .{
    .options = .{ .value = .{ .typo = true } },
} else .{
    .plugins = .{ .audit = .{ .record = false } },
    .options = .{ .value = .{ .stdin = true } },
};

pub fn execute(_: Args, _: Options, _: anytype) !void {}
