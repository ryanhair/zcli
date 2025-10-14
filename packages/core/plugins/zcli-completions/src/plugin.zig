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
                var stdout = context.stdout();
                var stderr = context.stderr();

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
                var stdout = context.stdout();
                var stderr = context.stderr();

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
                var stdout = context.stdout();
                var stderr = context.stderr();

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
    var stdout = context.stdout();

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
    var stdout = context.stdout();

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
