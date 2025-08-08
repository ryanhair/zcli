const std = @import("std");

// ============================================================================
// BUILD UTILITIES - For use in build.zig only
// These functions are not part of the public API for end users
// ============================================================================

// Command discovery structures
const CommandInfo = struct {
    name: []const u8,
    path: []const u8,
    is_group: bool,
    children: std.StringHashMap(CommandInfo),
    allocator: std.mem.Allocator,

    fn deinit(self: *CommandInfo) void {
        var it = self.children.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.children.deinit();
        self.allocator.free(self.name);
        self.allocator.free(self.path);
    }
};

const DiscoveredCommands = struct {
    allocator: std.mem.Allocator,
    root: std.StringHashMap(CommandInfo),

    fn deinit(self: *const DiscoveredCommands) void {
        var it = self.root.iterator();
        while (it.next()) |entry| {
            // Can't call deinit on const, but the build allocator will clean up
            _ = entry;
        }
        // Don't deinit the hashmap since we can't modify const
    }
};

// Command discovery and registry generation - the main public API
pub fn generateCommandRegistry(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zcli_module: *std.Build.Module, options: struct {
    commands_dir: []const u8,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
}) *std.Build.Module {
    _ = target; // Currently unused but may be needed later
    _ = optimize; // Currently unused but may be needed later

    // Discover all commands at build time
    const discovered_commands = discoverCommands(b.allocator, options.commands_dir) catch |err| {
        // Provide detailed error messages for common issues
        switch (err) {
            error.InvalidPath => {
                std.log.err("\n" ++
                    "=== Command Discovery Error ===\n" ++
                    "Invalid commands directory path: '{s}'\n" ++
                    "Path contains '..' which is not allowed for security reasons.\n" ++
                    "\n" ++
                    "Please use a relative path without '..' or an absolute path.\n" ++
                    "===========================\n", .{options.commands_dir});
            },
            error.FileNotFound => {
                std.log.err("\n" ++
                    "=== Command Discovery Error ===\n" ++
                    "Commands directory not found: '{s}'\n" ++
                    "\n" ++
                    "Please ensure the directory exists and the path is correct.\n" ++
                    "Expected location: {s}/{s}\n" ++
                    "===========================\n", .{ options.commands_dir, b.build_root.path orelse ".", options.commands_dir });
            },
            error.AccessDenied => {
                std.log.err("\n" ++
                    "=== Command Discovery Error ===\n" ++
                    "Access denied to commands directory: '{s}'\n" ++
                    "\n" ++
                    "Please check file permissions for the directory.\n" ++
                    "===========================\n", .{options.commands_dir});
            },
            error.OutOfMemory => {
                std.log.err("\n" ++
                    "=== Build Error ===\n" ++
                    "Out of memory during command discovery.\n" ++
                    "\n" ++
                    "Try reducing the number of commands or increasing available memory.\n" ++
                    "==================\n", .{});
            },
            else => {
                std.log.err("\n" ++
                    "=== Command Discovery Error ===\n" ++
                    "Failed to discover commands in '{s}'\n" ++
                    "Error: {any}\n" ++
                    "===========================\n", .{ options.commands_dir, err });
            },
        }
        // Use a generic panic message since we've already logged details
        @panic("Command discovery failed. See error message above for details.");
    };
    defer discovered_commands.deinit();

    // Generate registry source code
    const registry_source = generateRegistrySource(b.allocator, discovered_commands, options) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                std.log.err("\n" ++
                    "=== Build Error ===\n" ++
                    "Out of memory while generating command registry.\n" ++
                    "\n" ++
                    "The command structure may be too large. Try:\n" ++
                    "- Reducing the number of commands\n" ++
                    "- Simplifying command metadata\n" ++
                    "- Increasing available memory\n" ++
                    "==================\n", .{});
            },
            else => {
                std.log.err("\n" ++
                    "=== Registry Generation Error ===\n" ++
                    "Failed to generate command registry source code.\n" ++
                    "Error: {any}\n" ++
                    "==============================\n", .{err});
            },
        }
        @panic("Registry generation failed. See error message above for details.");
    };
    defer b.allocator.free(registry_source);

    // Create a write file step to write the generated source
    const write_registry = b.addWriteFiles();
    const registry_file = write_registry.add("command_registry.zig", registry_source);

    // Create module from the generated file
    const registry_module = b.addModule("command_registry", .{
        .root_source_file = registry_file,
    });

    // Add zcli import to registry module
    registry_module.addImport("zcli", zcli_module);

    // Create modules for all discovered command files dynamically
    createDiscoveredModules(b, registry_module, zcli_module, discovered_commands);

    return registry_module;
}

