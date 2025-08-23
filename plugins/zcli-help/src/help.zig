const std = @import("std");

/// Helper function to get field description from command metadata
fn getFieldDescription(comptime meta: anytype, comptime field_name: []const u8, comptime category: []const u8) ?[]const u8 {
    if (!@hasField(@TypeOf(meta), category)) return null;

    const category_meta = @field(meta, category);
    if (!@hasField(@TypeOf(category_meta), field_name)) return null;

    const field_meta = @field(category_meta, field_name);
    const field_type = @TypeOf(field_meta);

    // For backward compatibility, support both string descriptions and struct metadata
    // Check if it's a string type (slice of const u8)
    const type_info = @typeInfo(field_type);
    if (type_info == .pointer and type_info.pointer.size == .slice and type_info.pointer.child == u8) {
        return field_meta;
    }

    // Check if it's a struct with a desc field
    if (type_info == .@"struct") {
        if (@hasField(field_type, "desc")) {
            return field_meta.desc;
        }
    }

    return null;
}

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
        try generateArgsHelp(command_module.Args, meta, writer);
    }

    // Options section
    if (@hasDecl(command_module, "Options")) {
        try generateOptionsHelp(command_module.Options, meta, writer);
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

        if (isVarArgs(field.type)) {
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

fn generateArgsHelp(comptime args_type: type, comptime meta: anytype, writer: anytype) !void {
    const type_info = @typeInfo(args_type);
    if (type_info != .@"struct") return;

    if (type_info.@"struct".fields.len == 0) return;

    try writer.print("ARGS:\n", .{});

    inline for (type_info.@"struct".fields) |field| {
        try writer.print("    ", .{});

        if (isVarArgs(field.type)) {
            try writer.print("[{s}...]    ", .{field.name});
        } else if (@typeInfo(field.type) == .optional) {
            try writer.print("[{s}]        ", .{field.name});
        } else {
            try writer.print("<{s}>        ", .{field.name});
        }

        // Use metadata description if available, otherwise show type
        const description = getFieldDescription(meta, field.name, "args");
        if (description) |desc| {
            try writer.print("{s}\n", .{desc});
        } else {
            try writer.print("(type: {s})\n", .{@typeName(field.type)});
        }
    }

    try writer.print("\n", .{});
}

fn generateOptionsHelp(comptime options_type: type, comptime meta: anytype, writer: anytype) !void {
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

        // Use metadata description if available, otherwise show default/type info
        const description = getFieldDescription(meta, field.name, "options");
        if (description) |desc| {
            try writer.print("    {s}", .{desc});

            // Still show default/optional info after description
            if (field.type == bool) {
                try writer.print(" (default: false)", .{});
            } else if (@typeInfo(field.type) == .optional) {
                try writer.print(" (optional)", .{});
            }
        } else {
            // Fallback to original behavior
            if (field.type == bool) {
                try writer.print("    (default: false)", .{});
            } else if (@typeInfo(field.type) == .optional) {
                try writer.print("    (optional)", .{});
            }
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

/// Helper function to check if a type represents varargs
fn isVarArgs(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info == .pointer and
        type_info.pointer.size == .slice and
        @typeInfo(type_info.pointer.child) == .pointer and
        @typeInfo(type_info.pointer.child).pointer.size == .slice and
        @typeInfo(type_info.pointer.child).pointer.child == u8;
}
