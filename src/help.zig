const std = @import("std");
const logging = @import("logging.zig");
const args_parser = @import("args.zig");

pub fn generateCommandHelp(
    comptime command_module: type,
    writer: anytype,
    command_path: []const []const u8,
    app_name: []const u8,
) !void {
    const meta = if (@hasDecl(command_module, "meta")) command_module.meta else .{};

    // Command description
    if (@hasField(@TypeOf(meta), "description")) {
        try writer.print("{s}\n\n", .{meta.description});
    }

    // Usage line
    try writer.print("USAGE:\n", .{});
    try writer.print("    {s}", .{app_name});

    // Print command path
    for (command_path) |part| {
        try writer.print(" {s}", .{part});
    }

    // Add argument placeholders
    if (@hasDecl(command_module, "Args")) {
        try generateArgsUsage(command_module.Args, writer);
    }

    // Add options placeholder
    if (@hasDecl(command_module, "Options")) {
        try writer.print(" [OPTIONS]", .{});
    }

    try writer.print("\n\n", .{});

    // Arguments section
    if (@hasDecl(command_module, "Args")) {
        try generateArgsHelp(command_module.Args, writer);
    }

    // Options section
    if (@hasDecl(command_module, "Options")) {
        try generateOptionsHelp(command_module.Options, writer);
    }

    // Examples section
    if (@hasField(@TypeOf(meta), "examples")) {
        try writer.print("EXAMPLES:\n", .{});
        inline for (meta.examples) |example| {
            try writer.print("    {s}\n", .{example});
        }
        try writer.print("\n", .{});
    }
}

/// Generate main application help text showing available commands and global options.
///
/// This function outputs comprehensive help for the entire CLI application,
/// including the app description, global usage, and a list of all available commands.
///
/// ## Parameters
/// - `registry`: Command registry generated at build time
/// - `writer`: Output writer (typically stdout)
/// - `app_name`: Name of the CLI application
/// - `app_version`: Version string of the application
/// - `app_description`: Brief description of what the app does
///
/// ## Output Format
/// ```
/// myapp v1.0.0
/// A demonstration CLI built with zcli
///
/// USAGE:
///     myapp [GLOBAL OPTIONS] <COMMAND> [ARGS]
///
/// COMMANDS:
///     hello    Say hello to someone
///     users    User management commands
///
/// GLOBAL OPTIONS:
///     -h, --help       Show help information
///     -V, --version    Show version information
/// ```
///
/// ## Examples
/// ```zig
/// try zcli.generateAppHelp(
///     registry,
///     std.io.getStdOut().writer(),
///     "myapp",
///     "1.0.0",
///     "My CLI application"
/// );
/// ```
///
/// ## Usage
/// This is typically called automatically by the zcli framework when users
/// pass `--help` or when no command is specified (depending on configuration).
pub fn generateAppHelp(
    comptime registry: anytype,
    writer: anytype,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
) !void {
    try writer.print("{s} v{s}\n", .{ app_name, app_version });
    try writer.print("{s}\n\n", .{app_description});

    try writer.print("USAGE:\n", .{});
    try writer.print("    {s} [GLOBAL OPTIONS] <COMMAND> [ARGS]\n\n", .{app_name});

    try writer.print("COMMANDS:\n", .{});
    try generateTopLevelCommands(registry, writer);
    try writer.print("\n", .{});

    try writer.print("GLOBAL OPTIONS:\n", .{});
    try writer.print("    -h, --help       Show help information\n", .{});
    try writer.print("    -V, --version    Show version information\n", .{});

    // Generate help for user-defined global options if registry has GlobalOptions
    if (@hasDecl(@TypeOf(registry), "GlobalOptions")) {
        try generateGlobalOptionsHelp(registry.GlobalOptions, writer);
    }

    try writer.print("\n", .{});

    try writer.print("Run '{s} <command> --help' for more information on a command.\n", .{app_name});
}

