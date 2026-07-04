//! Thin facade over the registry submodules. The implementation lives in
//! registry/: paths.zig (comptime path/alias helpers), builder.zig (the
//! comptime registration builder), compiled.zig (the compiled registry and
//! runtime executor), and tests.zig (the test suite).
const builder = @import("registry/builder.zig");

pub const Config = builder.Config;
pub const CommandEntry = builder.CommandEntry;
pub const PluginEntry = builder.PluginEntry;
pub const Registry = builder.Registry;

test {
    _ = @import("registry/paths.zig");
    _ = @import("registry/builder.zig");
    _ = @import("registry/compiled.zig");
    _ = @import("registry/tests.zig");
}
