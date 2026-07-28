//! A hand-written stand-in for the `command_registry` module that
//! `zcli.generate` emits, supplied to `tool.zig` under `zig build test`.
//!
//! Without it the doc generator could not be compiled outside a consuming
//! project's build at all — which is why 704 lines of shipped, README-advertised
//! feature code had no test and no compile check in CI (#739). The fixture is
//! the whole trick: `command_registry` is just a module with five public decls,
//! so it can be written by hand.
//!
//! Deliberately adversarial in small ways, because the generator's escaping
//! rules are what break silently:
//!   - `|` in a description, which would close a markdown table cell,
//!   - `<`/`>`/`&`, which would inject markup into the HTML,
//!   - a leading `.`, which roff reads as a request line,
//!   - a hidden command, which must appear in NO format,
//!   - a nested command, which exercises directory creation and the HTML
//!     breadcrumb/subcommand link maths,
//!   - enum-valued and short-flag options, optional and variadic args.

const zcli = @import("zcli");

pub const app_name = "fixture";
pub const app_description = "Fixture CLI for <docs> & escaping";
pub const app_version = "9.9.9";

pub const global_options_info: []const zcli.OptionInfo = &.{
    .{ .name = "verbose", .short = 'v', .description = "Enable verbose output" },
    .{
        .name = "format",
        .description = "Output format",
        .takes_value = true,
        .enum_values = &.{ "text", "json" },
    },
};

pub const command_info: []const zcli.CommandInfo = &.{
    .{
        .path = &.{"greet"},
        .description = "Say hello | politely",
        .args = &.{
            .{ .name = "name", .description = "Who to greet" },
            .{ .name = "rest", .description = "Extra names", .is_optional = true, .is_variadic = true },
        },
        .options = &.{
            .{ .name = "loud", .short = 'l', .description = "Shout it" },
        },
        .aliases = &.{"hi"},
        .examples = &.{"greet world"},
    },
    .{
        .path = &.{"container"},
        .description = "Manage containers",
    },
    .{
        .path = &.{ "container", "ls" },
        .description = ".List <all> containers & more",
        .options = &.{
            .{ .name = "all", .short = 'a', .description = "Include stopped" },
        },
    },
    .{
        .path = &.{"internal"},
        .description = "Should never be documented",
        .hidden = true,
    },
};
