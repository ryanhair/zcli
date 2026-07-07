const std = @import("std");
const zcli = @import("zcli");
const registry = @import("command_registry");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

/// The tasks brand: a warm amber for command names and highlights, applied
/// everywhere — help output, prompts, and semantic styles.
pub const zcli_theme: zcli.Theme = .{
    .palette = .{
        .command = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } },
        .accent = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } },
    },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    app.run(init.gpa, init.io, init.environ_map, args) catch |err| switch (err) {
        error.CommandNotFound => std.process.exit(1),
        else => return err,
    };
}
