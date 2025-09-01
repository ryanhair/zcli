const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "List networks",
};

pub const Args = zcli.NoArgs;
pub const Options = struct {
    filter: ?[]const u8 = null,
};

pub fn execute(_: Args, options: Options, context: *zcli.Context) !void {
    _ = options;
    try context.stdout().print("Listing networks...\n", .{});
}
