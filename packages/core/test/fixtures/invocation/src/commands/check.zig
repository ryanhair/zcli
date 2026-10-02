pub const Args = struct { mode: []const u8 };
pub const Options = struct {
    ports: []u16 = &.{},
    tags: [][]const u8 = &.{},
};
pub const meta = .{ .options = .{
    .ports = .{ .short = 'p' },
    .tags = .{ .short = 't', .delimiter = ',' },
} };
const std = @import("std");
pub fn execute(args: Args, _: Options, context: anytype) !void {
    if (std.mem.eql(u8, args.mode, "output")) try context.stdout().writeAll("payload\n");
    if (std.mem.eql(u8, args.mode, "mapped")) return error.NotFound;
    if (std.mem.eql(u8, args.mode, "reported")) return context.fail("reported failure", .{});
    if (std.mem.eql(u8, args.mode, "unexpected")) return error.UnexpectedFixtureFailure;
}
