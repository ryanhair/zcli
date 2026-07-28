//! A hand-written stand-in for the `tool_config` module that
//! `build_utils/main.zig` generates for a plugin's tool (see `wireToolStep`),
//! supplied to `tool.zig` under `zig build test`.
//!
//! Same shape as the generated file — a typed accessor evaluated with the
//! tool's own `Config` type as the result type — so `tool.zig`'s `cfg` is
//! type-checked against a real config literal rather than only against the
//! defaults.

// Mirrors the generated form: `pub fn config(comptime Config: type) Config`.
pub fn config(comptime Config: type) Config {
    return .{ .formats = &.{ "markdown", "man", "html" }, .output_dir = "docs" };
}