// Build-time command discovery - scans filesystem directly
fn discoverCommands(allocator: std.mem.Allocator, commands_dir: []const u8) !DiscoveredCommands {
    var commands = DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(CommandInfo).init(allocator),
    };

    // Validate commands directory path
    if (std.mem.indexOf(u8, commands_dir, "..") != null) {
        return error.InvalidPath;
    }

    // Open the commands directory
    var dir = std.fs.cwd().openDir(commands_dir, .{ .iterate = true }) catch |err| {
        return err;
    };
    defer dir.close();

    const max_depth = 6; // Reasonable maximum nesting depth
    try scanDirectory(allocator, dir, &commands.root, commands_dir, 0, max_depth);
    return commands;
}

fn scanDirectory(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    commands: *std.StringHashMap(CommandInfo),
    base_path: []const u8,
    depth: u32,
    max_depth: u32,
) !void {
    // Prevent excessive nesting
    if (depth >= max_depth) {
        std.log.warn("Maximum command nesting depth ({}) reached at path: {s}", .{ max_depth, base_path });
        return;
    }

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        // Validate entry name
        if (!isValidCommandName(entry.name)) {
            std.log.warn("Skipping invalid command/directory name: {s} (contains invalid characters)", .{entry.name});
            continue;
        }

        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    // Remove .zig extension for command name
                    const name_without_ext = entry.name[0 .. entry.name.len - 4];

                    // Validate command name
                    if (!isValidCommandName(name_without_ext)) {
                        std.log.warn("Skipping invalid command name: {s} (contains invalid characters)", .{name_without_ext});
                        continue;
                    }

                    const command_name = try allocator.dupe(u8, name_without_ext);
                    const command_path = try std.fs.path.join(allocator, &.{ base_path, entry.name });

                    const command_info = CommandInfo{
                        .name = command_name,
                        .path = command_path,
                        .is_group = false,
                        .children = std.StringHashMap(CommandInfo).init(allocator),
                        .allocator = allocator,
                    };

                    try commands.put(command_name, command_info);
                }
            },
            .directory => {
                // Skip hidden directories
                if (entry.name[0] == '.') {
                    continue;
                }

                // This is a command group - check if it has an index.zig
                var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer subdir.close();

                const group_name = try allocator.dupe(u8, entry.name);
                const group_base_path = try std.fs.path.join(allocator, &.{ base_path, entry.name });

                var group_info = CommandInfo{
                    .name = group_name,
                    .path = group_base_path,
                    .is_group = true,
                    .children = std.StringHashMap(CommandInfo).init(allocator),
                    .allocator = allocator,
                };

                // Scan the subdirectory for subcommands
                try scanDirectory(allocator, subdir, &group_info.children, group_base_path, depth + 1, max_depth);

                // Only add the group if it has children or an index.zig
                if (group_info.children.count() > 0 or hasIndexFile(subdir)) {
                    try commands.put(group_name, group_info);
                }
            },
            else => continue,
        }
    }
}

fn hasIndexFile(dir: std.fs.Dir) bool {
    dir.access("index.zig", .{}) catch return false;
    return true;
}

/// Validate command/directory names for security
pub fn isValidCommandName(name: []const u8) bool {
    // Reject empty names
    if (name.len == 0) return false;

    // Reject names with path traversal attempts
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, "/") != null) return false;
    if (std.mem.indexOf(u8, name, "\\") != null) return false;

    // Reject names starting with dot (hidden files)
    if (name[0] == '.') return false;

    // Allow only alphanumeric, dash, and underscore
    for (name) |c| {
        const is_valid = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => true,
            else => false,
        };
        if (!is_valid) return false;
    }

    return true;
}

