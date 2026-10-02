const std = @import("std");
const registry = @import("command_registry");
pub fn main(init: std.process.Init) !void {
    var app = registry.init();
    try app.run(init.gpa, init.io, init.environ_map, try init.minimal.args.toSlice(init.arena.allocator()));
}
