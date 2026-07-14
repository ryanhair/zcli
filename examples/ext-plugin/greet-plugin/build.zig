const std = @import("std");

pub fn build(b: *std.Build) void {
    // Accept the target/optimize the consumer forwards via
    // `b.dependency("greet_plugin", .{ .target = ..., .optimize = ... })`, so a
    // plugin package with native code compiles for the CLI's target.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose the plugin's entry point under the module name `plugin` — the
    // contract `zcli.generate()` resolves via `dep.module("plugin")` for an
    // external-package plugin. That's all a plugin package must do: the
    // consuming CLI injects the `zcli` import when it registers the plugin, so
    // this package deliberately has no zcli dependency of its own.
    _ = b.addModule("plugin", .{
        .root_source_file = b.path("plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
}