// Generate registry source code at build time
fn generateRegistrySource(allocator: std.mem.Allocator, commands: DiscoveredCommands, options: anytype) ![]u8 {
    var source = std.ArrayList(u8).init(allocator);
    defer source.deinit();

    const writer = source.writer();

    // Header
    try writer.print(
        \\// Generated by zcli - DO NOT EDIT
        \\
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\
        \\pub const app_name = "{s}";
        \\pub const app_version = "{s}";
        \\pub const app_description = "{s}";
        \\
    , .{ options.app_name, options.app_version, options.app_description });

    // Helper function for array cleanup
    try writer.writeAll(
        \\// Helper function to clean up array fields in options
        \\// This function automatically frees memory allocated for array options (e.g., [][]const u8, []i32, etc.)
        \\// Individual string elements are not freed as they come from command-line args
        \\fn cleanupArrayOptions(comptime OptionsType: type, options: OptionsType, allocator: std.mem.Allocator) void {
        \\    const type_info = @typeInfo(OptionsType);
        \\    if (type_info != .@"struct") return;
        \\    
        \\    inline for (type_info.@"struct".fields) |field| {
        \\        const field_value = @field(options, field.name);
        \\        const field_type_info = @typeInfo(field.type);
        \\        
        \\        // Check if this is a slice type (array)
        \\        if (field_type_info == .pointer and 
        \\            field_type_info.pointer.size == .slice) {
        \\            // Free the slice itself - works for all array types:
        \\            // [][]const u8, []i32, []u32, []f64, etc.
        \\            // We don't free individual elements as they're either:
        \\            // - Strings from args (not owned)
        \\            // - Primitive values (no allocation)
        \\            allocator.free(field_value);
        \\        }
        \\    }
        \\}
        \\
        \\
    );

    // Generate execution functions for all commands
    try generateExecutionFunctions(writer, commands);

    // Generate the registry structure
    try writer.writeAll("pub const registry = .{\n    .commands = .{\n");
    try generateRegistryCommands(writer, commands);
    try writer.writeAll("    },\n};\n");

    return source.toOwnedSlice();
}

fn generateExecutionFunctions(writer: anytype, commands: DiscoveredCommands) !void {
    var it = commands.root.iterator();
    while (it.next()) |entry| {
        const cmd_name = entry.key_ptr.*;
        const cmd_info = entry.value_ptr;

        if (cmd_info.is_group) {
            // Generate execution functions for subcommands
            try generateGroupExecutionFunctions(writer, cmd_name, cmd_info, commands.allocator);
        } else {
            // Generate execution function for this command
            const module_name = if (std.mem.eql(u8, cmd_name, "root")) "cmd_root" else try std.fmt.allocPrint(commands.allocator, "cmd_{s}", .{cmd_name});
            defer if (!std.mem.eql(u8, cmd_name, "root")) commands.allocator.free(module_name);

            const func_name = if (std.mem.eql(u8, cmd_name, "root")) "executeRoot" else try std.fmt.allocPrint(commands.allocator, "execute{s}", .{cmd_name});
            defer if (!std.mem.eql(u8, cmd_name, "root")) commands.allocator.free(func_name);

            try generateSingleExecutionFunction(writer, func_name, module_name);
        }
    }
}

fn generateGroupExecutionFunctions(writer: anytype, group_name: []const u8, group_info: *const CommandInfo, allocator: std.mem.Allocator) !void {
    var it = group_info.children.iterator();
    while (it.next()) |entry| {
        const subcmd_name = entry.key_ptr.*;
        const subcmd_info = entry.value_ptr;

        if (subcmd_info.is_group) {
            // Nested group - recurse
            try generateGroupExecutionFunctions(writer, subcmd_name, subcmd_info, allocator);
        } else {
            // Generate execution function for this subcommand
            const module_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ group_name, subcmd_name });
            defer allocator.free(module_name);

            const func_name = try std.fmt.allocPrint(allocator, "execute{s}{s}", .{ group_name, subcmd_name });
            defer allocator.free(func_name);

            try generateSingleExecutionFunction(writer, func_name, module_name);
        }
    }
}

