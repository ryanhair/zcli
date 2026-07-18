const std = @import("std");
const zcli = @import("zcli");
const registry = @import("command_registry");

/// The upgrade plugin renders its progress as spinners on the ui engine, which
/// hides the cursor mid-frame — a panic must restore the terminal, so every
/// app wiring in the plugin needs this handler (enforced at compile time).
pub const panic = zcli.ui.panic;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    try app.run(init.gpa, init.io, init.environ_map, args);
}
