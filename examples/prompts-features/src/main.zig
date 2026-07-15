const std = @import("std");
const zcli = @import("zcli");
const registry = @import("command_registry");

/// The `password` and `multi_select` prompts drive raw mode and hide the
/// cursor, so a panic mid-prompt must restore the terminal instead of
/// stranding it.
pub const panic = zcli.ui.panic;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    try app.run(init.gpa, init.io, init.environ_map, args);
}
