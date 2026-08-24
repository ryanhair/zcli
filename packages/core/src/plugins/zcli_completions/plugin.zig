const std = @import("std");
const builtin = @import("builtin");
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
                const install_path = getInstallPath(allocator, context.environ, shell_type, context.app_name) catch |err| {
                    try reportInstallPathError(stderr, err);
                    return err;
                };
                defer allocator.free(install_path);

                // Create the parent chain through the guarded primitive rather
                // than a hand-rolled dirname + createDirPath, so the host-syntax
                // and fully-qualified checks still apply to a path that was
                // built with an overridden convention.
                context.paths().ensureParent(context.io, install_path) catch |err| {
                    try stderr.print("Error: failed to create directory for '{s}': {}\n", .{ install_path, err });
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

                // A script left at the pre-consolidation HOME-relative path is
                // still on disk and may still be sourced, so it can shadow or
                // duplicate the one just written. Name it rather than deleting
                // it: it is a file the user put there under the old rules.
                if (legacyInstallPath(allocator, context.environ, shell_type, context.app_name, install_path)) |legacy| {
                    defer allocator.free(legacy);
                    if (std.Io.Dir.cwd().access(context.io, legacy, .{})) |_| {
                        try stdout.print(
                            "Note: an older completion script is still at {s}\n      Delete it — otherwise it may shadow the one just installed.\n\n",
                            .{legacy},
                        );
                    } else |_| {}
                }

                // Always print manual instructions
                try printEnableInstructions(shell_type, context, install_path);
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
                const install_path = getInstallPath(allocator, context.environ, shell_type, context.app_name) catch |err| {
                    try reportInstallPathError(stderr, err);
                    return err;
                };
                defer allocator.free(install_path);

                // Also remove a script left at the pre-consolidation
                // HOME-relative path: leaving it behind means a `$PROFILE` line
                // or a bash-completion search hit keeps loading a stale script
                // after the user believes completions are gone.
                var removed_legacy = false;
                if (legacyInstallPath(allocator, context.environ, shell_type, context.app_name, install_path)) |legacy| {
                    defer allocator.free(legacy);
                    if (std.Io.Dir.cwd().deleteFile(context.io, legacy)) |_| {
                        removed_legacy = true;
                        try stdout.print("Removed the legacy completion script at {s}\n", .{legacy});
                    } else |_| {}
                }

                // Remove completion script
                std.Io.Dir.cwd().deleteFile(context.io, install_path) catch |err| {
                    if (err == error.FileNotFound) {
                        if (!removed_legacy) {
                            try stdout.print("Completions not installed at {s}\n", .{install_path});
                            return;
                        }
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
                try printDisableInstructions(shell_type, context, install_path);
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

/// Resolve where this shell's completion script belongs.
///
/// The plugin overrides **`convention` only**; `syntax` stays `Syntax.host`, so
/// every emitted path is a native path the host filesystem accepts, and the
/// guarded `ensureParent` still applies. That split is the whole point: bash
/// and fish document XDG-rooted user completion directories, and that is true
/// of the bash or fish we are installing into *wherever it runs*, while the
/// filesystem underneath is always the host's.
fn getInstallPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, shell_type: ShellType, app_name: []const u8) ![]const u8 {
    const host_paths: zcli.Paths = .{
        .allocator = allocator,
        .environ = environ,
        .app_name = app_name,
    };
    var xdg_paths = host_paths;
    xdg_paths.convention = .xdg; // policy only — NOT syntax

    return switch (shell_type) {
        .bash => try bashInstallPath(xdg_paths),
        .fish => blk: {
            const leaf = try std.fmt.allocPrint(allocator, "{s}.fish", .{app_name});
            defer allocator.free(leaf);
            break :blk try xdg_paths.resolve(.config, &.{ "fish", "completions", leaf });
        },
        // zsh has no XDG contract — `fpath` is user-configured — so the
        // destination stays the conventional ~/.zsh/completions.
        .zsh => blk: {
            const home = try host_paths.home();
            defer allocator.free(home);
            const leaf = try std.fmt.allocPrint(allocator, "_{s}", .{app_name});
            defer allocator.free(leaf);
            break :blk try std.fs.path.join(allocator, &.{ home, ".zsh", "completions", leaf });
        },
        // PowerShell has no auto-loaded completions directory, and no XDG story
        // on Windows ($PROFILE lives under Documents, possibly OneDrive-
        // redirected). Since we merely drop a script and tell the user to
        // dot-source it, it belongs in OUR config location under the HOST
        // convention: ~/.config/powershell/… on POSIX,
        // %APPDATA%\powershell\… on Windows.
        .powershell => blk: {
            const leaf = try std.fmt.allocPrint(allocator, "{s}.ps1", .{app_name});
            defer allocator.free(leaf);
            break :blk try host_paths.resolve(.config, &.{ "powershell", "completions", leaf });
        },
    };
}

/// bash-completion resolves its user completion directory as
///
///   ${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions
///
/// so `BASH_COMPLETION_USER_DIR` takes **precedence over** the XDG default.
/// Newer versions treat it as a separator-delimited *search list*; we write to
/// the first entry, which is where bash looks first.
fn bashInstallPath(p: zcli.Paths) ![]const u8 {
    if (p.environ.get("BASH_COMPLETION_USER_DIR")) |raw| {
        // The list separator follows the SYNTAX, not the convention. Under
        // POSIX the list is colon-delimited as everywhere else in the XDG
        // world; but MSYS2 and Cygwin rewrite POSIX path lists into Windows
        // form when launching a native child, converting both the entries and
        // the `:` delimiters to `;`. A native binary can therefore receive
        // `C:\one;C:\two`, which a colon split would leave as one absurd path.
        //
        // Residual ambiguity, stated rather than hidden: `;` is legal in a
        // Windows filename, so a genuine single path `C:\my;dir` is split and
        // we use its first fragment — installing under `C:\my` when that
        // fragment is itself fully qualified, or falling back to the XDG
        // default when it is not. Either way the outcome is silent rather than
        // dangerous, and Windows has no way to express such a path in a
        // `;`-delimited list either. Not worth a quoting mini-language for a
        // directory nobody names that way.
        const list_sep: u8 = switch (p.syntax) {
            .posix => ':',
            .windows => ';',
        };
        const first = if (std.mem.indexOfScalar(u8, raw, list_sep)) |i| raw[0..i] else raw;

        // An invalid value is ignored and we fall through to the XDG default —
        // the same disposition `Paths` gives any other invalid override.
        if (p.validOverride(first)) |dir| {
            // Joined with the SYNTAX's separator, not `std.fs.path.join`, which
            // dispatches on the host. Trailing separators are trimmed so a root
            // (`/`, `C:\`) does not produce a doubled one.
            var root = dir;
            while (root.len > 0 and p.syntax.isSep(root[root.len - 1])) root = root[0 .. root.len - 1];
            const sep = p.syntax.sep();
            return try std.fmt.allocPrint(
                p.allocator,
                "{s}{c}completions{c}{s}",
                .{ root, sep, sep, p.app_name },
            );
        }
    }
    return try p.resolve(.data, &.{ "bash-completion", "completions", p.app_name });
}

/// The pre-consolidation HOME-relative destination, always `/`-joined. Kept so
/// `install` can warn about a stale script that would shadow the new one, and
/// `uninstall` can remove it. Null when HOME is unset or the legacy path is
/// identical to the resolved one.
fn legacyInstallPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, shell_type: ShellType, app_name: []const u8, resolved: []const u8) ?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    if (home.len == 0) return null;

    const path = switch (shell_type) {
        .bash => std.fmt.allocPrint(allocator, "{s}/.local/share/bash-completion/completions/{s}", .{ home, app_name }),
        .zsh => std.fmt.allocPrint(allocator, "{s}/.zsh/completions/_{s}", .{ home, app_name }),
        .fish => std.fmt.allocPrint(allocator, "{s}/.config/fish/completions/{s}.fish", .{ home, app_name }),
        .powershell => std.fmt.allocPrint(allocator, "{s}/.config/powershell/completions/{s}.ps1", .{ home, app_name }),
    } catch return null;

    if (std.mem.eql(u8, path, resolved)) {
        allocator.free(path);
        return null;
    }
    return path;
}

