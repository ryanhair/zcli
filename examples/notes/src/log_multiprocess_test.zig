//! Multi-process coverage for src/log.zig.
//!
//! log.zig's own tests race threads, which shares one process, one `std.Io`,
//! and one lifetime. The locking this recipe rests on is defined between
//! *processes*: each holds its own open file description, and the kernel
//! releases its lock when it exits — including when it exits badly. These tests
//! spawn real child processes (src/log_appender.zig) to pin that down.
//!
//! Both are bounded and deterministic: a fixed number of children, a fixed
//! number of records each, and every child waited on.
//!
//! Run them through `zig build test`, which runs this binary with the example's
//! root as the working directory — the appender path below is relative to it.

const std = @import("std");
const log = @import("log");
// build.zig passes the appender binary's path in; see its `log_test_options`.
const options = @import("log_test_options");

const testing = std.testing;

const titles = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
const per_process = 20;

/// The appender's absolute path.
///
/// build.zig hands over a path relative to the example's root, and every child
/// below is spawned with its working directory changed to a scratch dir — so a
/// relative `argv[0]` would fail to exec. Resolve it once, from the cwd it is
/// relative to.
fn appenderPath(arena: std.mem.Allocator) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(testing.io, options.appender_exe, arena);
}

test "append: concurrent processes never interleave, and every record survives" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const appender = try appenderPath(arena_state.allocator());

    // Spawn every child before waiting on any of them — waiting in the loop
    // would serialize them and test nothing.
    var children: [titles.len]std.process.Child = undefined;
    for (&children, titles) |*child, title| {
        child.* = try std.process.spawn(io, .{
            .argv = &.{ appender, title, std.fmt.comptimePrint("{d}", .{per_process}) },
            .cwd = .{ .dir = tmp.dir }, // so each child logs to the same file
        });
    }
    for (&children) |*child| {
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    }

    // Every record parses, which is the assertion that matters: two appends
    // that interleaved would leave a line made of two half-records. And every
    // record is present, which is the other half — a writer whose lock was not
    // honored would have overwritten someone else's bytes instead.
    const entries = try log.read(tmp.dir, io, arena_state.allocator());
    try testing.expectEqual(titles.len * per_process, entries.len);

    var seen = [_]usize{0} ** titles.len;
    for (entries) |entry| {
        try testing.expectEqualStrings("add", entry.action);
        for (titles, &seen) |title, *count| {
            if (std.mem.eql(u8, title, entry.title)) count.* += 1;
        }
    }
    for (seen) |count| try testing.expectEqual(@as(usize, per_process), count);
}

test "a process that dies mid-record leaves a tail the next process repairs" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const appender = try appenderPath(arena_state.allocator());

    // A real prior process, so the fragment below sits after records written by
    // someone who has since exited and dropped its lock.
    {
        var child = try std.process.spawn(io, .{
            .argv = &.{ appender, "before", "3" },
            .cwd = .{ .dir = tmp.dir },
        });
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    }

    // What a writer killed part-way through a record leaves behind: bytes with
    // no terminating newline. (Killing a child at exactly that instant is not
    // reproducible; the byte pattern it leaves is, and that is what every other
    // process has to cope with.)
    {
        const file = try tmp.dir.createFile(io, log.filename, .{ .truncate = false });
        defer file.close(io);
        try file.writePositionalAll(io, "{\"action\":\"add\",\"tit", try file.length(io));
    }

    // A separate process appending next must repair the fragment rather than
    // build on top of it.
    {
        var child = try std.process.spawn(io, .{
            .argv = &.{ appender, "after", "2" },
            .cwd = .{ .dir = tmp.dir },
        });
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    }

    const entries = try log.read(tmp.dir, io, arena_state.allocator());
    try testing.expectEqual(@as(usize, 5), entries.len);
    for (entries[0..3]) |entry| try testing.expectEqualStrings("before", entry.title);
    for (entries[3..]) |entry| try testing.expectEqualStrings("after", entry.title);
}
