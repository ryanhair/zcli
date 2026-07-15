//! Flush-contract tests: an indicator's output must reach the underlying
//! file as it happens, not sit in the writer's buffer until process exit.
//! This package's prior form is exactly this bug (the no-flush spinner,
//! PR #136) — these tests drive each indicator over a genuinely *buffered*
//! file writer and read the file back mid-flight, so a dropped flush in the
//! ui engine or the indicators fails here instead of in a user's terminal.

const std = @import("std");
const progress = @import("Progress.zig");

const testing = std.testing;

fn readBack(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator) ![]u8 {
    return dir.readFileAlloc(io, "out.txt", alloc, .limited(1 << 16));
}

test "non-interactive spinner flushes each status line as it is set" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "out.txt", .{ .read = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined; // large enough that nothing auto-drains
    var fw = file.writer(io, &buf);

    var spinner = try progress.Spinner.init(testing.allocator, &fw.interface, io, .fallback, .{});
    defer spinner.deinit();
    spinner.app.options.interactive = false;

    spinner.start("Working on it");
    {
        const content = try readBack(io, tmp.dir, testing.allocator);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, "Working on it") != null);
    }

    spinner.succeed("Done");
    const content = try readBack(io, tmp.dir, testing.allocator);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "Done") != null);
}

test "piped progress bar flushes its single finish line at finish" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "out.txt", .{ .read = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);

    var bar = try progress.ProgressBar.init(testing.allocator, &fw.interface, io, .fallback, .{ .total = 10 });
    defer bar.deinit();
    bar.app.options.interactive = false;

    bar.update(10, null);
    bar.finish();

    // The finish summary must be on disk before deinit/process exit.
    const content = try readBack(io, tmp.dir, testing.allocator);
    defer testing.allocator.free(content);
    try testing.expect(content.len > 0);
}

test "piped multi bar is fully silent (documented degradation)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "out.txt", .{ .read = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);

    var mb = try progress.MultiBar.init(testing.allocator, &fw.interface, io, .fallback, .{});
    defer mb.deinit();
    mb.app.options.interactive = false;

    const item = try mb.add("download", 100);
    mb.set(item, 100);
    mb.finish();

    // Unlike the single bar (one finish line), a piped multi bar emits
    // nothing at all — no stray frames or partial escapes in the pipe.
    const content = try readBack(io, tmp.dir, testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 0), content.len);
}
