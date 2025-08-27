const std = @import("std");
const testing = std.testing;
const command_parser = @import("command_parser.zig");

// Test structures for various scenarios
const BasicArgs = struct {
    file: []const u8,
    output: ?[]const u8 = null,
};

const BasicOptions = struct {
    verbose: bool = false,
    debug: bool = false,
    count: u32 = 1,
    format: enum { json, yaml, xml } = .json,
};

const ArrayOptions = struct {
    files: [][]const u8 = &.{},
    numbers: []i32 = &.{},
    verbose: bool = false,
};

const ComplexArgs = struct {
    command: []const u8,
    target: []const u8,
    sources: [][]const u8 = &.{}, // varargs
};

const ComplexOptions = struct {
    optimize: enum { debug, fast, small } = .debug,
    features: [][]const u8 = &.{},
    define: [][]const u8 = &.{},
    verbose: bool = false,
    dry_run: bool = false,
};

// Basic argument parsing tests
test "e2e: arguments only" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(BasicArgs, struct {}, null, allocator, &.{ "input.txt", "output.txt" });
    defer result.deinit();

    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);
}

test "e2e: optional arguments" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(BasicArgs, struct {}, null, allocator, &.{"input.txt"});
    defer result.deinit();

    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expect(result.args.output == null);
}

// Basic option parsing tests
test "e2e: boolean flags only" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(struct {}, BasicOptions, null, allocator, &.{ "--verbose", "--debug" });
    defer result.deinit();

    try testing.expect(result.options.verbose);
    try testing.expect(result.options.debug);
    try testing.expectEqual(@as(u32, 1), result.options.count); // default
    try testing.expectEqual(.json, result.options.format); // default
}

test "e2e: value options" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(struct {}, BasicOptions, null, allocator, &.{ "--count", "42", "--format", "yaml" });
    defer result.deinit();

    try testing.expect(!result.options.verbose); // default
    try testing.expect(!result.options.debug); // default
    try testing.expectEqual(@as(u32, 42), result.options.count);
    try testing.expectEqual(.yaml, result.options.format);
}

// Mixed parsing tests (the main regression protection)
test "e2e: options after arguments" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(BasicArgs, BasicOptions, null, allocator, &.{ "input.txt", "--verbose", "output.txt", "--count", "10" });
    defer result.deinit();

    // Arguments should be parsed correctly
    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);

    // Options should be parsed correctly
    try testing.expect(result.options.verbose);
    try testing.expectEqual(@as(u32, 10), result.options.count);
}

test "e2e: options before arguments" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(BasicArgs, BasicOptions, null, allocator, &.{ "--verbose", "--count", "5", "input.txt", "output.txt" });
    defer result.deinit();

    // Arguments should be parsed correctly
    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);

    // Options should be parsed correctly
    try testing.expect(result.options.verbose);
    try testing.expectEqual(@as(u32, 5), result.options.count);
}

test "e2e: fully interleaved options and arguments" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(BasicArgs, BasicOptions, null, allocator, &.{ "--debug", "input.txt", "--count", "3", "--verbose", "output.txt" });
    defer result.deinit();

    // Arguments should be parsed correctly
    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);

    // Options should be parsed correctly
    try testing.expect(result.options.verbose);
    try testing.expect(result.options.debug);
    try testing.expectEqual(@as(u32, 3), result.options.count);
}

// Array option tests
test "e2e: multiple array values" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(struct {}, ArrayOptions, null, allocator, &.{ "--files", "a.txt", "--files", "b.txt", "--files", "c.txt" });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.options.files.len);
    try testing.expectEqualStrings("a.txt", result.options.files[0]);
    try testing.expectEqualStrings("b.txt", result.options.files[1]);
    try testing.expectEqualStrings("c.txt", result.options.files[2]);
}

test "e2e: array options mixed with other options" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(struct {}, ArrayOptions, null, allocator, &.{ "--files", "first.txt", "--verbose", "--files", "second.txt", "--numbers", "42" });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.options.files.len);
    try testing.expectEqualStrings("first.txt", result.options.files[0]);
    try testing.expectEqualStrings("second.txt", result.options.files[1]);

    try testing.expectEqual(@as(usize, 1), result.options.numbers.len);
    try testing.expectEqual(@as(i32, 42), result.options.numbers[0]);

    try testing.expect(result.options.verbose);
}

test "e2e: array options with arguments mixed" {
    const allocator = testing.allocator;

    const ComplexArgsForArray = struct {
        command: []const u8,
        target: ?[]const u8 = null,
    };

    const result = try command_parser.parseCommandLine(ComplexArgsForArray, ArrayOptions, null, allocator, &.{ "build", "--files", "main.zig", "release", "--files", "utils.zig", "--verbose" });
    defer result.deinit();

    // Arguments parsed correctly
    try testing.expectEqualStrings("build", result.args.command);
    try testing.expectEqualStrings("release", result.args.target.?);

    // Array options parsed correctly
    try testing.expectEqual(@as(usize, 2), result.options.files.len);
    try testing.expectEqualStrings("main.zig", result.options.files[0]);
    try testing.expectEqualStrings("utils.zig", result.options.files[1]);

    try testing.expect(result.options.verbose);
}