fn generateSingleExecutionFunction(writer: anytype, func_name: []const u8, module_name: []const u8) !void {
    try writer.print(
        \\fn {s}(args: []const []const u8, allocator: std.mem.Allocator, context: *zcli.Context) !void {{
        \\    const command = @import("{s}");
        \\    
        \\    // Parse options first if they exist
        \\    var remaining_args: []const []const u8 = args;
        \\    
        \\    const parsed_options = if (@hasDecl(command, "Options")) blk: {{
        \\        const command_meta = if (@hasDecl(command, "meta")) command.meta else null;
        \\        const options_result = try zcli.parseOptionsWithMeta(command.Options, command_meta, allocator, args);
        \\        remaining_args = args[options_result.result.next_arg_index..];
        \\        break :blk options_result.options;
        \\    }} else .{{}};
        \\    
        \\    // Setup cleanup for array fields in options
        \\    defer if (@hasDecl(command, "Options")) {{
        \\        cleanupArrayOptions(command.Options, parsed_options, allocator);
        \\    }};
        \\    
        \\    // Parse remaining arguments
        \\    const parsed_args = if (@hasDecl(command, "Args")) 
        \\        try zcli.parseArgs(command.Args, remaining_args)
        \\    else 
        \\        .{{}};
        \\    
        \\    // Execute the command
        \\    if (@hasDecl(command, "execute")) {{
        \\        try command.execute(parsed_args, parsed_options, context);
        \\    }} else {{
        \\        try context.stderr.print("Error: Command does not implement execute function\n", .{{}});
        \\    }}
        \\}}
    , .{ func_name, module_name });
}

fn generateRegistryCommands(writer: anytype, commands: DiscoveredCommands) !void {
    var it = commands.root.iterator();
    while (it.next()) |entry| {
        const cmd_name = entry.key_ptr.*;
        const cmd_info = entry.value_ptr;

        if (cmd_info.is_group) {
            try generateGroupRegistry(writer, cmd_name, cmd_info, commands.allocator);
        } else {
            const module_name = if (std.mem.eql(u8, cmd_name, "root")) "cmd_root" else try std.fmt.allocPrint(commands.allocator, "cmd_{s}", .{cmd_name});
            defer if (!std.mem.eql(u8, cmd_name, "root")) commands.allocator.free(module_name);

            const func_name = if (std.mem.eql(u8, cmd_name, "root")) "executeRoot" else try std.fmt.allocPrint(commands.allocator, "execute{s}", .{cmd_name});
            defer if (!std.mem.eql(u8, cmd_name, "root")) commands.allocator.free(func_name);

            if (std.mem.eql(u8, cmd_name, "test")) {
                try writer.print("        .@\"{s}\" = .{{ .module = @import(\"{s}\"), .execute = {s} }},\n", .{ cmd_name, module_name, func_name });
            } else {
                try writer.print("        .{s} = .{{ .module = @import(\"{s}\"), .execute = {s} }},\n", .{ cmd_name, module_name, func_name });
            }
        }
    }
}

