const std = @import("std");
const zcli = @import("zcli");
const registry = @import("command_registry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = zcli.App(@TypeOf(registry.registry), registry).init(
        allocator,
        registry.registry,
        .{
            .name = registry.app_name,
            .version = registry.app_version,
            .description = registry.app_description,
        },
    );

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try app.run(args[1..]);
}
