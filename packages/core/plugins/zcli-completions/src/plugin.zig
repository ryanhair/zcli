const std = @import("std");
const zcli = @import("zcli");

const bash = @import("bash.zig");
const zsh = @import("zsh.zig");
const fish = @import("fish.zig");

pub const commands = struct {
    pub const completions = struct {
        pub const meta = .{
            .description = "Manage shell completions for bash, zsh, and fish",
        };

        // This is a metadata-only group (no execute, no Args, no Options)
        // When called without subcommand, it will trigger CommandNotFound
        // which the help plugin will handle by showing subcommands

        pub const generate = struct {
            pub const meta = .{
                .description = "Generate shell completion script to stdout",
                .examples = &.{
                    "completions generate         # Auto-detect shell from $SHELL",
                    "completions generate bash > completions.bash",
                    "completions generate zsh > _myapp",
                    "completions generate fish > myapp.fish",
                },
            };

            pub const Args = struct {
                shell: ?[]const u8 = null,
            };

            pub const Options = struct {};

            pub fn execute(args: Args, _: Options, context: *zcli.Context) !void {
                const allocator = context.allocator;
                const stdout = context.stdout();
                const stderr = context.stderr();

                // Determine shell type (from arg or auto-detect)
                const shell_type = if (args.shell) |shell_arg|
                    getShellType(shell_arg) orelse {
                        try stderr.print("Error: unsupported shell '{s}'\n", .{shell_arg});
                        try stderr.print("Supported shells: bash, zsh, fish\n", .{});
                        return error.UnsupportedShell;
                    }
                else
                    detectShell() orelse {
                        try stderr.print("Error: could not detect shell from $SHELL environment variable\n", .{});
                        try stderr.print("Please specify shell explicitly: completions generate <bash|zsh|fish>\n", .{});
                        return error.ShellNotDetected;
                    };

                // Get command information
                const commands_info = context.getAvailableCommandInfo();
                const global_options = context.getGlobalOptions();

                // Generate completion script
                const script = switch (shell_type) {
                    .bash => try bash.generate(allocator, context.app_name, commands_info, global_options),
                    .zsh => try zsh.generate(allocator, context.app_name, commands_info, global_options),
                    .fish => try fish.generate(allocator, context.app_name, commands_info, global_options),
                };
                defer allocator.free(script);

                try stdout.print("{s}", .{script});
            }
        };

        pub const install = struct {
            pub const meta = .{
                .description = "Install shell completions for the current user",
                .examples = &.{
                    "completions install          # Auto-detect shell from $SHELL",
                    "completions install bash",
                    "completions install zsh",
                    "completions install fish",
                },
            };

            pub const Args = struct {
                shell: ?[]const u8 = null,
            };

            pub const Options = struct {};

            pub fn execute(args: Args, _: Options, context: *zcli.Context) !void {
                const allocator = context.allocator;
                const stdout = context.stdout();
                const stderr = context.stderr();

                // Determine shell type (from arg or auto-detect)
                const shell_type = if (args.shell) |shell_arg|
                    getShellType(shell_arg) orelse {
                        try stderr.print("Error: unsupported shell '{s}'\n", .{shell_arg});
                        try stderr.print("Supported shells: bash, zsh, fish\n", .{});
                        return error.UnsupportedShell;
                    }
                else
                    detectShell() orelse {
                        try stderr.print("Error: could not detect shell from $SHELL environment variable\n", .{});
                        try stderr.print("Please specify shell explicitly: completions install <bash|zsh|fish>\n", .{});
                        return error.ShellNotDetected;
                    };

                // Get command information
                const commands_info = context.getAvailableCommandInfo();
                const global_options = context.getGlobalOptions();

                // Generate completion script
                const script = switch (shell_type) {
                    .bash => try bash.generate(allocator, context.app_name, commands_info, global_options),
                    .zsh => try zsh.generate(allocator, context.app_name, commands_info, global_options),
                    .fish => try fish.generate(allocator, context.app_name, commands_info, global_options),
                };
                defer allocator.free(script);

                // Determine installation path
                const install_path = try getInstallPath(allocator, shell_type, context.app_name);
                defer allocator.free(install_path);

                // Create parent directory if it doesn't exist
                const dir_path = std.fs.path.dirname(install_path) orelse {
                    try stderr.print("Error: invalid install path '{s}'\n", .{install_path});
                    return error.InvalidPath;
                };

                std.fs.cwd().makePath(dir_path) catch |err| {
                    try stderr.print("Error: failed to create directory '{s}': {}\n", .{ dir_path, err });
                    return err;
                };

                // Write completion script
                const file = std.fs.cwd().createFile(install_path, .{}) catch |err| {
                    try stderr.print("Error: failed to write to '{s}': {}\n", .{ install_path, err });
                    return err;
                };
                defer file.close();

                try file.writeAll(script);

                const shell_name = switch (shell_type) {
                    .bash => "bash",
                    .zsh => "zsh",
                    .fish => "fish",
                };

                try stdout.print("✓ Installed {s} completions to {s}\n\n", .{ shell_name, install_path });

                // Always print manual instructions
                try printEnableInstructions(shell_type, context);
            }
        };

        pub const uninstall = struct {
            pub const meta = .{
                .description = "Uninstall shell completions",
                .examples = &.{
                    "completions uninstall        # Auto-detect shell from $SHELL",
                    "completions uninstall bash",
                    "completions uninstall zsh",
                    "completions uninstall fish",
                },
            };

            pub const Args = struct {
                shell: ?[]const u8 = null,
            };

            pub const Options = struct {};

            pub fn execute(args: Args, _: Options, context: *zcli.Context) !void {
                const allocator = context.allocator;
                const stdout = context.stdout();
                const stderr = context.stderr();

                // Determine shell type (from arg or auto-detect)
                const shell_type = if (args.shell) |shell_arg|
                    getShellType(shell_arg) orelse {
                        try stderr.print("Error: unsupported shell '{s}'\n", .{shell_arg});
                        try stderr.print("Supported shells: bash, zsh, fish\n", .{});
                        return error.UnsupportedShell;
                    }
                else
                    detectShell() orelse {
                        try stderr.print("Error: could not detect shell from $SHELL environment variable\n", .{});
                        try stderr.print("Please specify shell explicitly: completions uninstall <bash|zsh|fish>\n", .{});
                        return error.ShellNotDetected;
                    };

                // Determine installation path
                const install_path = try getInstallPath(allocator, shell_type, context.app_name);
                defer allocator.free(install_path);

                // Remove completion script
                std.fs.cwd().deleteFile(install_path) catch |err| {
                    if (err == error.FileNotFound) {
                        try stdout.print("Completions not installed at {s}\n", .{install_path});
                        return;
                    } else {
                        try stderr.print("Error: failed to remove '{s}': {}\n", .{ install_path, err });
                        return err;
                    }
                };

                const shell_name = switch (shell_type) {
                    .bash => "bash",
                    .zsh => "zsh",
                    .fish => "fish",
                };

                try stdout.print("✓ Uninstalled {s} completions from {s}\n\n", .{ shell_name, install_path });
                try printDisableInstructions(shell_type, context);
            }
        };
    };
};