/// How a path must be escaped to survive being pasted into a given shell.
/// Every path we print as part of a *runnable command* goes through this: a
/// resolved path can contain spaces, quotes, `$`, backticks and `\`, and
/// unescaped those produce a broken command — or, with `` ` `` or `$(`, an
/// executable one. Control bytes cannot occur: `Paths` rejects them at
/// resolution (fatal for HOME, ignored for XDG_*), so no snippet can contain a
/// newline. A path printed in prose is not quoted.
const QuoteStyle = enum { posix, fish, powershell };

fn shellQuote(allocator: std.mem.Allocator, style: QuoteStyle, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (s) |c| switch (style) {
        // Single quotes suppress $, backtick, backslash and word splitting
        // entirely; the only character needing care is the quote itself.
        .posix => if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c),
        // fish single-quoting recognises exactly two escapes.
        .fish => switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\'' => try out.appendSlice(allocator, "\\'"),
            else => try out.append(allocator, c),
        },
        // PowerShell single-quoted strings are literal; $ and backtick are inert.
        .powershell => if (c == '\'') try out.appendSlice(allocator, "''") else try out.append(allocator, c),
    };
    try out.append(allocator, '\'');

    return out.toOwnedSlice(allocator);
}

/// Explain a path-resolution failure in terms the user can act on.
fn reportInstallPathError(stderr: *std.Io.Writer, err: anyerror) !void {
    switch (err) {
        error.HomeNotFound => {
            try stderr.writeAll("Error: this environment names no user home directory.\n");
            try stderr.writeAll("Set HOME (POSIX) or %APPDATA% (Windows) to an absolute path, or install\n");
            try stderr.writeAll("manually by sourcing the generated script from a path your shell can see.\n");
        },
        error.HomeNotAbsolute => {
            try stderr.writeAll("Error: the home directory in this environment is not a fully-qualified path.\n");
            try stderr.writeAll("Accepted forms: an absolute POSIX path (/home/u), a Windows drive path\n");
            try stderr.writeAll("(C:\\Users\\u), or a complete UNC root (\\\\server\\share).\n\n");
            try stderr.writeAll("A POSIX-style value such as /c/Users/u comes from MSYS2 or Cygwin with path\n");
            try stderr.writeAll("conversion suppressed for that variable (MSYS2_ENV_CONV_EXCL). zcli does not\n");
            try stderr.writeAll("translate it: that would mean guessing at a mount table it cannot read, and a\n");
            try stderr.writeAll("wrong guess installs the script where your shell will never look. Either\n");
            try stderr.writeAll("re-enable conversion for that variable, set an absolute Win32 HOME, or source\n");
            try stderr.writeAll("the generated script manually.\n");
        },
        error.HomeMalformed => {
            try stderr.writeAll("Error: the home directory in this environment contains control bytes or is\n");
            try stderr.writeAll("not valid text. Set it to a well-formed absolute path.\n");
        },
        else => {},
    }
}