// Complex real-world scenarios
test "e2e: git-like command" {
    const allocator = testing.allocator;

    const GitArgs = struct {
        repository: ?[]const u8 = null,
    };

    const GitOptions = struct {
        bare: bool = false,
        shared: bool = false,
        template: ?[]const u8 = null,
    };

    const result = try command_parser.parseCommandLine(GitArgs, GitOptions, null, allocator, &.{ "my-repo", "--bare", "--template", "/path/to/template" });
    defer result.deinit();

    try testing.expectEqualStrings("my-repo", result.args.repository.?);
    try testing.expect(result.options.bare);
    try testing.expectEqualStrings("/path/to/template", result.options.template.?);
    try testing.expect(!result.options.shared); // default
}

test "e2e: docker-like command with filters" {
    const allocator = testing.allocator;

    const DockerArgs = struct {};

    const DockerOptions = struct {
        all: bool = false,
        filter: [][]const u8 = &.{},
        format: ?[]const u8 = null,
        quiet: bool = false,
    };

    const result = try command_parser.parseCommandLine(DockerArgs, DockerOptions, null, allocator, &.{ "--filter", "status=running", "--all", "--filter", "name=web", "--quiet" });
    defer result.deinit();

    try testing.expect(result.options.all);
    try testing.expect(result.options.quiet);

    try testing.expectEqual(@as(usize, 2), result.options.filter.len);
    try testing.expectEqualStrings("status=running", result.options.filter[0]);
    try testing.expectEqualStrings("name=web", result.options.filter[1]);
}

test "e2e: build tool with complex options" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(ComplexArgs, ComplexOptions, null, allocator, &.{ "build", "x86_64-linux", "--optimize", "fast", "src/main.zig", "src/utils.zig", "--features", "ssl", "--features", "json", "--define", "VERSION=1.0", "--define", "DEBUG=false", "--verbose" });
    defer result.deinit();

    // Arguments
    try testing.expectEqualStrings("build", result.args.command);
    try testing.expectEqualStrings("x86_64-linux", result.args.target);
    try testing.expectEqual(@as(usize, 2), result.args.sources.len);
    try testing.expectEqualStrings("src/main.zig", result.args.sources[0]);
    try testing.expectEqualStrings("src/utils.zig", result.args.sources[1]);

    // Options
    try testing.expectEqual(.fast, result.options.optimize);
    try testing.expect(result.options.verbose);

    try testing.expectEqual(@as(usize, 2), result.options.features.len);
    try testing.expectEqualStrings("ssl", result.options.features[0]);
    try testing.expectEqualStrings("json", result.options.features[1]);

    try testing.expectEqual(@as(usize, 2), result.options.define.len);
    try testing.expectEqualStrings("VERSION=1.0", result.options.define[0]);
    try testing.expectEqualStrings("DEBUG=false", result.options.define[1]);
}

// Edge cases
test "e2e: double dash separator" {
    const allocator = testing.allocator;

    const result = try command_parser.parseCommandLine(ComplexArgs, BasicOptions, null, allocator, &.{ "grep", "pattern", "--verbose", "--", "--looks-like-option", "file.txt" });
    defer result.deinit();

    // Arguments: everything after -- should be treated as positional
    try testing.expectEqualStrings("grep", result.args.command);
    try testing.expectEqualStrings("pattern", result.args.target);
    try testing.expectEqual(@as(usize, 2), result.args.sources.len);
    try testing.expectEqualStrings("--looks-like-option", result.args.sources[0]);
    try testing.expectEqualStrings("file.txt", result.args.sources[1]);

    // Options: only options before -- should be processed
    try testing.expect(result.options.verbose);
}

test "e2e: negative numbers as arguments" {
    const allocator = testing.allocator;

    const NumberArgs = struct {
        threshold: []const u8, // Will be "-5"
        value: ?[]const u8 = null,
    };

    const result = try command_parser.parseCommandLine(NumberArgs, BasicOptions, null, allocator, &.{ "--verbose", "-5", "--count", "10", "-42" });
    defer result.deinit();

    // Negative numbers should be treated as arguments, not options
    try testing.expectEqualStrings("-5", result.args.threshold);
    try testing.expectEqualStrings("-42", result.args.value.?);

    // Real options should still work
    try testing.expect(result.options.verbose);
    try testing.expectEqual(@as(u32, 10), result.options.count);
}

