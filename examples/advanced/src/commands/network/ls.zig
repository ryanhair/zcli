const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "List networks",
};

pub const Args = struct {};
pub const Options = struct {
    filter: ?[]const u8 = null,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;
    _ = options;
    try context.stdout().print("Listing networks...\n", .{});
}
