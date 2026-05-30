const std = @import("std");
const registry = @import("command_registry");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    app.run(init.gpa, init.io, init.environ_map, args) catch |err| switch (err) {
        error.CommandNotFound => std.process.exit(1),
        else => return err,
    };
}