fn generateGroupRegistry(writer: anytype, group_name: []const u8, group_info: *const CommandInfo, allocator: std.mem.Allocator) !void {
    try writer.print("        .{s} = .{{\n", .{group_name});
    try writer.writeAll("            ._is_group = true,\n");

    // Check for index command
    if (group_info.children.contains("index")) {
        const module_name = try std.fmt.allocPrint(allocator, "{s}_index", .{group_name});
        defer allocator.free(module_name);

        const func_name = try std.fmt.allocPrint(allocator, "execute{s}index", .{group_name});
        defer allocator.free(func_name);

        try writer.print("            ._index = .{{ .module = @import(\"{s}\"), .execute = {s} }},\n", .{ module_name, func_name });
    }

    // Add subcommands
    var it = group_info.children.iterator();
    while (it.next()) |entry| {
        const subcmd_name = entry.key_ptr.*;
        if (std.mem.eql(u8, subcmd_name, "index")) continue; // Skip index, already handled above

        const subcmd_info = entry.value_ptr;
        if (subcmd_info.is_group) {
            try generateGroupRegistry(writer, subcmd_name, subcmd_info, allocator);
        } else {
            const module_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ group_name, subcmd_name });
            defer allocator.free(module_name);

            const func_name = try std.fmt.allocPrint(allocator, "execute{s}{s}", .{ group_name, subcmd_name });
            defer allocator.free(func_name);

            try writer.print("            .{s} = .{{ .module = @import(\"{s}\"), .execute = {s} }},\n", .{ subcmd_name, module_name, func_name });
        }
    }

    try writer.writeAll("        },\n");
}

// Create modules for all discovered commands dynamically
fn createDiscoveredModules(b: *std.Build, registry_module: *std.Build.Module, zcli_module: *std.Build.Module, commands: DiscoveredCommands) void {
    var it = commands.root.iterator();
    while (it.next()) |entry| {
        const cmd_name = entry.key_ptr.*;
        const cmd_info = entry.value_ptr;

        if (cmd_info.is_group) {
            createGroupModules(b, registry_module, zcli_module, cmd_name, cmd_info);
        } else {
            const module_name = if (std.mem.eql(u8, cmd_name, "root")) "cmd_root" else b.fmt("cmd_{s}", .{cmd_name});
            const cmd_module = b.addModule(module_name, .{
                .root_source_file = b.path(cmd_info.path),
            });
            cmd_module.addImport("zcli", zcli_module);
            registry_module.addImport(module_name, cmd_module);
        }
    }
}

fn createGroupModules(b: *std.Build, registry_module: *std.Build.Module, zcli_module: *std.Build.Module, group_name: []const u8, group_info: *const CommandInfo) void {
    var it = group_info.children.iterator();
    while (it.next()) |entry| {
        const subcmd_name = entry.key_ptr.*;
        const subcmd_info = entry.value_ptr;

        if (subcmd_info.is_group) {
            createGroupModules(b, registry_module, zcli_module, subcmd_name, subcmd_info);
        } else {
            const module_name = b.fmt("{s}_{s}", .{ group_name, subcmd_name });
            const cmd_module = b.addModule(module_name, .{
                .root_source_file = b.path(subcmd_info.path),
            });
            cmd_module.addImport("zcli", zcli_module);
            registry_module.addImport(module_name, cmd_module);
        }
    }
}

// Tests

test "isValidCommandName security checks" {
    // Valid names
    try std.testing.expect(isValidCommandName("hello"));
    try std.testing.expect(isValidCommandName("hello-world"));
    try std.testing.expect(isValidCommandName("hello_world"));
    try std.testing.expect(isValidCommandName("hello123"));
    try std.testing.expect(isValidCommandName("UPPERCASE"));

    // Invalid names - path traversal
    try std.testing.expect(!isValidCommandName("../etc"));
    try std.testing.expect(!isValidCommandName(".."));
    try std.testing.expect(!isValidCommandName("hello/../world"));

    // Invalid names - path separators
    try std.testing.expect(!isValidCommandName("hello/world"));
    try std.testing.expect(!isValidCommandName("hello\\world"));

    // Invalid names - hidden files
    try std.testing.expect(!isValidCommandName(".hidden"));
    try std.testing.expect(!isValidCommandName("."));

    // Invalid names - special characters
    try std.testing.expect(!isValidCommandName("hello world"));
    try std.testing.expect(!isValidCommandName("hello@world"));
    try std.testing.expect(!isValidCommandName("hello$world"));
    try std.testing.expect(!isValidCommandName("hello;rm -rf"));

    // Invalid names - empty
    try std.testing.expect(!isValidCommandName(""));
}
