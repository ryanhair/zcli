const std = @import("std");
const help = @import("help.zig");

test "extracted help functions are available" {
    // Test that we can call the extracted help functions
    try std.testing.expect(@hasDecl(help, "generateCommandHelp"));
    try std.testing.expect(@hasDecl(help, "generateAppHelp"));
    try std.testing.expect(@hasDecl(help, "getAvailableCommands"));
    try std.testing.expect(@hasDecl(help, "getAvailableSubcommands"));
    try std.testing.expect(@hasDecl(help, "generateSubcommandsList"));
}

test "basic help generation" {
    const TestCommand = struct {
        pub const meta = .{
            .description = "Test command for extraction verification",
        };

        pub const Args = struct {
            name: []const u8,
        };

        pub const Options = struct {
            verbose: bool = false,
        };
    };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try help.generateCommandHelp(TestCommand, stream.writer(), &.{"test"}, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Test command for extraction verification") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "USAGE:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--verbose") != null);
}

test "app help generation" {
    const TestRegistry = struct {
        commands: struct {
            hello: struct {
                module: type,
                execute: fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void,
            },
            @"test": struct {
                module: type,
                execute: fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void,
            },
        },
    };

    const registry = TestRegistry{
        .commands = .{
            .hello = .{ .module = struct {}, .execute = undefined },
            .@"test" = .{ .module = struct {}, .execute = undefined },
        },
    };

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try help.generateAppHelp(registry, stream.writer(), "myapp", "1.0.0", "Test application for extraction verification");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test application for extraction verification") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "USAGE:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "COMMANDS:") != null);
}
