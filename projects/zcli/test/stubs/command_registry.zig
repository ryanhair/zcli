//! Test-only stub for the generated `command_registry` module.
//!
//! Command files reference `@import("command_registry").Context` at the top
//! level. Their pure helpers (source generation, validation) don't touch the
//! Context, so a minimal placeholder lets those helpers be unit-tested in
//! isolation. `execute` is never referenced from the tests, so Zig's lazy
//! analysis keeps it (and its real Context requirements) out of the build.

pub const Context = struct {};
