const std = @import("std");
const zcli = @import("zcli");
const registry = @import("command_registry");

/// The wizard prompts (`add`, `init`) and release progress bars hide the cursor
/// and drive raw mode, so a panic mid-prompt must restore the terminal.
pub const panic = zcli.ui.panic;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    try app.run(init.gpa, init.io, init.environ_map, args);
}