/// Both instruction printers take the **resolved** `install_path` rather than
/// re-deriving it. The literals they used to hard-code are wrong for anyone who
/// has set XDG_* or BASH_COMPLETION_USER_DIR — they would send that user to
/// edit a `.bashrc` line pointing at a file that is not there — and a second
/// copy of the rule is a source of truth that can drift from the first.
fn printEnableInstructions(shell_type: ShellType, context: anytype, install_path: []const u8) !void {
    var stdout = context.stdout();
    const allocator = context.allocator;

    switch (shell_type) {
        .bash => {
            const q = try shellQuote(allocator, .posix, install_path);
            defer allocator.free(q);

            try stdout.writeAll("The bash-completion package is recommended (it auto-loads scripts from\n");
            try stdout.writeAll("the completions directory). The generated script also works without it —\n");
            try stdout.writeAll("it falls back to reading COMP_WORDS directly — but you must source it.\n\n");
            try stdout.writeAll("To enable completions, add the following to your ~/.bashrc:\n\n");
            try stdout.print("  if [ -f {s} ]; then\n", .{q});
            try stdout.print("    . {s}\n  fi\n\n", .{q});
            if (context.environ.get("BASH_COMPLETION_USER_DIR") != null) {
                try stdout.writeAll("NOTE: BASH_COMPLETION_USER_DIR is set. bash-completion treats it as a\n");
                try stdout.writeAll("      search list; the script was installed under its FIRST entry, which\n");
                try stdout.writeAll("      is where bash looks first.\n\n");
            }
            try stdout.writeAll("Then clear the completion cache and reload your shell:\n");
            try stdout.writeAll("  rm -f ~/.bash_completion.d/cache\n");
            try stdout.writeAll("  exec bash\n");
        },
        .zsh => {
            // The fpath line names the DIRECTORY, not the script.
            const parent = std.fs.path.dirname(install_path) orelse install_path;
            const q = try shellQuote(allocator, .posix, parent);
            defer allocator.free(q);

            try stdout.writeAll("To enable completions, add the following to your ~/.zshrc:\n\n");
            try stdout.print("  fpath=({s} $fpath)\n\n", .{q});
            try stdout.writeAll("NOTE: If you use oh-my-zsh or another framework, add this BEFORE\n");
            try stdout.writeAll("      sourcing the framework (which calls compinit automatically).\n");
            try stdout.writeAll("      If you use plain zsh, also add: autoload -Uz compinit && compinit\n\n");
            try stdout.writeAll("Then clear the completion cache and reload your shell:\n");
            try stdout.writeAll("  rm -f ~/.zcompdump*\n");
            try stdout.writeAll("  exec zsh\n");
        },
        .fish => {
            // Prose, not a runnable command — so not quoted.
            const parent = std.fs.path.dirname(install_path) orelse install_path;
            try stdout.print("Fish completions are automatically loaded from {s}\n", .{parent});
            try stdout.writeAll("No additional configuration needed! Just start a new shell:\n");
            try stdout.writeAll("  exec fish\n");
        },
        .powershell => {
            const q = try shellQuote(allocator, .powershell, install_path);
            defer allocator.free(q);

            try stdout.writeAll("PowerShell has no auto-loaded completions directory, so dot-source the\n");
            try stdout.writeAll("script from your profile. Add the following to your $PROFILE:\n\n");
            try stdout.print("  . {s}\n\n", .{q});
            try stdout.writeAll("(Run `echo $PROFILE` to find its path; create the file if it doesn't exist.)\n");
            try stdout.writeAll("Then reload your shell:\n");
            try stdout.writeAll("  . $PROFILE\n");
        },
    }
}

