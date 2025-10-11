const std = @import("std");
const zcli = @import("zcli");

const bash = @import("bash.zig");
const zsh = @import("zsh.zig");
const fish = @import("fish.zig");

pub const commands = struct {
    pub const completions = struct {
        pub const meta = .{
            .description = "Manage shell completions for bash, zsh, and fish",
            .examples = &.{
                "completions generate bash",
                "completions install zsh",
                "completions uninstall fish",
            },
        };

        pub const Args = struct {
            action: []const u8,
            shell: []const u8,
        };

        pub const Options = struct {};

        pub fn execute(args: Args, _: Options, context: *zcli.Context) !void {
            const allocator = context.allocator;
            const stderr = context.stderr();

            // Validate shell
            const shell_type = getShellType(args.shell) orelse {
                try stderr.print("Error: unsupported shell '{s}'\n", .{args.shell});
                try stderr.print("Supported shells: bash, zsh, fish\n", .{});
                return error.UnsupportedShell;
            };

            // Route to appropriate action
            if (std.mem.eql(u8, args.action, "generate")) {
                return generateAction(allocator, context, shell_type);
            } else if (std.mem.eql(u8, args.action, "install")) {
                return installAction(allocator, context, shell_type);
            } else if (std.mem.eql(u8, args.action, "uninstall")) {
                return uninstallAction(allocator, context, shell_type);
            } else {
                try stderr.print("Error: unknown action '{s}'\n", .{args.action});
                try stderr.print("Valid actions: generate, install, uninstall\n", .{});
                return error.UnknownAction;
            }
        }
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

fn generateAction(allocator: std.mem.Allocator, context: *zcli.Context, shell_type: ShellType) !void {
    const stdout = context.stdout();

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

fn installAction(allocator: std.mem.Allocator, context: *zcli.Context, shell_type: ShellType) !void {
    const stdout = context.stdout();
    const stderr = context.stderr();

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

    // Print instructions for enabling completions
    try printEnableInstructions(shell_type, context);
}

fn uninstallAction(allocator: std.mem.Allocator, context: *zcli.Context, shell_type: ShellType) !void {
    const stdout = context.stdout();
    const stderr = context.stderr();

    // Determine installation path
    const install_path = try getInstallPath(allocator, shell_type, context.app_name);
    defer allocator.free(install_path);

    // Remove completion script
    std.fs.cwd().deleteFile(install_path) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print("Completions not installed at {s}\n", .{install_path});
            return;
        }
        try stderr.print("Error: failed to remove '{s}': {}\n", .{ install_path, err });
        return err;
    };

    const shell_name = switch (shell_type) {
        .bash => "bash",
        .zsh => "zsh",
        .fish => "fish",
    };

    try stdout.print("✓ Uninstalled {s} completions from {s}\n", .{ shell_name, install_path });
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
            try stdout.writeAll("To enable completions, ensure the following is in your ~/.bashrc:\n\n");
            try stdout.writeAll("  if [ -f ~/.local/share/bash-completion/completions/");
            try stdout.print("{s}", .{context.app_name});
            try stdout.writeAll(" ]; then\n");
            try stdout.writeAll("    . ~/.local/share/bash-completion/completions/");
            try stdout.print("{s}", .{context.app_name});
            try stdout.writeAll("\n  fi\n\n");
            try stdout.writeAll("Then reload your shell:\n");
            try stdout.writeAll("  source ~/.bashrc\n");
        },
        .zsh => {
            try stdout.writeAll("To enable completions, ensure the following is in your ~/.zshrc:\n\n");
            try stdout.writeAll("  fpath=(~/.zsh/completions $fpath)\n");
            try stdout.writeAll("  autoload -Uz compinit && compinit\n\n");
            try stdout.writeAll("Then reload your shell:\n");
            try stdout.writeAll("  source ~/.zshrc\n");
        },
        .fish => {
            try stdout.writeAll("Fish completions are automatically loaded from ~/.config/fish/completions/\n");
            try stdout.writeAll("No additional configuration needed! Start a new shell to use completions.\n");
        },
    }
}
