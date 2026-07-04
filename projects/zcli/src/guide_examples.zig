//! Canonical example sources, embedded at build time (ADR-0004/0008).
//!
//! Each `@embedFile` name is bound by build.zig (via `addAnonymousImport`) to a
//! real, CI-compiled example file under `examples/`. So `zcli guide` shows
//! compiled-and-tested code rather than hand-written prose, and a framework
//! change that breaks an example fails CI before it can reach the guide. These
//! are cross-package files, so they can only be embedded through that build
//! wiring — a bare relative `@embedFile` is rejected as "outside package path".
pub const repostat_repo = @embedFile("repostat/repo.zig");
pub const ghauth_login = @embedFile("ghauth/login.zig");
pub const ghauth_whoami = @embedFile("ghauth/whoami.zig");
pub const notes_store = @embedFile("notes/store.zig");
pub const notes_verbose_plugin = @embedFile("notes/verbose.zig");
