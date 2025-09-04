const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Say hello to someone",
};

pub const Options = struct {
    greeting: []const u8 = "Hello",
    excited: bool = false,
};

pub const Args = struct {
    name: []const u8 = "World",
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const punctuation = if (options.excited) "!" else ".";
    try context.io.stdout.print("{s}, {s}{s}\n", .{ options.greeting, args.name, punctuation });
}