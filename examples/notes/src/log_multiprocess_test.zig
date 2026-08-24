//! Multi-process coverage for src/log.zig.
//!
//! log.zig's own tests race threads, which shares one process, one `std.Io`,
//! and one lifetime. The locking this recipe rests on is defined between
//! *processes*: each holds its own open file description, and the kernel
//! releases its lock when it exits — including when it exits badly. These tests
//! spawn real child processes (src/log_appender.zig) to pin that down.
//!
//! Both are bounded and deterministic: a fixed number of children, a fixed
//! number of records each, every child released from one barrier, and every
//! child reaped on success and on failure alike.
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
const per_process_arg = std.fmt.comptimePrint("{d}", .{per_process});

/// The appender's absolute path.
///
/// build.zig hands over a path relative to the example's root, and every child
/// below is spawned with its working directory changed to a scratch dir — so a
/// relative `argv[0]` would fail to exec. Resolve it once, from the cwd it is
/// relative to.
fn appenderPath(arena: std.mem.Allocator) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(testing.io, options.appender_exe, arena);
}

/// Spawn an appender, stopped at the barrier. It blocks reading stdin until
/// `releaseStart` closes that pipe, so the caller decides when it starts.
fn spawnAtBarrier(
    io: std.Io,
    dir: std.Io.Dir,
    exe: []const u8,
    title: []const u8,
    count: []const u8,
) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ exe, title, count },
        .cwd = .{ .dir = dir }, // so every child logs to the same file
        .stdin = .pipe, // the barrier
    });
}

/// Let a waiting appender run: closing its stdin is the start signal.
fn releaseStart(io: std.Io, child: *std.process.Child) void {
    if (child.stdin) |pipe| {
        pipe.close(io);
        child.stdin = null;
    }
}

fn expectCleanExit(term: std.process.Child.Term) !void {
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}

/// Run one appender start to finish. Used where the point is the *sequence* of
/// processes rather than contention between them.
fn runAppender(
    io: std.Io,
    dir: std.Io.Dir,
    exe: []const u8,
    title: []const u8,
    count: []const u8,
) !void {
    var child = try spawnAtBarrier(io, dir, exe, title, count);
    var reaped = false;
    errdefer if (!reaped) child.kill(io);

    releaseStart(io, &child);
    const term = try child.wait(io);
    reaped = true;
    try expectCleanExit(term);
}

test "append: concurrent processes never interleave, and every record survives" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const appender = try appenderPath(arena_state.allocator());

    var children: [titles.len]std.process.Child = undefined;
    // `live` names exactly the children that have been spawned and not yet
    // reaped. It grows as they spawn and shrinks as they are waited on, so
    // every early return below — a failed spawn, a failed wait — still cleans
    // up the processes already running. Without it, one bad spawn would leave
    // its predecessors holding locks on a directory the test then deletes.
    var live: []std.process.Child = children[0..0];
    errdefer for (live) |*child| child.kill(io);

    for (&children, titles, 0..) |*child, title, i| {
        child.* = try spawnAtBarrier(io, tmp.dir, appender, title, per_process_arg);
        live = children[0 .. i + 1];
    }

    // Every child is now spawned and blocked. Releasing them together is what
    // makes the contention real: spawning is slow and uneven, so without the
    // barrier the first child can finish all twenty appends before the last one
    // starts — and a lock that did nothing would pass just as happily.
    for (live) |*child| releaseStart(io, child);

    // Collect every status before asserting on any of them. Returning at the
    // first non-zero exit would abandon the children not yet waited on.
    var terms: [titles.len]std.process.Child.Term = undefined;
    for (&terms, 0..) |*term, i| {
        term.* = try children[i].wait(io);
        live = children[i + 1 ..];
    }
    for (terms) |term| try expectCleanExit(term);

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
    try runAppender(io, tmp.dir, appender, "before", "3");

    // What a writer killed part-way through a record leaves behind: bytes with
    // no terminating newline. (Killing a child at exactly that instant is not
    // reproducible; the byte pattern it leaves is, and that is what every other
    // process has to cope with.)
    //
    // `.read = true` even though this only writes: asking a handle how long its
    // file is reads the file's attributes, which a handle opened write-only is
    // not allowed to do on Windows. Same open the recipe's `openForAppend` uses,
    // for the same reason.
    {
        const file = try tmp.dir.createFile(io, log.filename, .{ .read = true, .truncate = false });
        defer file.close(io);
        try file.writePositionalAll(io, "{\"action\":\"add\",\"tit", try file.length(io));
    }

    // A separate process appending next must repair the fragment rather than
    // build on top of it.
    try runAppender(io, tmp.dir, appender, "after", "2");

    const entries = try log.read(tmp.dir, io, arena_state.allocator());
    try testing.expectEqual(@as(usize, 5), entries.len);
    for (entries[0..3]) |entry| try testing.expectEqualStrings("before", entry.title);
    for (entries[3..]) |entry| try testing.expectEqualStrings("after", entry.title);
}
