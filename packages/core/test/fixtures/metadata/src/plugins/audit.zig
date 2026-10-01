const std = @import("std");
const case = @import("fixture_case").case;
pub const plugin_id = "audit";
pub const CommandConfig = if (std.mem.eql(u8, case, "missing_default")) struct {
    record: bool,
} else struct {
    record: bool = true,
};

pub fn prepare(context: anytype) !void {
    _ = context.command_config.audit.record;
}