const ShellType = enum {
    bash,
    zsh,
    fish,
};

fn getShellType(shell: []const u8) ?ShellType {
    if (std.mem.eql(u8, shell, "bash")) return .bash;
    if (std.mem.eql(u8, shell, "zsh")) return .zsh;
    if (std.mem.eql(u8, shell, "fish")) return .fish;
    return null;
}

fn detectShell() ?ShellType {
    const shell_path = std.posix.getenv("SHELL") orelse return null;

    // Extract shell name from path (e.g., "/bin/bash" -> "bash")
    const shell_name = std.fs.path.basename(shell_path);

    return getShellType(shell_name);
}

fn promptUserForConfigure(shell_type: ShellType, context: *zcli.Context) !bool {
    const stdout = context.stdout();
    const stdin = std.io.getStdIn().reader();

    const shell_name = switch (shell_type) {
        .bash => "bash",
        .zsh => "zsh",
        .fish => "fish",
    };

    try stdout.print("Would you like to automatically configure your shell (~/.{s}rc)? [Y/n]: ", .{shell_name});

    var buf: [10]u8 = undefined;
    const response = (try stdin.readUntilDelimiterOrEof(&buf, '\n')) orelse return false;

    // Trim whitespace
    const trimmed = std.mem.trim(u8, response, " \t\r\n");

    // Default to yes if empty or starts with 'y' or 'Y'
    if (trimmed.len == 0) return true;
    if (trimmed[0] == 'y' or trimmed[0] == 'Y') return true;

    return false;
}

