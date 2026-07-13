const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("terminal", .{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("Graphemes", zg.module("Graphemes"));

    const test_step = b.step("test", "Run terminal tests");
    const test_mod = b.addModule("test-terminal", .{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("Graphemes", zg.module("Graphemes"));
    const tests = b.addTest(.{ .root_module = test_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Runnable examples — `zig build run-<name>`. The interactive ones (keys,
    // resize) take over the terminal, so they need a real TTY; the rest (report,
    // wrap) degrade gracefully and run anywhere, including piped. Each example is
    // compiled by `test` so it can't bitrot.
    const example_names = [_][]const u8{ "report", "wrap", "keys", "resize" };
    for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = b.fmt("terminal-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("terminal", mod);
        test_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name}));
        run_step.dependOn(&run.step);
    }
}