/// Generate help for user-defined global options
fn generateGlobalOptionsHelp(comptime GlobalOptionsType: type, writer: anytype) !void {
    const type_info = @typeInfo(GlobalOptionsType);
    if (type_info != .@"struct") return;

    inline for (type_info.@"struct".fields) |field| {
        // Skip built-in fields if any
        if (std.mem.eql(u8, field.name, "help") or std.mem.eql(u8, field.name, "version")) continue;

        // Generate short flag (first letter of field name)
        const short_flag = field.name[0];

        try writer.print("    -{c}, --{s}", .{ short_flag, field.name });

        // Convert field name to kebab-case for display
        var name_buf: [64]u8 = undefined;
        const display_name = underscoresToDashes(name_buf[0..], field.name);
        if (!std.mem.eql(u8, field.name, display_name)) {
            try writer.print(" (--{s})", .{display_name});
        }

        // Add value placeholder for non-boolean types
        if (field.type != bool) {
            const type_name = @typeName(field.type);
            if (std.mem.startsWith(u8, type_name, "?")) {
                // Optional type - show the inner type
                try writer.print(" <{s}>", .{type_name[1..]});
            } else {
                try writer.print(" <{s}>", .{type_name});
            }
        }

        // Add default value info
        if (field.type == bool) {
            if (field.default_value) |default| {
                const default_bool = @as(*const bool, @ptrCast(@alignCast(default))).*;
                try writer.print("    (default: {s})", .{if (default_bool) "true" else "false"});
            } else {
                try writer.print("    (default: false)", .{});
            }
        } else if (@typeInfo(field.type) == .optional) {
            try writer.print("    (optional)", .{});
        }

        try writer.print("\n", .{});
    }
}

/// Convert underscores to dashes for display
fn underscoresToDashes(buf: []u8, input: []const u8) []const u8 {
    if (input.len > buf.len) {
        // Fallback: just return the original name if it's too long
        logging.fieldNameTooLong(input, 64);
        return input;
    }

    for (input, 0..) |char, i| {
        buf[i] = if (char == '_') '-' else char;
    }

    return buf[0..input.len];
}

fn generateArgsUsage(comptime args_type: type, writer: anytype) !void {
    const type_info = @typeInfo(args_type);
    if (type_info != .@"struct") return;

    inline for (type_info.@"struct".fields, 0..) |field, i| {
        try writer.print(" ", .{});

        if (args_parser.isVarArgs(field.type)) {
            try writer.print("[{s}...]", .{field.name});
        } else if (@typeInfo(field.type) == .optional) {
            try writer.print("[{s}]", .{field.name});
        } else {
            try writer.print("<{s}>", .{field.name});
        }

        // Only show first few args to keep usage line clean
        if (i >= 2) {
            try writer.print(" ...", .{});
            break;
        }
    }
}

fn generateArgsHelp(comptime args_type: type, writer: anytype) !void {
    const type_info = @typeInfo(args_type);
    if (type_info != .@"struct") return;

    if (type_info.@"struct".fields.len == 0) return;

    try writer.print("ARGS:\n", .{});

    inline for (type_info.@"struct".fields) |field| {
        try writer.print("    ", .{});

        if (args_parser.isVarArgs(field.type)) {
            try writer.print("[{s}...]    ", .{field.name});
        } else if (@typeInfo(field.type) == .optional) {
            try writer.print("[{s}]        ", .{field.name});
        } else {
            try writer.print("<{s}>        ", .{field.name});
        }

        // TODO: Add field documentation from comments or metadata
        try writer.print("(type: {s})\n", .{@typeName(field.type)});
    }

    try writer.print("\n", .{});
}

