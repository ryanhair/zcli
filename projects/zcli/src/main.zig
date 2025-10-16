const std = @import("std");
const registry = @import("command_registry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }
    const allocator = gpa.allocator();

    var app = registry.init();

    app.run(allocator) catch |err| switch (err) {
        error.CommandNotFound => {
            // Error was already handled by plugins or registry
            std.process.exit(1);
        },
        else => return err,
    };
}