fn printDisableInstructions(shell_type: ShellType, context: anytype, install_path: []const u8) !void {
    var stdout = context.stdout();
    const allocator = context.allocator;

    switch (shell_type) {
        .bash => {
            const q = try shellQuote(allocator, .posix, install_path);
            defer allocator.free(q);

            try stdout.writeAll("To complete removal, remove these lines from your ~/.bashrc:\n\n");
            try stdout.print("  if [ -f {s} ]; then\n", .{q});
            try stdout.print("    . {s}\n  fi\n\n", .{q});
            try stdout.writeAll("Then reload your shell:\n");
            try stdout.writeAll("  exec bash\n");
        },
        .zsh => {
            const parent = std.fs.path.dirname(install_path) orelse install_path;
            const q = try shellQuote(allocator, .posix, parent);
            defer allocator.free(q);

            try stdout.writeAll("To complete removal, remove this line from your ~/.zshrc:\n\n");
            try stdout.print("  fpath=({s} $fpath)\n\n", .{q});
            try stdout.writeAll("Or remove just this completion directory if others exist.\n\n");
            try stdout.writeAll("Then reload your shell:\n");
            try stdout.writeAll("  exec zsh\n");
        },
        .powershell => {
            const q = try shellQuote(allocator, .powershell, install_path);
            defer allocator.free(q);

            try stdout.writeAll("To complete removal, remove this line from your $PROFILE:\n\n");
            try stdout.print("  . {s}\n\n", .{q});
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

// ============================================================================
// Tests — install-path resolution and shell quoting.
//
// `syntax` is a runtime field, so the Windows-syntax rows (the MSYS list
// representation, the native PowerShell destination) are asserted on every
// runner rather than only on a Windows one.
// ============================================================================

const testing = std.testing;

fn testPaths(environ: *const std.process.Environ.Map, syntax: zcli.Paths.Syntax) zcli.Paths {
    return .{
        .allocator = testing.allocator,
        .environ = environ,
        .app_name = "myapp",
        .convention = .xdg,
        .syntax = syntax,
    };
}

fn envMap(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(testing.allocator);
    errdefer map.deinit();
    for (pairs) |kv| try map.put(kv[0], kv[1]);
    return map;
}

test "bash destination: XDG_DATA_HOME steers it; the default is ~/.local/share" {
    {
        var env = try envMap(&.{.{ "HOME", "/home/u" }});
        defer env.deinit();
        const got = try bashInstallPath(testPaths(&env, .posix));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/home/u/.local/share/bash-completion/completions/myapp", got);
    }
    {
        var env = try envMap(&.{ .{ "HOME", "/home/u" }, .{ "XDG_DATA_HOME", "/custom/data" } });
        defer env.deinit();
        const got = try bashInstallPath(testPaths(&env, .posix));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/custom/data/bash-completion/completions/myapp", got);
    }
}

test "bash destination: BASH_COMPLETION_USER_DIR wins, first list entry first" {
    // Single entry.
    {
        var env = try envMap(&.{ .{ "HOME", "/home/u" }, .{ "XDG_DATA_HOME", "/custom/data" }, .{ "BASH_COMPLETION_USER_DIR", "/opt/bc" } });
        defer env.deinit();
        const got = try bashInstallPath(testPaths(&env, .posix));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/opt/bc/completions/myapp", got);
    }
    // Colon-separated list under POSIX syntax.
    {
        var env = try envMap(&.{ .{ "HOME", "/home/u" }, .{ "BASH_COMPLETION_USER_DIR", "/opt/one:/opt/two" } });
        defer env.deinit();
        const got = try bashInstallPath(testPaths(&env, .posix));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/opt/one/completions/myapp", got);
    }
}

test "bash destination: a semicolon list under windows syntax (the MSYS native-child form)" {
    // MSYS/Cygwin rewrite `/a:/b` to `C:\a;C:\b` when launching a native child.
    // A colon split would shred the drive letters; treating the whole value as
    // one path would fail validation and silently fall back to the XDG default,
    // installing where that user's bash does not look first.
    var env = try envMap(&.{
        .{ "HOME", "C:\\Users\\u" },
        .{ "BASH_COMPLETION_USER_DIR", "C:\\one;C:\\two" },
    });
    defer env.deinit();
    const got = try bashInstallPath(testPaths(&env, .windows));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("C:\\one\\completions\\myapp", got);
}

test "bash destination: an invalid BASH_COMPLETION_USER_DIR falls back to the XDG default" {
    // Relative, empty, and the documented `C:\my;dir` false-split — all ignored
    // and fallen through, the same disposition Paths gives any invalid override.
    for ([_][]const u8{ "relative/dir", "", "::" }) |v| {
        var env = try envMap(&.{ .{ "HOME", "/home/u" }, .{ "BASH_COMPLETION_USER_DIR", v } });
        defer env.deinit();
        const got = try bashInstallPath(testPaths(&env, .posix));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/home/u/.local/share/bash-completion/completions/myapp", got);
    }
    {
        // A first fragment that is NOT fully qualified falls back.
        var env = try envMap(&.{ .{ "HOME", "C:\\Users\\u" }, .{ "BASH_COMPLETION_USER_DIR", "relative;C:\\two" } });
        defer env.deinit();
        const got = try bashInstallPath(testPaths(&env, .windows));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("C:\\Users\\u\\.local\\share\\bash-completion\\completions\\myapp", got);
    }
    {
        // The documented residual ambiguity: `;` is legal in a Windows
        // filename, so a genuine single path `C:\my;dir` is split and we use
        // its first fragment — which here IS fully qualified, so we install
        // under `C:\my` rather than falling back. Silent rather than
        // dangerous, and unrepresentable in a `;`-delimited list anyway.
        var env = try envMap(&.{ .{ "HOME", "C:\\Users\\u" }, .{ "BASH_COMPLETION_USER_DIR", "C:\\my;dir" } });
        defer env.deinit();
        const got = try bashInstallPath(testPaths(&env, .windows));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("C:\\my\\completions\\myapp", got);
    }
}

test "fish destination follows XDG_CONFIG_HOME" {
    var env = try envMap(&.{ .{ "HOME", "/home/u" }, .{ "XDG_CONFIG_HOME", "/custom/cfg" } });
    defer env.deinit();
    const got = try getInstallPath(testing.allocator, &env, .fish, "myapp");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/custom/cfg/fish/completions/myapp.fish", got);
}

test "zsh destination is HOME-relative and ignores XDG (fpath is user-configured)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = try envMap(&.{ .{ "HOME", "/home/u" }, .{ "XDG_CONFIG_HOME", "/custom/cfg" }, .{ "XDG_DATA_HOME", "/custom/data" } });
    defer env.deinit();
    const got = try getInstallPath(testing.allocator, &env, .zsh, "myapp");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u/.zsh/completions/_myapp", got);
}

test "PowerShell destination follows the HOST convention on both platforms" {
    var env = try envMap(&.{
        .{ "HOME", "/home/u" },
        .{ "APPDATA", "C:\\Users\\u\\AppData\\Roaming" },
    });
    defer env.deinit();
    const got = try getInstallPath(testing.allocator, &env, .powershell, "myapp");
    defer testing.allocator.free(got);

    const expected = if (builtin.os.tag == .windows)
        "C:\\Users\\u\\AppData\\Roaming\\powershell\\completions\\myapp.ps1"
    else
        "/home/u/.config/powershell/completions/myapp.ps1";
    try testing.expectEqualStrings(expected, got);
}

test "a POSIX-style HOME under windows syntax is rejected, not translated" {
    var env = try envMap(&.{.{ "HOME", "/c/Users/u" }});
    defer env.deinit();
    var p = testPaths(&env, .windows);
    p.convention = .xdg;
    try testing.expectError(error.HomeNotAbsolute, p.resolve(.data, &.{"bash-completion"}));

    // The diagnostic names both remedies rather than just saying "not absolute".
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try reportInstallPathError(&buf.writer, error.HomeNotAbsolute);
    const msg = buf.written();
    try testing.expect(std.mem.indexOf(u8, msg, "MSYS2_ENV_CONV_EXCL") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "manually") != null);
}

test "shellQuote: a path with a space, quote, dollar and backtick per shell" {
    const nasty = "/home/John Smith/it's $HOME `x`";

    const posix_q = try shellQuote(testing.allocator, .posix, nasty);
    defer testing.allocator.free(posix_q);
    try testing.expectEqualStrings("'/home/John Smith/it'\\''s $HOME `x`'", posix_q);

    const fish_q = try shellQuote(testing.allocator, .fish, nasty);
    defer testing.allocator.free(fish_q);
    try testing.expectEqualStrings("'/home/John Smith/it\\'s $HOME `x`'", fish_q);

    const ps_q = try shellQuote(testing.allocator, .powershell, nasty);
    defer testing.allocator.free(ps_q);
    try testing.expectEqualStrings("'/home/John Smith/it''s $HOME `x`'", ps_q);

    // A backslash is literal inside POSIX and PowerShell single quotes, but is
    // one of the two characters fish escapes.
    const win = "C:\\Users\\u";
    const fish_win = try shellQuote(testing.allocator, .fish, win);
    defer testing.allocator.free(fish_win);
    try testing.expectEqualStrings("'C:\\\\Users\\\\u'", fish_win);
}
