const std = @import("std");
const zcli = @import("zcli");

const bash = @import("bash.zig");
const zsh = @import("zsh.zig");
const fish = @import("fish.zig");
const powershell = @import("powershell.zig");
const resolve = @import("resolve.zig");
const wire = @import("wire.zig");

pub const commands = struct {
    /// Hidden dynamic-completion entry point (ADR-0026). The generated shell
    /// scripts call `app __complete <cword> -- <COMP_WORDS…>` at `<TAB>`; this
    /// resolves the field the cursor is on and runs its `complete` hook, printing
    /// a NUL-delimited stream: the FIRST record is a directive token (`default` /
    /// `also_files` / `also_dirs`), and every record after it is a candidate
    /// (`value` then optional `\t description`) — see `wire.writeResult`. The single
    /// `--` protects words that start with `-` from being parsed as this command's
    /// own options; any `--` the user typed is just another word after it.
    pub const __complete = struct {
        pub const meta = .{
            .hidden = true,
            .description = "Internal: emit dynamic completion candidates",
        };

        pub const Args = struct {
            /// Cursor word index (COMP_CWORD-style) into `words`.
            cword: usize,
            /// The shell's word array, `words[0]` = app name.
            words: []const []const u8 = &.{},
        };
        pub const Options = struct {};

        pub fn execute(args: Args, _: Options, context: anytype) !void {
            const commands_info = context.getAvailableCommandInfo();
            const global_options = context.getGlobalOptions();

            const match = resolve.resolve(context.allocator, commands_info, global_options, args.words, args.cword) catch |err| {
                debugLog(context, "resolve failed: {s}", .{@errorName(err)});
                return;
            } orelse return;

            switch (match.spec) {
                .hook => |hook| {
                    var req: zcli.completion.Request = .{
                        .allocator = context.allocator,
                        .io = context.io,
                        .environ = context.environ,
                        .partial = match.partial,
                        .args = match.positionals,
                    };
                    const result = hook(&req) catch |err| {
                        debugLog(context, "hook error: {s}", .{@errorName(err)});
                        return;
                    };
                    const out = context.stdout();
                    try wire.writeResult(out, result, match.partial);
                },
                // Builtins are resolved statically at generation time and never
                // reach `__complete`.
                .file, .dir => {},
            }
        }

        fn debugLog(context: anytype, comptime fmt: []const u8, fmt_args: anytype) void {
            const v = context.environ.get("ZCLI_COMPLETE_DEBUG") orelse return;
            if (v.len == 0 or std.mem.eql(u8, v, "0")) return;
            context.stderr().print("zcli __complete: " ++ fmt ++ "\n", fmt_args) catch {};
        }
    };

    pub const completions = struct {
        pub const meta = .{
            .description = "Manage shell completions for bash, zsh, fish, and PowerShell",
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
                    "completions generate powershell > _myapp.ps1",
                },
            };

            pub const Args = struct {
                shell: ?[]const u8 = null,
            };

            pub const Options = struct {};

            pub fn execute(args: Args, _: Options, context: anytype) !void {
                const allocator = context.allocator;
                var stdout = context.stdout();
                var stderr = context.stderr();

                // Determine shell type (from arg or auto-detect)
                const shell_type = if (args.shell) |shell_arg|
                    getShellType(shell_arg) orelse {
                        try stderr.print("Error: unsupported shell '{s}'\n", .{shell_arg});
                        try stderr.print("Supported shells: bash, zsh, fish, powershell\n", .{});
                        return error.UnsupportedShell;
                    }
                else
                    detectShell(allocator, context.environ) orelse {
                        try stderr.print("Error: could not detect shell from $SHELL environment variable\n", .{});
                        try stderr.print("Please specify shell explicitly: completions generate <bash|zsh|fish|powershell>\n", .{});
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
                    .powershell => try powershell.generate(allocator, context.app_name, commands_info, global_options),
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
                    "completions install powershell",
                },
            };

            pub const Args = struct {
                shell: ?[]const u8 = null,
            };

            pub const Options = struct {};

            pub fn execute(args: Args, _: Options, context: anytype) !void {
                const allocator = context.allocator;
                var stdout = context.stdout();
                var stderr = context.stderr();

                // Determine shell type (from arg or auto-detect)
                const shell_type = if (args.shell) |shell_arg|
                    getShellType(shell_arg) orelse {
                        try stderr.print("Error: unsupported shell '{s}'\n", .{shell_arg});
                        try stderr.print("Supported shells: bash, zsh, fish, powershell\n", .{});
                        return error.UnsupportedShell;
                    }
                else
                    detectShell(allocator, context.environ) orelse {
                        try stderr.print("Error: could not detect shell from $SHELL environment variable\n", .{});
                        try stderr.print("Please specify shell explicitly: completions install <bash|zsh|fish|powershell>\n", .{});
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
                    .powershell => try powershell.generate(allocator, context.app_name, commands_info, global_options),
                };
                defer allocator.free(script);

                // Determine installation path
                const install_path = try getInstallPath(allocator, context.environ, shell_type, context.app_name);
                defer allocator.free(install_path);

                // Create parent directory if it doesn't exist
                const dir_path = std.fs.path.dirname(install_path) orelse {
                    try stderr.print("Error: invalid install path '{s}'\n", .{install_path});
                    return error.InvalidPath;
                };

                std.Io.Dir.cwd().createDirPath(context.io, dir_path) catch |err| {
                    try stderr.print("Error: failed to create directory '{s}': {}\n", .{ dir_path, err });
                    return err;
                };

                // A symlink at the destination is plausible (a dotfiles setup
                // that links this name elsewhere), and replacing it rather than
                // writing through it changes the user's arrangement — so notice
                // it now and say so below, instead of silently swapping it for a
                // regular file. Purely informational: the safety comes from the
                // rename, not from this check.
                const replaced_symlink = if (std.Io.Dir.cwd().statFile(context.io, install_path, .{ .follow_symlinks = false })) |st|
                    st.kind == .sym_link
                else |_|
                    false;

                // Write the script into an exclusively-created temp file in the
                // destination directory, then rename it into place.
                //
                // Trust assumption: HOME belongs to the user, so this is not a
                // defence against a hostile home directory. But the destination
                // is PREDICTABLE (`~/.zsh/completions/_myapp`), so whatever
                // already sits at that name is something we did not put there. A
                // plain `createFile` follows a symlink planted there and writes
                // the script through it, into a file of the planter's choosing —
                // `~/.zshrc`, say. `rename(2)` never follows a symlink at the
                // destination; it replaces the link itself. So the script always
                // lands at exactly the path we print, and the temp file it comes
                // from is O_EXCL-created — the same rule the github-upgrade
                // plugin applies inside its private scratch dir. The rename also
                // makes the install atomic: a reader either sees the old script
                // or the new one, never a half-written file.
                //
                // That reasoning — and the regression test behind it — are
                // POSIX. Windows takes the same code path but nothing here
                // verifies it: creating a symlink there needs Developer Mode or
                // SeCreateSymbolicLinkPrivilege, so the test skips and the
                // rename's behaviour against a reparse point at the destination
                // stays unconfirmed. std additionally documents that the Windows
                // rename opens a brief window in which operations on the
                // destination return AccessDenied. So: asserted on POSIX, merely
                // intended on Windows — where planting the symlink is itself a
                // privileged act, which is why that gap is acceptable rather
                // than blocking.
                var staged = std.Io.Dir.cwd().createFileAtomic(context.io, install_path, .{ .replace = true }) catch |err| {
                    try stderr.print("Error: failed to write to '{s}': {}\n", .{ install_path, err });
                    return err;
                };
                // Runs after a successful `replace` too (it becomes a no-op);
                // on any failure below it removes the staged temp file.
                defer staged.deinit(context.io);

                try staged.file.writeStreamingAll(context.io, script);

                staged.replace(context.io) catch |err| {
                    try stderr.print("Error: failed to install to '{s}': {}\n", .{ install_path, err });
                    return err;
                };

                const shell_name = switch (shell_type) {
                    .bash => "bash",
                    .zsh => "zsh",
                    .fish => "fish",
                    .powershell => "powershell",
                };

                if (replaced_symlink) {
                    try stdout.print("Note: {s} was a symlink; it was replaced, not followed.\n", .{install_path});
                }

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
                    "completions uninstall powershell",
                },
            };

            pub const Args = struct {
                shell: ?[]const u8 = null,
            };

            pub const Options = struct {};

            pub fn execute(args: Args, _: Options, context: anytype) !void {
                const allocator = context.allocator;
                var stdout = context.stdout();
                var stderr = context.stderr();

                // Determine shell type (from arg or auto-detect)
                const shell_type = if (args.shell) |shell_arg|
                    getShellType(shell_arg) orelse {
                        try stderr.print("Error: unsupported shell '{s}'\n", .{shell_arg});
                        try stderr.print("Supported shells: bash, zsh, fish, powershell\n", .{});
                        return error.UnsupportedShell;
                    }
                else
                    detectShell(allocator, context.environ) orelse {
                        try stderr.print("Error: could not detect shell from $SHELL environment variable\n", .{});
                        try stderr.print("Please specify shell explicitly: completions uninstall <bash|zsh|fish|powershell>\n", .{});
                        return error.ShellNotDetected;
                    };

                // Determine installation path
                const install_path = try getInstallPath(allocator, context.environ, shell_type, context.app_name);
                defer allocator.free(install_path);

                // Remove completion script
                std.Io.Dir.cwd().deleteFile(context.io, install_path) catch |err| {
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
                    .powershell => "powershell",
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
    powershell,
};

fn getShellType(shell: []const u8) ?ShellType {
    if (std.mem.eql(u8, shell, "bash")) return .bash;
    if (std.mem.eql(u8, shell, "zsh")) return .zsh;
    if (std.mem.eql(u8, shell, "fish")) return .fish;
    // Accept the several names PowerShell is invoked under.
    if (std.mem.eql(u8, shell, "powershell")) return .powershell;
    if (std.mem.eql(u8, shell, "pwsh")) return .powershell;
    if (std.mem.eql(u8, shell, "powershell.exe")) return .powershell;
    if (std.mem.eql(u8, shell, "pwsh.exe")) return .powershell;
    return null;
}

fn detectShell(_: std.mem.Allocator, environ: *const std.process.Environ.Map) ?ShellType {
    const shell_path = environ.get("SHELL") orelse return null;

    // Extract shell name from path (e.g., "/bin/bash" -> "bash")
    const shell_name = std.fs.path.basename(shell_path);

    return getShellType(shell_name);
}

fn getInstallPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, shell_type: ShellType, app_name: []const u8) ![]const u8 {
    const home = environ.get("HOME") orelse return error.HomeNotFound;

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
        // PowerShell (pwsh) has no auto-loaded completions directory, so the script
        // is dropped in the standard cross-platform config dir and dot-sourced from
        // the user's $PROFILE (see printEnableInstructions).
        .powershell => try std.fmt.allocPrint(
            allocator,
            "{s}/.config/powershell/completions/{s}.ps1",
            .{ home, app_name },
        ),
    };
}

