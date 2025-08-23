const std = @import("std");
const zcli = @import("zcli.zig");
const options = @import("options.zig");

test "parseOptions with array of strings (filter option)" {
    const allocator = std.testing.allocator;

    // Define an Options struct similar to container ls
    const TestOptions = struct {
        all: bool = false,
        filter: []const []const u8 = &.{},
        quiet: bool = false,
    };

    // Test case 1: No filter options provided
    {
        const args = [_][]const u8{"--all"};
        const result = options.parseOptions(TestOptions, allocator, &args);
        if (result.isError()) {
            std.debug.print("Parse error: {any}\n", .{result.getError()});
            return error.ParseFailed;
        }
        const parsed = result.unwrap();
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == true);
        try std.testing.expect(parsed.options.filter.len == 0);
        try std.testing.expect(parsed.options.quiet == false);
    }

    // Test case 2: Single filter option
    {
        const args = [_][]const u8{ "--filter", "status=running" };
        const result = options.parseOptions(TestOptions, allocator, &args);
        if (result.isError()) {
            std.debug.print("Parse error: {any}\n", .{result.getError()});
            return error.ParseFailed;
        }
        const parsed = result.unwrap();
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == false);
        try std.testing.expect(parsed.options.filter.len == 1);
        try std.testing.expectEqualStrings(parsed.options.filter[0], "status=running");
    }

    // Test case 3: Multiple filter options
    {
        const args = [_][]const u8{ "--filter", "status=running", "--filter", "name=web" };
        const result = options.parseOptions(TestOptions, allocator, &args);
        if (result.isError()) {
            std.debug.print("Parse error: {any}\n", .{result.getError()});
            return error.ParseFailed;
        }
        const parsed = result.unwrap();
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.filter.len == 2);
        try std.testing.expectEqualStrings(parsed.options.filter[0], "status=running");
        try std.testing.expectEqualStrings(parsed.options.filter[1], "name=web");
    }

    // Test case 4: Mixed options with filters
    {
        const args = [_][]const u8{ "--all", "--filter", "status=exited", "--quiet" };
        const result = options.parseOptions(TestOptions, allocator, &args);
        if (result.isError()) {
            std.debug.print("Parse error: {any}\n", .{result.getError()});
            return error.ParseFailed;
        }
        const parsed = result.unwrap();
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == true);
        try std.testing.expect(parsed.options.quiet == true);
        try std.testing.expect(parsed.options.filter.len == 1);
        try std.testing.expectEqualStrings(parsed.options.filter[0], "status=exited");
    }
}

test "array options default initialization" {
    const allocator = std.testing.allocator;

    const TestOptions = struct {
        filter: []const []const u8 = &.{},
        env: []const []const u8 = &.{},
        volume: []const []const u8 = &.{},
    };

    // Parse with no arguments - should use defaults
    const args = [_][]const u8{};
    const result = options.parseOptions(TestOptions, allocator, &args);
    if (result.isError()) {
        std.debug.print("Parse error: {any}\n", .{result.getError()});
        return error.ParseFailed;
    }
    const parsed = result.unwrap();
    defer options.cleanupOptions(TestOptions, parsed.options, allocator);

    // All array options should be empty but valid (not null/undefined)
    try std.testing.expect(parsed.options.filter.len == 0);
    try std.testing.expect(parsed.options.env.len == 0);
    try std.testing.expect(parsed.options.volume.len == 0);

    // Should be safe to iterate over empty arrays
    for (parsed.options.filter) |f| {
        _ = f; // This should not crash
    }
    for (parsed.options.env) |e| {
        _ = e; // This should not crash
    }
    for (parsed.options.volume) |v| {
        _ = v; // This should not crash
    }
}

test "basic array options iteration" {
    const allocator = std.testing.allocator;

    const TestOptions = struct {
        filter: []const []const u8 = &.{},
        env: []const []const u8 = &.{},
    };

    // Test with no options provided
    {
        const args = [_][]const u8{};
        const result = options.parseOptions(TestOptions, allocator, &args);
        if (result.isError()) {
            std.debug.print("Parse error: {any}\n", .{result.getError()});
            return error.ParseFailed;
        }
        const parsed = result.unwrap();
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        // This should not crash even with default empty arrays
        try std.testing.expect(parsed.options.filter.len == 0);
        try std.testing.expect(parsed.options.env.len == 0);

        // Should be safe to iterate
        for (parsed.options.filter) |filter| {
            _ = filter;
        }

        for (parsed.options.env) |env| {
            _ = env;
        }
    }

    // Test with array options provided
    {
        const args = [_][]const u8{ "--filter", "test=value", "--env", "FOO=bar" };
        const result = options.parseOptions(TestOptions, allocator, &args);
        if (result.isError()) {
            std.debug.print("Parse error: {any}\n", .{result.getError()});
            return error.ParseFailed;
        }
        const parsed = result.unwrap();
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.filter.len == 1);
        try std.testing.expect(parsed.options.env.len == 1);

        // Should be safe to iterate
        for (parsed.options.filter) |filter| {
            try std.testing.expectEqualStrings(filter, "test=value");
        }

        for (parsed.options.env) |env| {
            try std.testing.expectEqualStrings(env, "FOO=bar");
        }
    }
}

test "actual container ls options parsing" {
    const allocator = std.testing.allocator;

    // This is the actual Options struct from container ls
    const ContainerLsOptions = struct {
        all: bool = false,
        filter: []const []const u8 = &.{},
        format: ?[]const u8 = null,
        last: ?u32 = null,
        latest: bool = false,
        no_trunc: bool = false,
        quiet: bool = false,
        size: bool = false,
    };

    // Test the exact case that was causing segfault
    {
        const args = [_][]const u8{"--all"};
        const result = options.parseOptions(ContainerLsOptions, allocator, &args);
        if (result.isError()) {
            std.debug.print("Parse error: {any}\n", .{result.getError()});
            return error.ParseFailed;
        }
        const parsed = result.unwrap();
        defer options.cleanupOptions(ContainerLsOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == true);
        try std.testing.expect(parsed.options.filter.len == 0);

        // This iteration was causing the segfault in the real code
        for (parsed.options.filter) |filter| {
            _ = filter;
        }
    }
}
