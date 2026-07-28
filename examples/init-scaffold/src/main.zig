const std = @import("std");
const zcli = @import("zcli");
const registry = @import("command_registry");

/// Prompts (`add`, `init`) and progress bars hide the cursor and drive raw
/// mode, so a panic mid-prompt must restore the terminal.
pub const panic = zcli.ui.panic;
//<zcli:debug-hook>
/// Segfaults do not route through `panic` — they go to
/// `root.debug.handleSegfault` — so a crash needs this hook too (#759).
pub const debug = zcli.ui.debug;
//</zcli:debug-hook>

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    try app.run(init.gpa, init.io, init.environ_map, args);
}
