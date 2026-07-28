const std = @import("std");
const registry = @import("command_registry");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    // `run()` classifies and exits on every error it reports to the user —
    // command-not-found is exit 3, misuse 2, a command's own `fail()` 1 — so it
    // only ever *returns* an unexpected error. Propagating that is the whole
    // contract; there is nothing here to catch (#790).
    try app.run(init.gpa, init.io, init.environ_map, args);
}
