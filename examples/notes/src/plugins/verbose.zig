//! verbose.zig — a plugin adding a global `--verbose` flag.
//!
//! A plugin (src/plugins/<name>.zig, auto-discovered) adds cross-cutting
//! behavior to every command. This one declares a `--verbose` flag and, when
//! it's set, prints a diagnostic line before each command runs.

const std = @import("std");
const zcli = @import("zcli");

/// Names this plugin's slot on the context. Commands — and this plugin's own
/// hooks — read its state as `context.plugins.verbose`.
pub const plugin_id = "verbose";

/// This plugin's state, one instance per command run, reachable at
/// `context.plugins.verbose`. Give every field a default.
pub const ContextData = struct {
    enabled: bool = false,
};

/// Global options show up in every command's `--help`. Declared here, handled
/// by `handleGlobalOption` below.
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("verbose", bool, .{ .short = 'v', .default = false, .description = "Print diagnostic output" }),
};

/// The framework calls this while parsing, once per declared global option it
/// sees — before any command runs. Stash the value in our ContextData for the
/// rest of the run to read.
pub fn handleGlobalOption(context: anytype, name: []const u8, value: anytype) !void {
    if (std.mem.eql(u8, name, "verbose")) context.plugins.verbose.enabled = value;
}

/// Hooks are @hasDecl-gated — declare only the ones you need. preExecute runs
/// before every command; return the (possibly rewritten) args, or null to halt.
pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs {
    if (context.plugins.verbose.enabled)
        try context.stderr().writeAll("[verbose] verbose mode enabled\n");
    return args;
}
