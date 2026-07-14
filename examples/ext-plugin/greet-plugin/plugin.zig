//! greet-plugin — a zcli plugin shipped as its OWN Zig package.
//!
//! This is the third-party-plugin distribution model: the plugin lives in a
//! separate package (its own build.zig / build.zig.zon), and a consuming CLI
//! opts in from build.zig with
//!
//!     const greet = b.dependency("greet_plugin", .{ .target = target, .optimize = optimize });
//!     ... .plugins = &.{ ..., .{ .name = "greet", .dependency = greet } },
//!
//! The plugin source is identical to a project-local plugin — the only
//! difference is where it lives and how it's registered. `zcli.generate()`
//! injects the consumer's `zcli` import into this module, so this package needs
//! no zcli dependency of its own (see greet-plugin/build.zig).

const std = @import("std");
const zcli = @import("zcli");

/// Names this plugin's slot on the context: `context.plugins.greet`.
pub const plugin_id = "greet";

/// Per-run plugin state. Every field needs a default.
pub const ContextData = struct {
    enabled: bool = false,
};

/// A global `--greet` flag, shown in every command's `--help`.
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("greet", bool, .{ .default = false, .description = "Greet before running the command" }),
};

pub fn handleGlobalOption(context: anytype, name: []const u8, value: anytype) !void {
    if (std.mem.eql(u8, name, "greet")) context.plugins.greet.enabled = value;
}

/// preExecute runs before every command; return the (possibly rewritten) args,
/// or null to halt.
pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs {
    if (context.plugins.greet.enabled)
        try context.stderr().writeAll("hello from the external greet plugin\n");
    return args;
}
