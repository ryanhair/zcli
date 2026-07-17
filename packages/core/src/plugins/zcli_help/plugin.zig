//! zcli-help Plugin
//!
//! Provides help functionality for CLI applications using the lifecycle hook
//! plugin system. This file is the thin hook surface: it wires the `--help`
//! flag, the `help` command, and the argv rewrite / error reactions that decide
//! *when* and *which* help to show. The actual rendering lives in focused files
//! (mirroring how `zcli_completions` decomposes into per-shell files):
//!
//!   - `app_help.zig`     — app, root, and command-group help,
//!   - `command_help.zig` — a single resolved command's help,
//!   - `format.zig`       — the shared per-field tables, sections, and the
//!                          usage arg-pattern.

const std = @import("std");
const zcli = @import("zcli");

const app_help = @import("app_help.zig");
const command_help = @import("command_help.zig");
const format = @import("format.zig");

/// Unique identifier for this plugin (required for type-safe context data)
pub const plugin_id = "zcli_help";

/// Help wins over --version when both are present: the plugin pipeline sorts
/// plugins by priority (higher first) and runs their hooks in that order, so a
/// value above the version plugin's 90 makes our preExecute render help first.
pub const priority = 100;

/// Plugin-specific context data (type-safe, stored in computed Context)
pub const ContextData = struct {
    help_requested: bool = false,
};

/// Public API: Check if help was requested
pub fn isHelpRequested(context: anytype) bool {
    return context.plugins.zcli_help.help_requested;
}

/// Global options provided by this plugin
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("help", bool, .{ .short = 'h', .default = false, .description = "Show help message" }),
};

/// Handle global options - specifically the --help flag
pub fn handleGlobalOption(
    context: anytype,
    option_name: []const u8,
    value: anytype,
) !void {
    // The registry dispatches --help with its declared bool type, so `value` is
    // always a bool here — no runtime type guard needed.
    if (std.mem.eql(u8, option_name, "help") and value) {
        context.plugins.zcli_help.help_requested = true;
    }
}

/// Rewrite `myapp help <cmd...>` into `myapp <cmd...>` with help requested, so
/// the target command resolves normally and populates the context (meta,
/// module_info) that the help renderer reads. Without this, `help <cmd>` would
/// resolve the `help` command itself and describe *it* instead of the target.
///
/// Multi-word paths work for free — `help remote add` drops the leading `help`
/// and lets normal resolution match `remote add`. Bare `help` (or `help` with a
/// trailing option like `help --foo`) is left untouched: it routes to the help
/// command below, which shows app help.
pub fn transformArgs(
    context: anytype,
    args: []const []const u8,
) !zcli.TransformResult {
    if (args.len > 1 and
        std.mem.eql(u8, args[0], "help") and
        !std.mem.startsWith(u8, args[1], "-"))
    {
        context.plugins.zcli_help.help_requested = true;
        return .{ .args = args[1..] };
    }
    return .{ .args = args };
}

/// Pre-execute hook to show help if requested
pub fn preExecute(
    context: anytype,
    args: zcli.ParsedArgs,
) !?zcli.ParsedArgs {
    if (context.plugins.zcli_help.help_requested) {
        // An empty command_path is the app level. When a command module
        // resolved there, it's the root group's index (registered at the
        // empty path, ADR-0029) — render root help: app help plus the root
        // command's own args/options. With no resolved module it's plain app
        // help. Otherwise the resolved command's context drives the command
        // help — payload-free, everything renders from context.command_meta /
        // command_module_info.
        // Explicit help request → stdout.
        if (context.command_path.len == 0) {
            if (context.command_module_info != null) {
                try app_help.showRoot(context, true);
            } else {
                try app_help.showApp(context, true);
            }
        } else {
            try command_help.showCommand(context, true);
        }

        // Return null to stop execution
        return null;
    }

    // Continue normal execution
    return args;
}

/// Error hook to handle command group help
pub fn onError(
    context: anytype,
    err: anyerror,
) !bool {
    if (err == error.CommandNotFound) {
        // A pending --version belongs to the version plugin, which runs at a
        // lower priority and would otherwise lose this CommandNotFound to the
        // group-help rendering below — `myapp --version <group>` must print
        // the version, exactly like `myapp --version <unknown>` does (#403).
        // Comptime-guarded: apps without the version plugin skip this.
        if (comptime @hasField(@TypeOf(context.plugins), "zcli_version")) {
            if (context.plugins.zcli_version.version_requested) return false;
        }
        // If no command was provided at all, show app help. This is an error
        // reaction (CommandNotFound), so it goes to stderr.
        if (context.command_path.len == 0) {
            try app_help.showApp(context, false);
            return true; // Error handled, don't let it propagate
        }

        // Check if this looks like a command group (has subcommands)
        if (context.command_path.len > 0) {
            const command_infos = context.getAvailableCommandInfo();

            // Try to find the deepest command group that has subcommands
            // Start from the full path and work backwards
            var depth = context.command_path.len;
            while (depth > 0) : (depth -= 1) {
                const prefix = context.command_path[0..depth];
                var has_subcommands = false;

                // Check if this prefix has any subcommands
                for (command_infos) |cmd_info| {
                    // Skip hidden commands
                    if (cmd_info.hidden) continue;

                    if (cmd_info.path.len > depth) {
                        // Check if the prefix matches
                        var matches = true;
                        for (prefix, 0..) |part, i| {
                            if (!std.mem.eql(u8, cmd_info.path[i], part)) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            has_subcommands = true;
                            break;
                        }
                    }
                }

                // If we found subcommands at this depth, show help for this group
                // using the same renderer as `<group> --help` (command_help). A
                // pure group is unregistered, so its CommandNotFound carries the
                // full unmatched argv (e.g. `app foo baz`); narrow command_path to
                // the matched group prefix so the command renderer describes the
                // group, not the phantom deeper command. The prefix is a subslice
                // of the already-owned command_path, so no allocation is needed.
                if (has_subcommands) {
                    context.command_path = prefix;
                    // Reached from an error (a bare command group) → stderr.
                    try command_help.showCommand(context, false);
                    return true; // Error handled, don't let it propagate
                }
            }
        }
    }

    return false; // Error not handled
}

/// Commands provided by this plugin
pub const commands = struct {
    /// The help command itself. `help <cmd...>` is handled earlier by
    /// transformArgs (which rewrites it to the target command with help
    /// requested), so this command only ever runs for a bare `help` and shows
    /// application help.
    pub const help = struct {
        pub const Args = struct {};

        pub const Options = struct {};

        pub const meta = .{
            .description = "Show help for commands",
        };

        pub fn execute(args: Args, options: Options, context: anytype) !void {
            _ = args;
            _ = options;
            // Explicitly invoked → stdout.
            try app_help.showApp(context, true);
        }
    };
};

test {
    std.testing.refAllDecls(@This());
    // Pull the split renderers' tests into this binary (the help plugin's test
    // root is this file).
    _ = app_help;
    _ = command_help;
    _ = format;
}

test "help plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "global_options"));
    try std.testing.expect(@hasDecl(@This(), "handleGlobalOption"));
    try std.testing.expect(@hasDecl(@This(), "preExecute"));
    try std.testing.expect(@hasDecl(@This(), "commands"));
    try std.testing.expect(@hasDecl(@This(), "ContextData"));
    try std.testing.expect(@hasDecl(@This(), "isHelpRequested"));
}