fn generateOptionsHelp(comptime options_type: type, writer: anytype) !void {
    const type_info = @typeInfo(options_type);
    if (type_info != .@"struct") return;

    if (type_info.@"struct".fields.len == 0) return;

    try writer.print("OPTIONS:\n", .{});

    inline for (type_info.@"struct".fields) |field| {
        // Generate short flag (first letter of field name)
        const short_flag = field.name[0];

        try writer.print("    -{c}, --{s}", .{ short_flag, field.name });

        // Add value placeholder for non-boolean types
        if (field.type != bool) {
            const type_name = @typeName(field.type);
            if (std.mem.startsWith(u8, type_name, "?")) {
                // Optional type - show the inner type
                try writer.print(" <{s}>", .{type_name[1..]});
            } else {
                try writer.print(" <{s}>", .{type_name});
            }
        }

        // Add default value info
        if (field.type == bool) {
            try writer.print("    (default: false)", .{});
        } else if (@typeInfo(field.type) == .optional) {
            try writer.print("    (optional)", .{});
        }

        try writer.print("\n", .{});
    }

    try writer.print("\n", .{});
}

pub fn generateSubcommandsList(comptime group: anytype, writer: anytype) !void {
    const GroupType = @TypeOf(group);

    // Iterate through all fields in the group struct
    inline for (@typeInfo(GroupType).@"struct".fields) |field| {
        // Skip metadata fields that start with underscore
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;

        const subcommand = @field(group, field.name);
        const subcommand_type_info = @typeInfo(@TypeOf(subcommand));

        if (subcommand_type_info == .@"struct") {
            // Check if this is a nested command group
            const subcommand_struct_info = subcommand_type_info.@"struct";
            comptime var is_nested_group = false;
            inline for (subcommand_struct_info.fields) |subcmd_field| {
                if (comptime std.mem.eql(u8, subcmd_field.name, "_is_group")) {
                    is_nested_group = true;
                    break;
                }
            }

            if (comptime is_nested_group) {
                // This is a nested command group
                try writer.print("    {s}        (nested command group)\n", .{field.name});
            } else {
                // This is a regular subcommand entry with .module and .execute
                if (comptime @hasField(@TypeOf(subcommand), "module")) {
                    const module = subcommand.module;
                    if (comptime @hasDecl(module, "meta")) {
                        const meta = module.meta;
                        if (comptime @hasField(@TypeOf(meta), "description")) {
                            try writer.print("    {s:<12} {s}\n", .{ field.name, meta.description });
                        } else {
                            try writer.print("    {s}\n", .{field.name});
                        }
                    } else {
                        try writer.print("    {s}\n", .{field.name});
                    }
                } else {
                    try writer.print("    {s}\n", .{field.name});
                }
            }
        } else {
            // This shouldn't happen with the new registry structure, but handle gracefully
            try writer.print("    {s}\n", .{field.name});
        }
    }
}

fn generateTopLevelCommands(comptime registry: anytype, writer: anytype) !void {
    const commands = registry.commands;
    const CommandsType = @TypeOf(commands);

    // Iterate through all fields in the commands struct
    inline for (@typeInfo(CommandsType).@"struct".fields) |field| {
        // Skip metadata fields that start with underscore (comptime condition)
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;

        const command = @field(commands, field.name);
        const command_type_info = @typeInfo(@TypeOf(command));

        if (command_type_info == .@"struct") {
            // Check if this is a command group
            const command_struct_info = command_type_info.@"struct";
            comptime var is_group = false;
            inline for (command_struct_info.fields) |cmd_field| {
                if (comptime std.mem.eql(u8, cmd_field.name, "_is_group")) {
                    is_group = true;
                    break;
                }
            }

            if (comptime is_group) {
                // This is a command group
                try writer.print("    {s}        (command group)\n", .{field.name});
            } else {
                // This is a regular command entry with .module and .execute
                if (comptime @hasField(@TypeOf(command), "module")) {
                    const module = command.module;
                    if (comptime @hasDecl(module, "meta")) {
                        const meta = module.meta;
                        if (comptime @hasField(@TypeOf(meta), "description")) {
                            try writer.print("    {s:<12} {s}\n", .{ field.name, meta.description });
                        } else {
                            try writer.print("    {s}\n", .{field.name});
                        }
                    } else {
                        try writer.print("    {s}\n", .{field.name});
                    }
                } else {
                    try writer.print("    {s}\n", .{field.name});
                }
            }
        } else {
            // This shouldn't happen with the new registry structure, but handle gracefully
            try writer.print("    {s}\n", .{field.name});
        }
    }
}

