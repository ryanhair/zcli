//! The single registry-level comptime validation pass (#677).
//!
//! Validation used to be a reactive checklist split across three sites that
//! each saw only part of the picture: `zcli.validateCommand` saw one module at
//! a time (called from `register()` and plugin-command discovery), and
//! `CompiledRegistry` carried separate comptime blocks for path conflicts and
//! global options — nothing saw the *composition*. The varargs SEGV (#662),
//! the global-vs-command option shadow (#663), and the `--no-X` negation
//! shadow (#667) all lived in the gaps between those sites. This pass runs
//! once, from `CompiledRegistry`, with total knowledge: every file-based
//! command, every plugin command, and every plugin global option.
//!
//! Layering:
//!   - Per-module rules — the command contract (`Args`/`Options` shape,
//!     varargs order, optional/array default shapes, in-command option
//!     spelling collisions including `--no-…` negations, meta hygiene) — live
//!     in `zcli.validateCommand`. This pass drives that check over every
//!     command in the composition, file-based and plugin alike, so a rule
//!     added there automatically covers both populations.
//!   - Per-plugin rules (misspelled lifecycle hooks, the ContextData
//!     contract) live in `plugin_types.validatePlugin`, driven from here for
//!     every registered plugin.
//!   - Cross-module rules are implemented HERE, where the whole composition
//!     is visible: command-path uniqueness (file vs file, plugin vs file,
//!     plugin vs plugin), command-group shape, global-option uniqueness
//!     across plugins, and global-vs-command option shadowing — effective
//!     long names, declared shorts, and derived `--no-…` negations.
//!
//! Every error names the offending command by its space-joined path (which
//! maps directly to a file under src/commands/ or a plugin's `commands`
//! struct), the field/flag involved, and what to change.

const std = @import("std");
const zcli = @import("../zcli.zig");
const plugin_types = @import("../plugin_types.zig");
const option_utils = @import("../options/utils.zig");
const paths = @import("paths.zig");
const builder = @import("builder.zig");

const CommandEntry = builder.CommandEntry;
const comptimeJoinPath = paths.comptimeJoinPath;
const pathsEqual = paths.pathsEqual;

