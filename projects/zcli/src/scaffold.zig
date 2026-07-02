//! Shared scaffolding library for the `add` command family. `spec` is the
//! arg/option model plus its rendering/validation helpers; `splice` is the
//! in-file AST-guided editor that adds fields to existing command files without
//! disturbing their `execute()` bodies (ADR-0005). Wired to command modules as
//! the `scaffold` shared module in build.zig.

pub const spec = @import("scaffold/spec.zig");
pub const splice = @import("scaffold/splice.zig");

test {
    _ = spec;
    _ = splice;
}
