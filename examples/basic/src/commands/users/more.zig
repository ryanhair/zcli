const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "More...",
};

pub const Args = struct {};

pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
    try context.stdout().print("Hi there!\n", .{});
}