test "e2e: empty string values" {
    const allocator = testing.allocator;

    const EmptyArgs = struct {
        name: []const u8,
        message: ?[]const u8 = null,
    };

    const EmptyOptions = struct {
        output: ?[]const u8 = null,
        prefix: []const u8 = "default",
    };

    const result = try command_parser.parseCommandLine(EmptyArgs, EmptyOptions, null, allocator, &.{ "test", "", "--output", "", "--prefix", "custom" });
    defer result.deinit();

    try testing.expectEqualStrings("test", result.args.name);
    try testing.expectEqualStrings("", result.args.message.?);
    try testing.expectEqualStrings("", result.options.output.?);
    try testing.expectEqualStrings("custom", result.options.prefix);
}

// Error condition tests
test "e2e: missing required arguments" {
    const allocator = testing.allocator;

    // BasicArgs requires 'file', so this should fail
    const result = command_parser.parseCommandLine(BasicArgs, BasicOptions, null, allocator, &.{"--verbose"} // Only options, no required args
    );

    try testing.expectError(command_parser.ZcliError.ArgumentMissingRequired, result);
}

test "e2e: too many arguments" {
    const allocator = testing.allocator;

    const LimitedArgs = struct {
        single_arg: []const u8,
    };

    // LimitedArgs only accepts 1 argument, so this should fail
    const result = command_parser.parseCommandLine(LimitedArgs, BasicOptions, null, allocator, &.{ "arg1", "arg2", "arg3" } // Too many args
    );

    try testing.expectError(command_parser.ZcliError.ArgumentTooMany, result);
}

test "e2e: unknown option" {
    const allocator = testing.allocator;

    // BasicOptions doesn't have --unknown, so this should fail
    const result = command_parser.parseCommandLine(BasicArgs, BasicOptions, null, allocator, &.{ "input.txt", "--unknown", "value" });

    try testing.expectError(command_parser.ZcliError.OptionUnknown, result);
}

// Integration tests with the actual examples
test "e2e: basic example init command scenarios" {
    const allocator = testing.allocator;

    // Simulate the exact Args/Options from examples/basic/src/commands/init.zig
    const InitArgs = struct {
        directory: ?[]const u8 = null,
    };

    const InitOptions = struct {
        bare: bool = false,
    };

    // All the scenarios that were previously failing

    // 1. Option only
    {
        const result = try command_parser.parseCommandLine(InitArgs, InitOptions, null, allocator, &.{"--bare"});
        defer result.deinit();

        try testing.expect(result.args.directory == null);
        try testing.expect(result.options.bare);
    }

    // 2. Argument then option
    {
        const result = try command_parser.parseCommandLine(InitArgs, InitOptions, null, allocator, &.{ "test-repo", "--bare" });
        defer result.deinit();

        try testing.expectEqualStrings("test-repo", result.args.directory.?);
        try testing.expect(result.options.bare);
    }

    // 3. Argument only
    {
        const result = try command_parser.parseCommandLine(InitArgs, InitOptions, null, allocator, &.{"new-repo"});
        defer result.deinit();

        try testing.expectEqualStrings("new-repo", result.args.directory.?);
        try testing.expect(!result.options.bare);
    }

    // 4. Option then argument
    {
        const result = try command_parser.parseCommandLine(InitArgs, InitOptions, null, allocator, &.{ "--bare", "another-repo" });
        defer result.deinit();

        try testing.expectEqualStrings("another-repo", result.args.directory.?);
        try testing.expect(result.options.bare);
    }
}

test "e2e: advanced example container ls scenarios" {
    const allocator = testing.allocator;

    // Simulate the exact Args/Options from examples/advanced/src/commands/container/ls.zig
    const ContainerArgs = struct {};

    const ContainerOptions = struct {
        all: bool = false,
        filter: [][]const u8 = &.{},
        format: ?[]const u8 = null,
        last: ?u32 = null,
        latest: bool = false,
        no_trunc: bool = false,
        quiet: bool = false,
        size: bool = false,
    };

    // Complex array option scenarios that work in production

    // 1. Multiple filters with other options
    {
        const result = try command_parser.parseCommandLine(ContainerArgs, ContainerOptions, null, allocator, &.{ "--filter", "status=running", "--filter", "name=web", "--all" });
        defer result.deinit();

        try testing.expect(result.options.all);
        try testing.expectEqual(@as(usize, 2), result.options.filter.len);
        try testing.expectEqualStrings("status=running", result.options.filter[0]);
        try testing.expectEqualStrings("name=web", result.options.filter[1]);
    }

    // 2. Mixed option ordering
    {
        const result = try command_parser.parseCommandLine(ContainerArgs, ContainerOptions, null, allocator, &.{ "--all", "--filter", "status=Up", "--quiet" });
        defer result.deinit();

        try testing.expect(result.options.all);
        try testing.expect(result.options.quiet);
        try testing.expectEqual(@as(usize, 1), result.options.filter.len);
        try testing.expectEqualStrings("status=Up", result.options.filter[0]);
    }
}