/// Extract available command names from registry for error handling
pub fn getAvailableCommands(comptime registry: anytype, allocator: std.mem.Allocator) ![][]const u8 {
    const commands = registry.commands;
    const CommandsType = @TypeOf(commands);

    // Count available commands (excluding metadata fields)
    comptime var count: usize = 0;
    inline for (@typeInfo(CommandsType).@"struct".fields) |field| {
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;
        count += 1;
    }

    // Allocate and fill array
    var result = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    inline for (@typeInfo(CommandsType).@"struct".fields) |field| {
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;
        result[i] = field.name;
        i += 1;
    }

    return result;
}

/// Extract available subcommand names from group for error handling
pub fn getAvailableSubcommands(comptime group: anytype, allocator: std.mem.Allocator) ![][]const u8 {
    const GroupType = @TypeOf(group);

    // Count available subcommands (excluding metadata fields)
    comptime var count: usize = 0;
    inline for (@typeInfo(GroupType).@"struct".fields) |field| {
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;
        count += 1;
    }

    // Allocate and fill array
    var result = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    inline for (@typeInfo(GroupType).@"struct".fields) |field| {
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;
        result[i] = field.name;
        i += 1;
    }

    return result;
}

// Tests
test "getAvailableCommands" {
    const allocator = std.testing.allocator;

    const TestRegistry = struct {
        commands: struct {
            root: struct { module: type, execute: fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void },
            hello: struct { module: type, execute: fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void },
            users: struct { _is_group: bool = true },
            @"test": struct { module: type, execute: fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void },
        },
    };

    const registry = TestRegistry{
        .commands = .{
            .root = .{ .module = struct {}, .execute = undefined },
            .hello = .{ .module = struct {}, .execute = undefined },
            .users = .{ ._is_group = true },
            .@"test" = .{ .module = struct {}, .execute = undefined },
        },
    };

    const commands = try getAvailableCommands(registry, allocator);
    defer allocator.free(commands);

    // Should get all non-metadata commands
    try std.testing.expectEqual(@as(usize, 4), commands.len);

    // Check that all expected commands are present
    var found_root = false;
    var found_hello = false;
    var found_users = false;
    var found_test = false;

    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd, "root")) found_root = true;
        if (std.mem.eql(u8, cmd, "hello")) found_hello = true;
        if (std.mem.eql(u8, cmd, "users")) found_users = true;
        if (std.mem.eql(u8, cmd, "test")) found_test = true;
    }

    try std.testing.expect(found_root);
    try std.testing.expect(found_hello);
    try std.testing.expect(found_users);
    try std.testing.expect(found_test);
}

test "getAvailableSubcommands" {
    const allocator = std.testing.allocator;

    const TestGroup = struct {
        _is_group: bool = true,
        _index: struct { module: type, execute: fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void },
        list: struct { module: type, execute: fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void },
        search: struct { module: type, execute: fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void },
        create: struct { module: type, execute: fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void },
    };

    const group = TestGroup{
        ._is_group = true,
        ._index = .{ .module = struct {}, .execute = undefined },
        .list = .{ .module = struct {}, .execute = undefined },
        .search = .{ .module = struct {}, .execute = undefined },
        .create = .{ .module = struct {}, .execute = undefined },
    };

    const subcommands = try getAvailableSubcommands(group, allocator);
    defer allocator.free(subcommands);

    // Should exclude metadata fields (_is_group, _index)
    try std.testing.expectEqual(@as(usize, 3), subcommands.len);

    // Check that all expected subcommands are present
    var found_list = false;
    var found_search = false;
    var found_create = false;

    for (subcommands) |cmd| {
        if (std.mem.eql(u8, cmd, "list")) found_list = true;
        if (std.mem.eql(u8, cmd, "search")) found_search = true;
        if (std.mem.eql(u8, cmd, "create")) found_create = true;
    }

    try std.testing.expect(found_list);
    try std.testing.expect(found_search);
    try std.testing.expect(found_create);
}

