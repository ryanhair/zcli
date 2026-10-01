const std = @import("std");
const harness = @import("testing_e2e");
const fixture = @import("editor_fixture_path").path;

test "editor operation attaches terminal independently of redirected stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const output_path = try std.fs.path.join(allocator, &.{ dir, "document.txt" });
    defer allocator.free(output_path);
    var script = harness.InteractiveScript.init(allocator);
    defer script.deinit();
    _ = script.expect("EDITOR_UI").expect("DONE");
    var result = harness.runInteractive(allocator, io, &.{ fixture, output_path }, script, .{ .total_timeout_ms = 15000 }) catch |err| switch (err) {
        error.PtyAllocationFailed, error.UnsupportedPlatform => {
            if (harness.interactiveRequired()) return err;
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer result.deinit();
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Invitation") == null);
    const document = try tmp.dir.readFileAlloc(io, "document.txt", allocator, .limited(100));
    defer allocator.free(document);
    try std.testing.expectEqualStrings("saved\n", document);
}

test "missing controlling terminal is structured failure without launching" {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ fixture, "no-terminal" } });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expectEqualStrings("NO_TERMINAL\n", result.stdout);
}

test "interactive immediate prompt skips Enter invitation" {
    var script = harness.InteractiveScript.init(std.testing.allocator);
    defer script.deinit();
    _ = script.expect("EDITOR_UI").expect("DONE");
    var result = harness.runInteractive(std.testing.allocator, std.testing.io, &.{ fixture, "prompt-immediate" }, script, .{ .total_timeout_ms = 15000 }) catch |err| switch (err) {
        error.PtyAllocationFailed, error.UnsupportedPlatform => {
            if (harness.interactiveRequired()) return err;
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer result.deinit();
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Invitation") == null);
}