fn getShellConfigPath(allocator: std.mem.Allocator, shell_type: ShellType) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;

    return switch (shell_type) {
        .bash => try std.fmt.allocPrint(allocator, "{s}/.bashrc", .{home}),
        .zsh => try std.fmt.allocPrint(allocator, "{s}/.zshrc", .{home}),
        .fish => try std.fmt.allocPrint(allocator, "{s}/.config/fish/config.fish", .{home}),
    };
}

fn isAlreadyConfigured(config_content: []const u8, app_name: []const u8) bool {
    const marker_start = std.fmt.allocPrint(std.heap.page_allocator, "# >>> {s} completion setup >>>", .{app_name}) catch return false;
    defer std.heap.page_allocator.free(marker_start);

    return std.mem.indexOf(u8, config_content, marker_start) != null;
}

fn configureShell(shell_type: ShellType, context: *zcli.Context) !void {
    const allocator = context.allocator;

    const config_path = try getShellConfigPath(allocator, shell_type);
    defer allocator.free(config_path);

    // Read existing config or create empty
    const existing_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| blk: {
        if (err == error.FileNotFound) {
            // Create parent directory if needed
            if (std.fs.path.dirname(config_path)) |dir| {
                try std.fs.cwd().makePath(dir);
            }
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(existing_content);

    // Check if already configured
    if (isAlreadyConfigured(existing_content, context.app_name)) {
        return; // Already configured, nothing to do
    }

    // Build configuration block
    const config_block = switch (shell_type) {
        .bash => try std.fmt.allocPrint(
            allocator,
            \\
            \\# >>> {s} completion setup >>>
            \\if [ -f ~/.local/share/bash-completion/completions/{s} ]; then
            \\    . ~/.local/share/bash-completion/completions/{s}
            \\fi
            \\# <<< {s} completion setup <<<
            \\
        ,
            .{ context.app_name, context.app_name, context.app_name, context.app_name },
        ),
        .zsh => try std.fmt.allocPrint(
            allocator,
            \\
            \\# >>> {s} completion setup >>>
            \\fpath=(~/.zsh/completions $fpath)
            \\autoload -Uz compinit && compinit
            \\# <<< {s} completion setup <<<
            \\
        ,
            .{ context.app_name, context.app_name },
        ),
        .fish => try std.fmt.allocPrint(
            allocator,
            \\
            \\# >>> {s} completion setup >>>
            \\# Fish completions are automatically loaded from ~/.config/fish/completions/
            \\# <<< {s} completion setup <<<
            \\
        ,
            .{ context.app_name, context.app_name },
        ),
    };
    defer allocator.free(config_block);

    // Append to config file
    const file = try std.fs.cwd().openFile(config_path, .{ .mode = .read_write });
    defer file.close();

    try file.seekFromEnd(0);
    try file.writeAll(config_block);
}

fn promptUserForUnconfigure(shell_type: ShellType, context: *zcli.Context) !bool {
    const stdout = context.stdout();
    const stdin = std.io.getStdIn().reader();

    const shell_name = switch (shell_type) {
        .bash => "bash",
        .zsh => "zsh",
        .fish => "fish",
    };

    try stdout.print("Would you like to remove shell configuration from ~/.{s}rc? [y/N]: ", .{shell_name});

    var buf: [10]u8 = undefined;
    const response = (try stdin.readUntilDelimiterOrEof(&buf, '\n')) orelse return false;

    // Trim whitespace
    const trimmed = std.mem.trim(u8, response, " \t\r\n");

    // Default to no if empty, yes if starts with 'y' or 'Y'
    if (trimmed.len == 0) return false;
    if (trimmed[0] == 'y' or trimmed[0] == 'Y') return true;

    return false;
}

fn unconfigureShell(shell_type: ShellType, context: *zcli.Context) !void {
    const allocator = context.allocator;

    const config_path = try getShellConfigPath(allocator, shell_type);
    defer allocator.free(config_path);

    // Read existing config
    const existing_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            return; // Config doesn't exist, nothing to do
        }
        return err;
    };
    defer allocator.free(existing_content);

    // Build markers
    const marker_start = try std.fmt.allocPrint(allocator, "# >>> {s} completion setup >>>", .{context.app_name});
    defer allocator.free(marker_start);
    const marker_end = try std.fmt.allocPrint(allocator, "# <<< {s} completion setup <<<", .{context.app_name});
    defer allocator.free(marker_end);

    // Find the configuration block
    const start_idx = std.mem.indexOf(u8, existing_content, marker_start) orelse {
        return; // Not configured, nothing to do
    };

    const end_idx = std.mem.indexOf(u8, existing_content, marker_end) orelse {
        return error.InvalidConfigurationBlock;
    };

    // Calculate the end position (include the end marker line and trailing newline if present)
    var block_end = end_idx + marker_end.len;
    if (block_end < existing_content.len and existing_content[block_end] == '\n') {
        block_end += 1;
    }

    // Build new content without the configuration block
    const new_content = try std.mem.concat(allocator, u8, &.{
        existing_content[0..start_idx],
        existing_content[block_end..],
    });
    defer allocator.free(new_content);

    // Write the new content
    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll(new_content);
}

