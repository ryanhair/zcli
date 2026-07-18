//! Reference sources for the project `zcli init` scaffolds (issue #679 part 2).
//!
//! Each `@embedFile` name is bound by build.zig (via `addAnonymousImport` on the
//! `scaffold` module) to a real file under `examples/init-scaffold/`, which the
//! root build compiles against the local zcli as an ordinary example/test
//! project. So these are compiled truth: a framework change that breaks the code
//! `init` emits fails OUR build here, instead of shipping a broken scaffold that
//! only fails inside a downstream user's `zig build`. `init` embeds these bytes
//! and substitutes the project's name, description, and selected plugins in
//! (see `init.zig`).
//!
//! The reference `build.zig` is written against the *local* (unreleased) zcli so
//! it compiles here; `init` pins the released tag `context.app_version` points
//! at, so it emits the API shape that release expects. Everything is emitted
//! verbatim (only name/description/plugins are substituted). If the local API
//! drifts from the pinned release between cuts, the drifted call must be
//! adapted at emit time in `init.zig` until the next release — see the retired
//! `addCommandTests` 3-arg pin (#709, removed in #722) for the shape of that.

pub const build_zig = @embedFile("reference/build.zig");
pub const main_zig = @embedFile("reference/main.zig");
pub const hello_zig = @embedFile("reference/hello.zig");
pub const index_zig = @embedFile("reference/index.zig");