test "generateCommandHelp basic" {
    const TestCommand = struct {
        pub const meta = .{
            .description = "Test command",
            .examples = &.{ "test example1", "test example2" },
        };

        pub const Args = struct {
            name: []const u8,
            files: [][]const u8 = &.{},
        };

        pub const Options = struct {
            verbose: bool = false,
            count: u32 = 1,
        };
    };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try generateCommandHelp(TestCommand, stream.writer(), &.{"test"}, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Test command") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "USAGE:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp test") != null);
}

test "generateCommandHelp no meta" {
    const TestCommand = struct {
        // No meta field

        pub const Args = struct {
            file: []const u8,
        };
    };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try generateCommandHelp(TestCommand, stream.writer(), &.{"process"}, "myapp");

    const output = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "USAGE:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp process") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<file>") != null);
}

test "generateCommandHelp with subcommand path" {
    const TestCommand = struct {
        pub const meta = .{
            .description = "Manage user accounts",
        };

        pub const Args = struct {
            username: []const u8,
            email: ?[]const u8,
        };

        pub const Options = struct {
            admin: bool = false,
            quota: ?u64 = null,
        };
    };

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const path = [_][]const u8{ "users", "create" };
    try generateCommandHelp(TestCommand, stream.writer(), &path, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Manage user accounts") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp users create") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<username>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[email]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--admin") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--quota") != null);
}

test "generateCommandHelp varargs" {
    const TestCommand = struct {
        pub const Args = struct {
            command: []const u8,
            args: [][]const u8,
        };
    };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try generateCommandHelp(TestCommand, stream.writer(), &.{"exec"}, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "<command>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[args...]") != null);
}

test "generateCommandHelp all optional args" {
    const TestCommand = struct {
        pub const Args = struct {
            first: ?[]const u8,
            second: ?[]const u8,
            third: ?i32,
        };
    };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try generateCommandHelp(TestCommand, stream.writer(), &.{"maybe"}, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "[first]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[second]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[third]") != null);
}

test "generateCommandHelp with examples" {
    const TestCommand = struct {
        pub const meta = .{
            .description = "Copy files",
            .examples = &[_][]const u8{
                "myapp copy source.txt dest.txt",
                "myapp copy -r /src /dest",
                "myapp copy --verbose file1 file2",
            },
        };

        pub const Args = struct {
            source: []const u8,
            destination: []const u8,
        };

        pub const Options = struct {
            recursive: bool = false,
            verbose: bool = false,
        };
    };

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try generateCommandHelp(TestCommand, stream.writer(), &.{"copy"}, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "EXAMPLES:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp copy source.txt dest.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp copy -r /src /dest") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp copy --verbose file1 file2") != null);
}

test "generateOptionsHelp all option types" {
    const TestOptions = struct {
        // Boolean flags
        verbose: bool = false,
        quiet: bool = false,

        // Required options
        output: []const u8,

        // Optional options
        timeout: ?i32 = null,
        format: ?[]const u8 = null,

        // Numeric options
        port: u16 = 8080,
        threads: u8 = 4,

        // Enum option
        level: enum { debug, info, warn, err } = .info,
    };

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try generateOptionsHelp(TestOptions, stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "OPTIONS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--quiet") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--output") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--format") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--port") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--threads") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--level") != null);
}
