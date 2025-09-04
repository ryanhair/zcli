//! ZTheme Demo CLI - Entry point
//!
//! Minimal main.zig that delegates to zcli framework

const std = @import("std");
const registry = @import("command_registry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = registry.registry.init();

    app.run(allocator) catch |err| switch (err) {
        error.CommandNotFound => {
            // Error was already handled by plugins or registry
            std.process.exit(1);
        },
        else => return err,
    };
}
