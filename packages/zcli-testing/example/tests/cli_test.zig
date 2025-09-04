const std = @import("std");
const zcli = @import("zcli");
const testing = @import("zcli_testing");
const registry = @import("command_registry");

// Basic functionality tests for the example CLI

test "help command displays usage" {
    const allocator = std.testing.allocator;

    var result = try testing.runWithRegistry(allocator, registry.registry, &.{"--help"});
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stderr, "example-cli v1.0.0");
    try testing.expectContains(result.stderr, "USAGE:");
    try testing.expectContains(result.stderr, "COMMANDS:");
}

test "version flag shows error (not implemented)" {
    const allocator = std.testing.allocator;

    var result = try testing.runWithRegistry(allocator, registry.registry, &.{"--version"});
    defer result.deinit();

    // The current CLI doesn't support --version flag, returns error
    try testing.expectExitCode(result, 1);
    try testing.expectContains(result.stderr, "command --version not found");
}

test "hello command with default name" {
    const allocator = std.testing.allocator;

    var result = try testing.runWithRegistry(allocator, registry.registry, &.{"hello"});
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "Hello, World.");
}

test "hello command with custom name and greeting" {
    const allocator = std.testing.allocator;

    var result = try testing.runWithRegistry(allocator, registry.registry, &.{ "hello", "--greeting=Hi", "--excited", "zcli" });
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "Hi, zcli!");
}

test "echo command basic" {
    const allocator = std.testing.allocator;

    var result = try testing.runWithRegistry(allocator, registry.registry, &.{ "echo", "Hello", "World" });
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "Hello.d World.d");
}

test "echo command uppercase" {
    const allocator = std.testing.allocator;

    var result = try testing.runWithRegistry(allocator, registry.registry, &.{ "echo", "--uppercase", "hello", "world" });
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "HELLO WORLD");
}

test "echo command no newline" {
    const allocator = std.testing.allocator;

    var result = try testing.runWithRegistry(allocator, registry.registry, &.{ "echo", "--no-newline", "test" });
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "test.d");
    // Should not contain newline at end
    try testing.expectEqualStrings("test.d", result.stdout);
}

test "unknown command shows error" {
    const allocator = std.testing.allocator;

    var result = try testing.runWithRegistry(allocator, registry.registry, &.{"unknown"});
    defer result.deinit();

    try testing.expectExitCode(result, 1);
    try testing.expectContains(result.stderr, "command unknown not found");
}

// Snapshot tests for consistent output

test "help command output snapshot" {
    const allocator = std.testing.allocator;

    var result = try testing.runWithRegistry(allocator, registry.registry, &.{"--help"});
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectSnapshot(result.stderr, @src(), "help_output");
}

test "hello command variations snapshot" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    // Default hello
    {
        var result = try testing.runWithRegistry(allocator, registry.registry, &.{"hello"});
        defer result.deinit();
        try output.writer().print("Default: {s}", .{result.stdout});
    }

    // Custom greeting
    {
        var result = try testing.runWithRegistry(allocator, registry.registry, &.{ "hello", "--greeting=Hi", "zcli" });
        defer result.deinit();
        try output.writer().print("Custom: {s}", .{result.stdout});
    }

    // Excited
    {
        var result = try testing.runWithRegistry(allocator, registry.registry, &.{ "hello", "--excited", "World" });
        defer result.deinit();
        try output.writer().print("Excited: {s}", .{result.stdout});
    }

    try testing.expectSnapshot(output.items, @src(), "hello_variations");
}

test "echo command variations snapshot" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    // Basic echo
    {
        var result = try testing.runWithRegistry(allocator, registry.registry, &.{ "echo", "Hello", "World" });
        defer result.deinit();
        try output.writer().print("Basic: {s}", .{result.stdout});
    }

    // Uppercase echo
    {
        var result = try testing.runWithRegistry(allocator, registry.registry, &.{ "echo", "--uppercase", "hello", "world" });
        defer result.deinit();
        try output.writer().print("Uppercase: {s}", .{result.stdout});
    }

    // No newline
    {
        var result = try testing.runWithRegistry(allocator, registry.registry, &.{ "echo", "--no-newline", "test" });
        defer result.deinit();
        try output.writer().print("No newline: '{s}'\\n", .{result.stdout});
    }

    try testing.expectSnapshot(output.items, @src(), "echo_variations");
}