fn getInstallPath(allocator: std.mem.Allocator, shell_type: ShellType, app_name: []const u8) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;

    return switch (shell_type) {
        .bash => try std.fmt.allocPrint(
            allocator,
            "{s}/.local/share/bash-completion/completions/{s}",
            .{ home, app_name },
        ),
        .zsh => try std.fmt.allocPrint(
            allocator,
            "{s}/.zsh/completions/_{s}",
            .{ home, app_name },
        ),
        .fish => try std.fmt.allocPrint(
            allocator,
            "{s}/.config/fish/completions/{s}.fish",
            .{ home, app_name },
        ),
    };
}

fn printEnableInstructions(shell_type: ShellType, context: *zcli.Context) !void {
    const stdout = context.stdout();

    switch (shell_type) {
        .bash => {
            try stdout.writeAll("To enable completions, add the following to your ~/.bashrc:\n\n");
            try stdout.writeAll("  if [ -f ~/.local/share/bash-completion/completions/");
            try stdout.print("{s}", .{context.app_name});
            try stdout.writeAll(" ]; then\n");
            try stdout.writeAll("    . ~/.local/share/bash-completion/completions/");
            try stdout.print("{s}", .{context.app_name});
            try stdout.writeAll("\n  fi\n\n");
            try stdout.writeAll("Then clear the completion cache and reload your shell:\n");
            try stdout.writeAll("  rm -f ~/.bash_completion.d/cache\n");
            try stdout.writeAll("  exec bash\n");
        },
        .zsh => {
            try stdout.writeAll("To enable completions, add the following to your ~/.zshrc:\n\n");
            try stdout.writeAll("  fpath=(~/.zsh/completions $fpath)\n\n");
            try stdout.writeAll("NOTE: If you use oh-my-zsh or another framework, add this BEFORE\n");
            try stdout.writeAll("      sourcing the framework (which calls compinit automatically).\n");
            try stdout.writeAll("      If you use plain zsh, also add: autoload -Uz compinit && compinit\n\n");
            try stdout.writeAll("Then clear the completion cache and reload your shell:\n");
            try stdout.writeAll("  rm -f ~/.zcompdump*\n");
            try stdout.writeAll("  exec zsh\n");
        },
        .fish => {
            try stdout.writeAll("Fish completions are automatically loaded from ~/.config/fish/completions/\n");
            try stdout.writeAll("No additional configuration needed! Just start a new shell:\n");
            try stdout.writeAll("  exec fish\n");
        },
    }
}

fn printDisableInstructions(shell_type: ShellType, context: *zcli.Context) !void {
    const stdout = context.stdout();

    switch (shell_type) {
        .bash => {
            try stdout.writeAll("To complete removal, remove these lines from your ~/.bashrc:\n\n");
            try stdout.writeAll("  if [ -f ~/.local/share/bash-completion/completions/");
            try stdout.print("{s}", .{context.app_name});
            try stdout.writeAll(" ]; then\n");
            try stdout.writeAll("    . ~/.local/share/bash-completion/completions/");
            try stdout.print("{s}", .{context.app_name});
            try stdout.writeAll("\n  fi\n\n");
            try stdout.writeAll("Then reload your shell:\n");
            try stdout.writeAll("  exec bash\n");
        },
        .zsh => {
            try stdout.writeAll("To complete removal, remove this line from your ~/.zshrc:\n\n");
            try stdout.writeAll("  fpath=(~/.zsh/completions $fpath)\n\n");
            try stdout.writeAll("Or remove just this completion directory if others exist.\n\n");
            try stdout.writeAll("Then reload your shell:\n");
            try stdout.writeAll("  exec zsh\n");
        },
        .fish => {
            try stdout.writeAll("Completions fully removed. No configuration cleanup needed.\n");
            try stdout.writeAll("Just start a new shell:\n");
            try stdout.writeAll("  exec fish\n");
        },
    }
}
