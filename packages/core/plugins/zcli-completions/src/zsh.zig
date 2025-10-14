const std = @import("std");
const zcli = @import("zcli");

/// Escape special characters in descriptions for zsh completion
fn escapeDescription(allocator: std.mem.Allocator, desc: []const u8) ![]const u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    for (desc) |c| {
        switch (c) {
            '(' => {
                try result.append(allocator, '\\');
                try result.append(allocator, '(');
            },
            ')' => {
                try result.append(allocator, '\\');
                try result.append(allocator, ')');
            },
            '[' => {
                try result.append(allocator, '\\');
                try result.append(allocator, '[');
            },
            ']' => {
                try result.append(allocator, '\\');
                try result.append(allocator, ']');
            },
            '\'' => {
                // For single quotes inside single-quoted strings, we need to:
                // end the string, add an escaped quote, and start a new string
                try result.appendSlice(allocator, "'\\''");
            },
            '\\' => {
                try result.append(allocator, '\\');
                try result.append(allocator, '\\');
            },
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Generate option completions for a specific command
fn generateOptionsForCommand(
    writer: anytype,
    allocator: std.mem.Allocator,
    commands: []const zcli.CommandInfo,
    command_path_str: []const u8,
    indent: []const u8,
) !void {
    // Find the command with this path
    var target_path = std.ArrayList([]const u8){};
    defer target_path.deinit(allocator);

    var path_iter = std.mem.splitScalar(u8, command_path_str, ' ');
    while (path_iter.next()) |part| {
        try target_path.append(allocator, part);
    }

    // Find matching command
    var found_options: ?[]const zcli.OptionInfo = null;
    for (commands) |cmd| {
        if (cmd.path.len != target_path.items.len) continue;

        var matches = true;
        for (cmd.path, target_path.items) |cmd_part, target_part| {
            if (!std.mem.eql(u8, cmd_part, target_part)) {
                matches = false;
                break;
            }
        }

        if (matches) {
            found_options = cmd.options;
            break;
        }
    }

    // Generate _arguments call with options
    if (found_options) |options| {
        if (options.len > 0) {
            // Set curcontext for this specific command
            var context_name = std.ArrayList(u8){};
            defer context_name.deinit(allocator);

            var context_iter = std.mem.splitScalar(u8, command_path_str, ' ');
            while (context_iter.next()) |part| {
                if (context_name.items.len > 0) try context_name.append(allocator, '-');
                try context_name.appendSlice(allocator, part);
            }

            try writer.print("{s}    curcontext=\"${{curcontext%:*:*}}:{s}:\"\n", .{ indent, context_name.items });
            try writer.print("{s}    _arguments -S \\\n", .{indent});

            for (options) |opt| {
                const escaped_desc = if (opt.description) |desc|
                    try escapeDescription(allocator, desc)
                else
                    null;
                defer if (escaped_desc) |e| allocator.free(e);

                if (opt.short) |short| {
                    // Short option: '-h[description]'
                    try writer.print("{s}        '-{c}", .{ indent, short });
                    if (escaped_desc) |desc| {
                        try writer.print("[{s}]", .{desc});
                    }
                    if (opt.takes_value) {
                        try writer.print(":{s}:", .{opt.name});
                    }
                    try writer.writeAll("' \\\n");

                    // Long option: '--help[description]'
                    try writer.print("{s}        '--{s}", .{ indent, opt.name });
                    if (escaped_desc) |desc| {
                        try writer.print("[{s}]", .{desc});
                    }
                    if (opt.takes_value) {
                        try writer.print(":{s}:", .{opt.name});
                    }
                    try writer.writeAll("' \\\n");
                } else {
                    // Long option only: '--help[description]'
                    try writer.print("{s}        '--{s}", .{ indent, opt.name });
                    if (escaped_desc) |desc| {
                        try writer.print("[{s}]", .{desc});
                    }
                    if (opt.takes_value) {
                        try writer.print(":{s}:", .{opt.name});
                    }
                    try writer.writeAll("' \\\n");
                }
            }

            // Add catch-all for remaining arguments
            try writer.print("{s}        '*::arg:_files'\n", .{indent});
        }
    }
}

/// Recursively generate nested case statements for subcommands
fn generateNestedCases(
    writer: anytype,
    allocator: std.mem.Allocator,
    command_tree: *const std.StringHashMap(std.ArrayList([]const u8)),
    commands: []const zcli.CommandInfo,
    current_path: []const u8,
    depth: usize,
) !void {
    // Check if this path has children
    if (command_tree.get(current_path)) |subcommands| {
        // Always use case statements when there are subcommands to properly handle leaf nodes
        if (subcommands.items.len > 0) {
            // Check if any subcommands have children (for determining if we need nested recursion)
            var has_nested_children = false;
            for (subcommands.items) |subcmd| {
                var child_path = std.ArrayList(u8){};
                defer child_path.deinit(allocator);
                try child_path.appendSlice(allocator, current_path);
                try child_path.append(allocator, ' ');
                try child_path.appendSlice(allocator, subcmd);

                if (command_tree.contains(child_path.items)) {
                    has_nested_children = true;
                    break;
                }
            }

            var indent_buf: [128]u8 = undefined;
            const actual_indent = try std.fmt.bufPrint(&indent_buf, "{s: <[1]}", .{ "", (depth - 1) * 4 });

            // Always create a case statement to handle subcommands
            try writer.print("{s}case $line[{d}] in\n", .{ actual_indent, depth });

            // Process ALL subcommands
            for (subcommands.items) |subcmd| {
                var child_path = std.ArrayList(u8){};
                defer child_path.deinit(allocator);
                try child_path.appendSlice(allocator, current_path);
                try child_path.append(allocator, ' ');
                try child_path.appendSlice(allocator, subcmd);

                try writer.print("{s}    {s})\n", .{ actual_indent, subcmd });

                if (command_tree.contains(child_path.items)) {
                    // This subcommand has children, recurse
                    try generateNestedCases(writer, allocator, command_tree, commands, child_path.items, depth + 1);
                } else {
                    // Leaf node - show options for this command
                    try generateOptionsForCommand(writer, allocator, commands, child_path.items, actual_indent);
                }

                try writer.print("{s}        ;;\n", .{actual_indent});
            }

            // Default case: show current level completions when not in a nested branch
            try writer.print("{s}    *)\n", .{actual_indent});

            // Show completions at the current level (in default case)
            try writer.print("{s}        local -a subcommands\n", .{actual_indent});
            try writer.print("{s}        subcommands=(\n", .{actual_indent});

            for (subcommands.items) |subcmd_name| {
                // Find description
                var desc: ?[]const u8 = null;
                for (commands) |cmd| {
                    if (cmd.path.len < 2) continue;
                    // Check if path matches
                    var matches = true;
                    var path_check = std.mem.splitScalar(u8, current_path, ' ');
                    var check_depth: usize = 0;
                    while (path_check.next()) |part| {
                        if (check_depth >= cmd.path.len or !std.mem.eql(u8, cmd.path[check_depth], part)) {
                            matches = false;
                            break;
                        }
                        check_depth += 1;
                    }
                    if (matches and check_depth < cmd.path.len and std.mem.eql(u8, cmd.path[check_depth], subcmd_name)) {
                        desc = cmd.description;
                        break;
                    }
                }

                try writer.print("{s}            '{s}", .{ actual_indent, subcmd_name });
                if (desc) |d| {
                    const escaped = try escapeDescription(allocator, d);
                    defer allocator.free(escaped);
                    try writer.print(":{s}", .{escaped});
                }
                try writer.writeAll("'\n");
            }

            try writer.print("{s}        )\n", .{actual_indent});
            try writer.print("{s}        _describe 'subcommand' subcommands\n", .{actual_indent});

            // Close the default case and case statement
            try writer.print("{s}        ;;\n", .{actual_indent});
            try writer.print("{s}esac\n", .{actual_indent});
        }
    }
}

/// Generate zsh completion script for the given app
pub fn generate(
    allocator: std.mem.Allocator,
    app_name: []const u8,
    commands: []const zcli.CommandInfo,
    global_options: []const zcli.OptionInfo,
) ![]const u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // Header
    try writer.print("#compdef {s}\n", .{app_name});
    try writer.writeAll("# zsh completion for ");
    try writer.print("{s}\n", .{app_name});
    try writer.writeAll("# Generated by zcli-completions plugin\n\n");

    // Main completion function
    try writer.print("_{s}() {{\n", .{app_name});
    try writer.writeAll("    local curcontext=\"$curcontext\" line state\n");
    try writer.print("    typeset -A opt_args\n\n", .{});

    // Build command tree structure
    var command_tree = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = command_tree.valueIterator();
        while (it.next()) |list| {
            list.deinit(allocator);
        }
        command_tree.deinit();
    }

    // Build tree of commands (parent -> children)
    // We need to create entries for ALL levels, not just the immediate parent
    for (commands) |cmd| {
        if (cmd.path.len == 1) {
            // Root level command
            const entry = try command_tree.getOrPut("");
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList([]const u8){};
            }
            try entry.value_ptr.append(allocator, cmd.path[0]);
        } else {
            // Nested command - create entries for each level
            for (1..cmd.path.len) |depth| {
                // Build parent path for this depth
                var parent_path = std.ArrayList(u8){};
                defer parent_path.deinit(allocator);
                for (cmd.path[0..depth], 0..) |part, idx| {
                    if (idx > 0) try parent_path.append(allocator, ' ');
                    try parent_path.appendSlice(allocator, part);
                }

                const parent_key = try allocator.dupe(u8, parent_path.items);
                const entry = try command_tree.getOrPut(parent_key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = std.ArrayList([]const u8){};
                } else {
                    allocator.free(parent_key);
                }

                // Add the child at this level (avoid duplicates)
                const child = cmd.path[depth];
                var already_exists = false;
                for (entry.value_ptr.items) |existing| {
                    if (std.mem.eql(u8, existing, child)) {
                        already_exists = true;
                        break;
                    }
                }
                if (!already_exists) {
                    try entry.value_ptr.append(allocator, child);
                }
            }
        }
    }

    // Generate _arguments call with global options
    try writer.writeAll("    _arguments -S -C \\\n");

    // Add global options
    for (global_options) |opt| {
        const escaped_desc = if (opt.description) |desc|
            try escapeDescription(allocator, desc)
        else
            null;
        defer if (escaped_desc) |e| allocator.free(e);

        if (opt.short) |short| {
            // Short option: '-h[description]'
            try writer.print("        '-{c}", .{short});
            if (escaped_desc) |desc| {
                try writer.print("[{s}]", .{desc});
            }
            if (opt.takes_value) {
                try writer.print(":{s}:", .{opt.name});
            }
            try writer.writeAll("' \\\n");

            // Long option: '--help[description]'
            try writer.print("        '--{s}", .{opt.name});
            if (escaped_desc) |desc| {
                try writer.print("[{s}]", .{desc});
            }
            if (opt.takes_value) {
                try writer.print(":{s}:", .{opt.name});
            }
            try writer.writeAll("' \\\n");
        } else {
            // Long option only: '--help[description]'
            try writer.print("        '--{s}", .{opt.name});
            if (escaped_desc) |desc| {
                try writer.print("[{s}]", .{desc});
            }
            if (opt.takes_value) {
                try writer.print(":{s}:", .{opt.name});
            }
            try writer.writeAll("' \\\n");
        }
    }

    // Add subcommand argument
    try writer.writeAll("        '1: :->command' \\\n");
    try writer.writeAll("        '*::arg:->args'\n\n");

    // Handle command state
    try writer.writeAll("    case $state in\n");
    try writer.writeAll("        command)\n");
    try writer.writeAll("            local -a commands\n");
    try writer.writeAll("            commands=(\n");

    // List root-level commands
    if (command_tree.get("")) |root_cmds| {
        for (root_cmds.items) |cmd_name| {
            // Find description for this command
            var desc: ?[]const u8 = null;
            for (commands) |cmd| {
                if (cmd.path.len == 1 and std.mem.eql(u8, cmd.path[0], cmd_name)) {
                    desc = cmd.description;
                    break;
                }
            }

            try writer.print("                '{s}", .{cmd_name});
            if (desc) |d| {
                const escaped = try escapeDescription(allocator, d);
                defer allocator.free(escaped);
                try writer.print(":{s}", .{escaped});
            }
            try writer.writeAll("'\n");
        }
    }

    try writer.writeAll("            )\n");
    try writer.writeAll("            _describe 'command' commands\n");
    try writer.writeAll("            ;;\n");

    // Handle args state - subcommands
    try writer.writeAll("        args)\n");
    try writer.writeAll("            case $line[1] in\n");

    // Generate cases for each first-level command that has subcommands
    // We need to build this recursively for proper nesting
    var processed = std.StringHashMap(void).init(allocator);
    defer processed.deinit();

    var tree_it = command_tree.iterator();
    while (tree_it.next()) |entry| {
        if (entry.key_ptr.len == 0) continue; // Skip root

        const parent_path = entry.key_ptr.*;

        // Only process first-level commands here
        if (std.mem.indexOfScalar(u8, parent_path, ' ') != null) continue;

        // Skip if already processed
        if (processed.contains(parent_path)) continue;
        try processed.put(parent_path, {});

        try writer.print("                {s})\n", .{parent_path});

        // Recursively generate nested cases
        try generateNestedCases(writer, allocator, &command_tree, commands, parent_path, 2);

        try writer.writeAll("                    ;;\n");
    }

    // Now handle root-level leaf commands (commands without subcommands)
    // These need option completions too
    if (command_tree.get("")) |root_cmds| {
        for (root_cmds.items) |cmd_name| {
            // Skip if this command has children (already processed above)
            if (command_tree.contains(cmd_name)) continue;

            // This is a leaf command at root level - generate options for it
            try writer.print("                {s})\n", .{cmd_name});
            try generateOptionsForCommand(writer, allocator, commands, cmd_name, "            ");
            try writer.writeAll("                    ;;\n");
        }
    }

    try writer.writeAll("            esac\n");
    try writer.writeAll("            ;;\n");
    try writer.writeAll("    esac\n");

    try writer.writeAll("}\n\n");

    // Call the function
    try writer.print("_{s} \"$@\"\n", .{app_name});

    return buf.toOwnedSlice(allocator);
}