/// Validate the whole program composition at compile time. Called exactly once,
/// from `CompiledRegistry`, with the file-based command entries, the discovered
/// plugin command entries (including nested), and the registered plugin types.
pub fn validateComposition(
    comptime cmd_entries: []const CommandEntry,
    comptime plugin_cmd_entries: []const CommandEntry,
    comptime new_plugins: []const type,
) void {
    comptime {
        // The pass is O(commands × options) with pairwise path comparisons on
        // top; give it headroom well above the 1000 default so growing an app
        // never trips the quota inside a validation loop.
        @setEvalBranchQuota(1_000_000);

        // ── Per-module contract, over the WHOLE composition ─────────────────
        // File-based and plugin commands get the identical contract check, so
        // a rule added to `validateCommand` can never cover only one
        // population. (Alias entries share their canonical entry's module;
        // re-validating them is free — comptime memoizes on identical args.)
        for (cmd_entries) |cmd| {
            zcli.validateCommand(comptimeJoinPath(cmd.path), cmd.module);
        }
        for (plugin_cmd_entries) |cmd| {
            zcli.validateCommand(comptimeJoinPath(cmd.path), cmd.module);
        }

        // ── Per-plugin contract ─────────────────────────────────────────────
        // Backstop against silently-dead misspelled hooks and ContextData
        // contract violations (exact-name detection has no diagnostics of its
        // own).
        for (new_plugins) |Plugin| {
            plugin_types.validatePlugin(Plugin);
        }

        // ── Command-path uniqueness ─────────────────────────────────────────
        // The router resolves a path to exactly one module; a duplicate would
        // silently shadow. Three distinct messages so the author knows which
        // two populations collided.
        for (cmd_entries, 0..) |cmd, i| {
            for (cmd_entries[0..i]) |prev| {
                if (pathsEqual(prev.path, cmd.path)) {
                    @compileError("Duplicate command path: " ++ comptimeJoinPath(cmd.path));
                }
            }
        }
        for (plugin_cmd_entries, 0..) |plugin_cmd, i| {
            for (cmd_entries) |cmd| {
                if (pathsEqual(cmd.path, plugin_cmd.path)) {
                    @compileError("Plugin command conflicts with existing command: " ++ comptimeJoinPath(plugin_cmd.path));
                }
            }
            for (plugin_cmd_entries[0..i]) |prev| {
                if (pathsEqual(prev.path, plugin_cmd.path)) {
                    @compileError("Duplicate plugin command: " ++ comptimeJoinPath(plugin_cmd.path));
                }
            }
        }

        // ── Command-group shape ─────────────────────────────────────────────
        // A command that has subcommands is a group: routing tries the longest
        // path first, so the group's own positionals would swallow what looks
        // like a subcommand name. Checked over the combined list so a plugin
        // command nested under a file-based group (or vice versa) counts too.
        const all_entries = cmd_entries ++ plugin_cmd_entries;
        for (all_entries) |cmd| {
            const has_subcommands = blk: {
                for (all_entries) |other| {
                    if (other.path.len <= cmd.path.len) continue;
                    var is_subcommand = true;
                    for (cmd.path, 0..) |component, i| {
                        if (!std.mem.eql(u8, component, other.path[i])) {
                            is_subcommand = false;
                            break;
                        }
                    }
                    if (is_subcommand) break :blk true;
                }
                break :blk false;
            };
            if (has_subcommands and @hasDecl(cmd.module, "Args")) {
                if (std.meta.fields(cmd.module.Args).len > 0) {
                    @compileError("Optional command group '" ++ comptimeJoinPath(cmd.path) ++
                        "' cannot have Args fields. " ++
                        "Command groups with subcommands must have an empty Args struct.");
                }
            }
        }

        // ── Global-option uniqueness across plugins ─────────────────────────
        // Globals from every plugin share one namespace; the first match wins
        // in parseGlobalOptions, so a duplicate would silently shadow.
        const flat_globals = blk: {
            var opts: []const plugin_types.GlobalOption = &.{};
            for (new_plugins) |Plugin| {
                if (plugin_types.hasGlobalOptions(Plugin)) {
                    opts = opts ++ Plugin.global_options;
                }
            }
            break :blk opts;
        };
        for (flat_globals, 0..) |opt_a, i| {
            for (flat_globals[i + 1 ..]) |opt_b| {
                if (std.mem.eql(u8, opt_a.name, opt_b.name)) {
                    @compileError("Duplicate global option name: --" ++ opt_a.name ++ ". Two plugins define the same global option.");
                }
                if (opt_a.short != null and opt_b.short != null and opt_a.short.? == opt_b.short.?) {
                    @compileError("Duplicate global option short flag: -" ++ &[_]u8{opt_a.short.?} ++ " (used by both --" ++ opt_a.name ++ " and --" ++ opt_b.name ++ ")");
                }
            }
        }

        // ── Global-vs-command option shadowing ──────────────────────────────
        // parseGlobalOptions() scans the entire argv and consumes any token
        // matching a global option's long name or short flag *before* routing,
        // so a command spelling that collides with a global would never reach
        // the command — the global handler eats it and the field keeps its
        // default (#663). Checked for every command in the composition (plugin
        // commands parse their options through the same pipeline), and for all
        // three spellings a command can answer to: its effective long name,
        // its declared short, and — for boolean options — the auto-generated
        // `--no-<name>` negation.
        for (new_plugins) |Plugin| {
            if (!plugin_types.hasGlobalOptions(Plugin)) continue;
            for (Plugin.global_options) |gopt| {
                for (all_entries) |cmd| {
                    if (!@hasDecl(cmd.module, "Options")) continue;
                    const meta = if (@hasDecl(cmd.module, "meta")) cmd.module.meta else null;
                    for (std.meta.fields(cmd.module.Options)) |field| {
                        const long = option_utils.effectiveLongName(meta, field.name);
                        if (std.mem.eql(u8, long, gopt.name)) {
                            @compileError("Command '" ++ comptimeJoinPath(cmd.path) ++
                                "' option --" ++ long ++ " (field '" ++ field.name ++
                                "') collides with global option --" ++ gopt.name ++
                                " provided by plugin '" ++ @typeName(Plugin) ++
                                "'. The global handler consumes this flag before the command runs, so the command would never see it. Rename the command's option (e.g. `meta.options." ++
                                field.name ++ ".name`) or remove the conflicting global option.");
                        }
                        const short = option_utils.shortCharForField(meta, field.name);
                        if (short != null and gopt.short != null and short.? == gopt.short.?) {
                            @compileError("Command '" ++ comptimeJoinPath(cmd.path) ++
                                "' option -" ++ &[_]u8{short.?} ++ " (field '" ++ field.name ++
                                "') collides with global short flag -" ++ &[_]u8{gopt.short.?} ++
                                " (--" ++ gopt.name ++ ") provided by plugin '" ++ @typeName(Plugin) ++
                                "'. The global handler consumes this flag before the command runs, so the command would never see it. Rename the command's short (`meta.options." ++
                                field.name ++ ".short`) or remove the conflicting global option.");
                        }
                        // A boolean command option also answers to `--no-<long>`.
                        // A global option carrying exactly that name would eat
                        // the negation before the command parser sees it — the
                        // same silent shadow as above, via the derived spelling.
                        if (option_utils.isBooleanFlag(field.type) and
                            std.mem.eql(u8, gopt.name, "no-" ++ long))
                        {
                            @compileError("Command '" ++ comptimeJoinPath(cmd.path) ++
                                "' boolean option --" ++ long ++ " (field '" ++ field.name ++
                                "') auto-generates the negation `--no-" ++ long ++
                                "`, which collides with global option --" ++ gopt.name ++
                                " provided by plugin '" ++ @typeName(Plugin) ++
                                "'. The global handler consumes `--no-" ++ long ++
                                "` before the command runs, so the negation would never reach the command. Rename the command's option (e.g. `meta.options." ++
                                field.name ++ ".name`) or remove the conflicting global option.");
                        }
                    }
                }
            }
        }
    }
}

