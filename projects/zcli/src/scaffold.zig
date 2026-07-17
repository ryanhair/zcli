//! Shared scaffolding library for the `add`/`rm`/`mv` command family. `spec` is
//! the arg/option model plus its rendering/validation helpers; `splice` is the
//! in-file AST-guided editor that edits existing command files without
//! disturbing their `execute()` bodies (ADR-0005); `fs` holds the whole-file
//! filesystem helpers (empty-group cleanup). Wired to command modules as the
//! `scaffold` shared module in build.zig.

pub const spec = @import("scaffold/spec.zig");
pub const splice = @import("scaffold/splice.zig");
pub const fs = @import("scaffold/fs.zig");
pub const reference = @import("scaffold/reference.zig");
pub const workflows = @import("scaffold/workflows.zig");

test {
    _ = spec;
    _ = splice;
    _ = fs;
    _ = workflows;
}