fn printEnableInstructions(shell_type: ShellType, context: anytype) !void {
    var stdout = context.stdout();

    switch (shell_type) {
        .bash => {
            try stdout.writeAll("The bash-completion package is recommended (it auto-loads scripts from\n");
            try stdout.writeAll("the completions directory). The generated script also works without it —\n");
            try stdout.writeAll("it falls back to reading COMP_WORDS directly — but you must source it.\n\n");
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
        .powershell => {
            try stdout.writeAll("PowerShell has no auto-loaded completions directory, so dot-source the\n");
            try stdout.writeAll("script from your profile. Add the following to your $PROFILE:\n\n");
            try stdout.writeAll("  . ~/.config/powershell/completions/");
            try stdout.print("{s}", .{context.app_name});
            try stdout.writeAll(".ps1\n\n");
            try stdout.writeAll("(Run `echo $PROFILE` to find its path; create the file if it doesn't exist.)\n");
            try stdout.writeAll("Then reload your shell:\n");
            try stdout.writeAll("  . $PROFILE\n");
        },
    }
}

fn printDisableInstructions(shell_type: ShellType, context: anytype) !void {
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
        .powershell => {
            try stdout.writeAll("To complete removal, remove this line from your $PROFILE:\n\n");
            try stdout.writeAll("  . ~/.config/powershell/completions/");
            try stdout.print("{s}", .{context.app_name});
            try stdout.writeAll(".ps1\n\n");
            try stdout.writeAll("Then reload your shell:\n");
            try stdout.writeAll("  . $PROFILE\n");
        },
        .fish => {
            try stdout.writeAll("Completions fully removed. No configuration cleanup needed.\n");
            try stdout.writeAll("Just start a new shell:\n");
            try stdout.writeAll("  exec fish\n");
        },
    }
}
