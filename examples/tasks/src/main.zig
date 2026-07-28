const std = @import("std");
const zcli = @import("zcli");
const registry = @import("command_registry");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

/// The tasks brand: a warm amber for command names and highlights, applied
/// everywhere — help output, prompts, and semantic styles.
pub const zcli_theme: zcli.Theme = .{
    .palette = .{
        .command = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } },
        .accent = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } },
    },
};

/// Prompts and progress indicators hide the cursor and drive raw mode, so a
/// panic mid-prompt must restore the terminal instead of stranding it.
pub const panic = zcli.ui.panic;
/// Segfaults do not route through `panic` — they go to
/// `root.debug.handleSegfault` — so a crash needs this hook too (#759).
pub const debug = zcli.ui.debug;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    // `run()` classifies and exits on every error it reports to the user —
    // command-not-found is exit 3, misuse 2, a command's own `fail()` 1 — so it
    // only ever *returns* an unexpected error. Propagating that is the whole
    // contract; there is nothing here to catch (#790).
    try app.run(init.gpa, init.io, init.environ_map, args);
}