test "validateComposition accepts a well-formed composition" {
    // A representative composition: a file-based group with a subcommand, a
    // plugin providing both a command and global options. Reaching the final
    // assertion means the whole pass ran without tripping a @compileError.
    const Group = struct {
        pub const meta = .{ .description = "A group" };
    };
    const Sub = struct {
        pub const Args = struct { name: []const u8 };
        pub const Options = struct { loud: bool = false };
        pub fn execute(_: Args, _: Options, _: anytype) !void {}
    };
    const Plugin = struct {
        pub const global_options = [_]plugin_types.GlobalOption{
            zcli.option("verbose", bool, .{ .short = 'v', .default = false, .description = "chatty" }),
        };
        pub const commands = struct {
            pub const version = struct {
                pub const Args = struct {};
                pub const Options = struct {};
                pub fn execute(_: Args, _: Options, _: anytype) !void {}
            };
        };
    };
    const cmds = [_]CommandEntry{
        .{ .path = &.{"users"}, .module = Group },
        .{ .path = &.{ "users", "add" }, .module = Sub },
    };
    const plugin_cmds = comptime builder.discoverPluginCommands(Plugin.commands, &.{});
    comptime validateComposition(&cmds, plugin_cmds, &.{Plugin});
    try std.testing.expect(true);
}

// The negative cases below are compile errors by design, so they cannot be run
// as tests. Each is verified by hand; uncomment one to see the message it
// emits. (Per-module negative cases — varargs order, `--no-…` collisions
// inside one command, default shapes, meta typos — live with
// `zcli.validateCommand` in zcli.zig; the cases here are the ones only the
// whole composition can reveal.)
//
//   Duplicate command path: users add
//     two entries registered at the same path
//
//   Plugin command conflicts with existing command: version
//     a plugin `commands.version` while src/commands/version.zig exists
//
//   Duplicate plugin command: version
//     two plugins both exporting `commands.version`
//
//   Optional command group 'users' cannot have Args fields. ...
//     a group with subcommands whose Args struct has fields
//
//   Duplicate global option name: --verbose. Two plugins define the same global option.
//   Duplicate global option short flag: -v (used by both --verbose and --version)
//
//   Global-vs-command shadowing (#663) — long, short, and derived negation:
//
//   Command 'users add' option --verbose (field 'verbose') collides with global
//     option --verbose provided by plugin '...'. The global handler consumes this
//     flag before the command runs, ...
//     pub const Options = struct { verbose: bool = false };  // + a --verbose global
//
//   Command 'users add' option -v (field 'verbose') collides with global short
//     flag -v (--verbose) provided by plugin '...'. ...
//     meta.options.verbose.short = 'v'  // + a global with .short = 'v'
//
//   Command 'users add' boolean option --color (field 'color') auto-generates
//     the negation `--no-color`, which collides with global option --no-color
//     provided by plugin '...'. The global handler consumes `--no-color` before
//     the command runs, ...
//     pub const Options = struct { color: bool = true };  // + a --no-color global
