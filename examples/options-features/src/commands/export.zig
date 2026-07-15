const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Export deployment state (demonstrates meta.exclusive and a directional meta.options.requires)",
    .examples = &.{
        "export",
        "export --json",
        "export --output state.txt --format text",
    },
    .options = .{
        .json = .{ .description = "Print as JSON" },
        .yaml = .{ .description = "Print as YAML" },
        .output = .{ .short = 'o', .description = "Write to a file instead of stdout" },
        // `requires`: `--format` only makes sense once `--output` names a
        // file to write (stdout output is always plain text) — supplying
        // `format` without `output` is a reported misuse (exit code 2).
        .format = .{ .description = "File format when writing to a file", .requires = .{.output} },
    },
    // At most one of `json`/`yaml` may be supplied — supplying both is a
    // reported misuse (exit code 2), checked at comptime for typos/self-
    // reference and at runtime for the actual conflict.
    .exclusive = .{.{ .json, .yaml }},
};

pub const Args = struct {};

pub const Options = struct {
    json: bool = false,
    yaml: bool = false,
    output: ?[]const u8 = null,
    format: ?[]const u8 = null,
};

pub fn execute(_: Args, options: Options, context: *Context) !void {
    const stdout = context.stdout();

    const style: []const u8 = if (options.json) "json" else if (options.yaml) "yaml" else "text";

    if (options.output) |path| {
        try stdout.print("Wrote {s} state to {s} (format: {s})\n", .{ style, path, options.format orelse "default" });
    } else {
        try stdout.print("state: ok ({s})\n", .{style});
    }
}
