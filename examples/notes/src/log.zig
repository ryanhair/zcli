//! log.zig — an append-only activity log that stays correct when several
//! processes read and append to it at the same time.
//!
//! `store.zig` next door rewrites the whole file every save, which is fine for
//! a document one process owns. A log is different: every run adds a record to
//! a file other runs may be reading or appending to right now. Two rules make
//! that safe, and they are the whole recipe:
//!
//!   1. An advisory lock held for the whole of every read and every append —
//!      `.exclusive` to append, `.shared` to read. Readers do not block each
//!      other; a writer excludes everyone.
//!   2. One record = one line, written (and flushed) as a single unit while
//!      the exclusive lock is held. A reader only trusts bytes up to the last
//!      newline, so a record a half-written writer left behind is never
//!      mistaken for a complete one.
//!
//! What that does and does not buy you. It survives a writer that dies
//! mid-record: the next appender repairs the fragment, and readers ignore it
//! meanwhile. It is NOT a durability guarantee — the flush below drains a
//! buffered writer into the file, it does not `fsync`, so an OS crash or power
//! cut can still lose or tear records the kernel had not written out. Add
//! `file.sync(io)` inside the lock if you need that, and pay for it.
//!
//! This is a log, not a database. It buys atomic appends and concurrent
//! readers. It does NOT give you multi-record transactions, in-place edits,
//! indexes, or readers that block until a writer commits. When you need those,
//! reach for a real database — the honest failure of this recipe is that it
//! silently does not scale to them.

const std = @import("std");

/// Where the log lives, relative to the directory passed in.
pub const filename = "notes.log";

/// One appended record. Field names become the JSON object keys, exactly as
/// in `store.zig` — a typed struct out, the same typed struct back.
pub const Entry = struct {
    action: []const u8,
    title: []const u8,
};

/// The largest a single record may be, encoded and including its newline.
/// Every read is bounded by this too, so a corrupt file can never make the
/// reader allocate (or scan back) without limit.
///
/// A complete record may be exactly this long, newline included; one that
/// exceeds it is rejected on the way in and reported by `read` on the way out.
///
/// The cap also draws the line between the two kinds of damage at the end of
/// the file, and `read` and `append` MUST agree on where that line is — this is
/// the one stretch of the file both of them inspect. An unterminated fragment
/// after the last newline SHORTER than this is a torn tail: some writer was
/// killed part-way through a record it was allowed to write, so readers skip it
/// and the next appender truncates it. A fragment that reaches this length
/// cannot be a record-in-progress, so both sides call it corruption and report
/// `error.RecordTooLong` rather than guessing where to cut.
pub const max_record_bytes = 8 * 1024;

/// The largest log this reader will load into memory at once. Past this the
/// log has outgrown "read it all and iterate" and wants rotation, so say so
/// instead of quietly OOMing.
pub const max_log_bytes = 4 * 1024 * 1024;

pub const Error = error{
    /// Something in the file, or on its way into it, does not fit
    /// `max_record_bytes`. Three occasions, and they are not symmetric:
    ///   - `append` — the record it was handed encodes to more than the cap.
    ///   - `read` — a complete record in the file exceeds the cap. `append`
    ///     does not raise this for such a record: it only ever inspects the
    ///     tail, and never re-validates records written before it.
    ///   - both — an unterminated trailing fragment that *reaches* the cap.
    ///     This is the one case they are guaranteed to agree on, because the
    ///     tail is the only part of the file both of them look at.
    /// A complete record of exactly `max_record_bytes` is fine everywhere; see
    /// `max_record_bytes` for where the fragment line sits and why.
    RecordTooLong,
    /// The file exceeds `max_log_bytes`.
    LogTooLarge,
    /// A newline-terminated (therefore complete) record is not valid JSON.
    /// Locking makes this impossible for a writer that used `append`, so it
    /// means real damage, not a torn tail — see the corruption policy below.
    CorruptRecord,
};

/// Append one record.
///
/// The corruption policy, in one place:
///   - A *torn tail* — an unterminated fragment after the last newline, shorter
///     than `max_record_bytes` — is expected: a writer can be killed
///     mid-record. It is repaired here, truncated away under the exclusive
///     lock before this record is appended, so the file never grows a record
///     glued onto half of an older one.
///   - A fragment that reaches `max_record_bytes` is not a record in progress.
///     Both this function and `read` report `error.RecordTooLong` and leave the
///     file alone: truncating on a hunch could throw away good records.
///   - A *complete* record that does not parse is not expected and is never
///     discarded silently; `read` reports `error.CorruptRecord` and leaves the
///     file alone for a human to look at.
pub fn append(dir: std.Io.Dir, io: std.Io, entry: Entry) !void {
    // Encode first, outside the lock: the critical section should hold the
    // lock for a seek and a write, not for formatting. The fixed buffer is
    // also the bound — a record too big to fit is rejected rather than
    // half-written.
    var record: [max_record_bytes]u8 = undefined;
    var rw = std.Io.Writer.fixed(&record);
    rw.print("{f}\n", .{std.json.fmt(entry, .{})}) catch return Error.RecordTooLong;
    const line = rw.buffered();

    const file = try openForAppend(dir, io);
    // Closing releases the lock, so everything below — including the flush —
    // must happen first. `defer` puts the close last, which is the ordering
    // this needs.
    defer file.close(io);

    // Blocks until every other appender (and reader) is done, so two concurrent
    // `notes add` runs take turns instead of interleaving their bytes.
    try file.lock(io, .exclusive);

    const end = try repairTail(io, file);

    var buf: [512]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.seekTo(end);
    try fw.interface.writeAll(line);
    // Flush INSIDE the lock. A buffered writer that flushes on close (or not
    // at all) would hand the next appender a file whose end-of-file is not
    // where this record ends, and the two records would overlap. Note the
    // limit: this pushes the bytes into the file, it does not `fsync` them to
    // the platter — enough to order this record against the next appender's,
    // not enough to survive a power cut (see the header).
    try fw.interface.flush();
}

/// Load every complete record, oldest first, into `arena`-owned memory.
///
/// The shared lock lets any number of readers run at once while still
/// excluding an appender mid-write; the appender's own repair-then-append
/// means a reader never sees a partial record in the middle of the file.
pub fn read(dir: std.Io.Dir, io: std.Io, arena: std.mem.Allocator) ![]Entry {
    const file = dir.openFile(io, filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{}, // nothing logged yet
        else => return err,
    };
    defer file.close(io); // and closing releases the lock taken below

    // `.shared`: any number of readers hold this at once, and all of them keep
    // an appender out until they are done.
    try file.lock(io, .shared);

    var buf: [4096]u8 = undefined;
    var fr = file.reader(io, &buf);
    const bytes = fr.interface.allocRemaining(arena, .limited(max_log_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return Error.LogTooLarge,
        else => |e| return e,
    };

    // A record counts as written only once its newline is in the file.
    // Everything up to the last newline is complete; anything after it is a
    // tail some writer never finished. Skipping it costs nothing — the next
    // `append` truncates it anyway — and every earlier record is kept.
    //
    // `end_of_last_record` is 0 when there is no newline at all — the whole
    // file is then one unfinished fragment.
    const end_of_last_record = if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |i| i + 1 else 0;
    // The one judgement call, and it has to match `repairTail` exactly (see
    // `max_record_bytes`): a fragment that long is not a record in progress, so
    // report it instead of quietly hiding damage the appender will refuse to
    // repair.
    if (bytes.len - end_of_last_record >= max_record_bytes) return Error.RecordTooLong;
    if (end_of_last_record == 0) return &.{}; // nothing complete yet
    // Minus the final newline, so splitting yields records and not a phantom
    // empty one after the last of them.
    const complete = bytes[0 .. end_of_last_record - 1];

    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, complete, '\n');
    while (lines.next()) |line| {
        if (line.len + 1 > max_record_bytes) return Error.RecordTooLong;
        const parsed = std.json.parseFromSlice(Entry, arena, line, .{ .allocate = .alloc_always }) catch
            return Error.CorruptRecord;
        try entries.append(arena, parsed.value);
    }
    return entries.toOwnedSlice(arena);
}

/// How many times to retry an open that races another process creating the
/// same file. Bounded, so a path that genuinely does not exist (a missing
/// parent directory) still fails instead of spinning forever.
const max_open_attempts = 16;

/// Open the log for appending, creating it on first use.
///
/// `.truncate = false` keeps what is already there. `.read = true` is not
/// decoration either, even though appending only ever writes: `repairTail`
/// reads the last record's worth of bytes back through this same handle and
/// asks it for the file's length, and a handle opened write-only can do
/// neither on Windows — the length query is a read of the file's attributes,
/// and it fails with `error.AccessDenied`. One handle opened read+write keeps
/// the whole critical section — length, tail read, truncate, append — under
/// the one lock, which is the point; a second handle just to measure the file
/// would sit outside it.
///
/// Note what this open does NOT do: ask for the lock. `createFile` and
/// `openFile` both take a `.lock` and can acquire it atomically with the open —
/// but on macOS two threads or processes creating the same file at the same
/// moment can both be told `error.FileNotFound` for a file one of them just
/// made, and asking the open to lock as well widens that window. Retry it, and
/// take the lock as its own step: both behave the same on every platform.
fn openForAppend(dir: std.Io.Dir, io: std.Io) !std.Io.File {
    var attempts: usize = 0;
    while (true) {
        return dir.createFile(io, filename, .{ .read = true, .truncate = false }) catch |err| switch (err) {
            error.FileNotFound => {
                attempts += 1;
                if (attempts == max_open_attempts) return err;
                continue;
            },
            else => return err,
        };
    }
}

/// Drop a torn trailing record, if there is one, and return the offset the
/// next record starts at. Call only while holding the exclusive lock.
///
/// Only the tail can be torn: every earlier record was written by a lock
/// holder that flushed before releasing. So this reads backwards at most
/// `max_record_bytes` — a bounded read, not a whole-file one — looking for the
/// last newline, and applies the same rule `read` applies to what follows it.
fn repairTail(io: std.Io, file: std.Io.File) !u64 {
    const size = try file.length(io);
    if (size == 0) return 0;

    // One record's worth of the end of the file is all a torn tail can occupy:
    // a fragment that fills this window is already too long to be one.
    var window: [max_record_bytes]u8 = undefined;
    const want: usize = @intCast(@min(size, max_record_bytes));
    const start = size - want;
    const n = try file.readPositionalAll(io, window[0..want], start);
    const tail = window[0..n];

    const fragment_len = if (std.mem.lastIndexOfScalar(u8, tail, '\n')) |i|
        tail.len - (i + 1)
    else
        // No newline in the window at all: everything back to `start` is
        // fragment, and if the file reaches past the window there is even more
        // of it. Either way it is at least `want` bytes long.
        want;

    // Same line `read` draws (see `max_record_bytes`): too long to be a record
    // in progress means damage, and guessing where to cut could throw away good
    // records. Both sides refuse on exactly the same files.
    if (fragment_len >= max_record_bytes) return Error.RecordTooLong;

    const valid_end = size - fragment_len;
    if (fragment_len != 0) try file.setLength(io, valid_end);
    return valid_end;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// These run in `zig build test` — build.zig attaches this module's test binary
// to the same step as the command tests. The one case they cannot cover is
// separate processes, because a lock and a process outlive each other in ways
// threads do not: see src/log_multiprocess_test.zig, which drives real child
// processes through the same `append`.

const testing = std.testing;

/// Put raw bytes on the end of the log, behind `append`'s back: no lock, no
/// encoding, no repair. This is how a test stages the damage a writer killed
/// mid-record leaves behind, which no well-behaved appender would ever write.
///
/// It opens the same way `openForAppend` does, and for the same reason: asking
/// a handle how long its file is reads the file's attributes, which a handle
/// opened write-only is not allowed to do on Windows. Without `.read = true`
/// this passes on POSIX and fails with `error.AccessDenied` there.
fn writeRawTail(dir: std.Io.Dir, io: std.Io, bytes: []const u8) !void {
    const file = try dir.createFile(io, filename, .{ .read = true, .truncate = false });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, try file.length(io));
}

/// One concurrent appender, so a test can spawn several and join them.
const Appender = struct {
    dir: std.Io.Dir,
    io: std.Io,
    title: []const u8,
    count: usize,
    err: ?anyerror = null,

    fn run(self: *Appender) void {
        for (0..self.count) |_| {
            append(self.dir, self.io, .{ .action = "add", .title = self.title }) catch |err| {
                self.err = err;
                return;
            };
        }
    }
};

test "append: concurrent threads never interleave, and every record survives" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const titles = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    const per_writer = 25;

    var appenders: [titles.len]Appender = undefined;
    var threads: [titles.len]std.Thread = undefined;
    for (&appenders, &threads, titles) |*a, *t, title| {
        a.* = .{ .dir = tmp.dir, .io = io, .title = title, .count = per_writer };
        t.* = try std.Thread.spawn(.{}, Appender.run, .{a});
    }
    for (threads) |t| t.join();
    for (appenders) |a| if (a.err) |err| return err;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    // Every record parses, which is the assertion that matters: an interleaved
    // append would have produced a line that is two half-records.
    const entries = try read(tmp.dir, io, arena_state.allocator());
    try testing.expectEqual(titles.len * per_writer, entries.len);

    var seen = [_]usize{0} ** titles.len;
    for (entries) |entry| {
        try testing.expectEqualStrings("add", entry.action);
        for (titles, &seen) |title, *count| {
            if (std.mem.eql(u8, title, entry.title)) count.* += 1;
        }
    }
    for (seen) |count| try testing.expectEqual(@as(usize, per_writer), count);
}

test "read: a partial final record is ignored, earlier records are kept" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try append(tmp.dir, io, .{ .action = "add", .title = "first" });
    try append(tmp.dir, io, .{ .action = "add", .title = "second" });

    // Simulate a writer killed mid-record: bytes with no terminating newline.
    try writeRawTail(tmp.dir, io, "{\"action\":\"add\",\"tit");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try read(tmp.dir, io, arena);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("first", entries[0].title);
    try testing.expectEqualStrings("second", entries[1].title);
}

test "append: repairs a partial final record instead of gluing onto it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try append(tmp.dir, io, .{ .action = "add", .title = "first" });
    try writeRawTail(tmp.dir, io, "{\"action\":\"add\",\"tit");

    try append(tmp.dir, io, .{ .action = "remove", .title = "second" });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const entries = try read(tmp.dir, io, arena_state.allocator());
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("first", entries[0].title);
    try testing.expectEqualStrings("remove", entries[1].action);
    try testing.expectEqualStrings("second", entries[1].title);
}

test "read: an empty or missing log is not an error" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(usize, 0), (try read(tmp.dir, io, arena)).len);

    const file = try tmp.dir.createFile(io, filename, .{});
    file.close(io);
    try testing.expectEqual(@as(usize, 0), (try read(tmp.dir, io, arena)).len);
}

test "records are bounded on the way in and on the way out" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Too big to encode into one record: rejected before the file is touched.
    const huge = "x" ** (max_record_bytes + 1);
    try testing.expectError(Error.RecordTooLong, append(tmp.dir, io, .{ .action = "add", .title = huge }));

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(usize, 0), (try read(tmp.dir, io, arena)).len);

    // An over-long complete record already on disk is reported, not parsed.
    {
        const file = try tmp.dir.createFile(io, filename, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "[" ++ huge ++ "]\n", 0);
    }
    try testing.expectError(Error.RecordTooLong, read(tmp.dir, io, arena));
}

test "an over-long trailing fragment is corruption to reader and writer alike" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try append(tmp.dir, io, .{ .action = "add", .title = "first" });

    // A fragment this long cannot be a record someone was part-way through
    // writing, so it is damage rather than a torn tail. `read` must not quietly
    // skip what `append` refuses to repair — that divergence would let a reader
    // report a healthy-looking log while every append failed.
    try writeRawTail(tmp.dir, io, "x" ** max_record_bytes);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(Error.RecordTooLong, read(tmp.dir, io, arena_state.allocator()));
    try testing.expectError(Error.RecordTooLong, append(tmp.dir, io, .{ .action = "add", .title = "second" }));

    // And one byte shorter is a torn tail again — repaired, not reported.
    {
        const file = try tmp.dir.openFile(io, filename, .{ .mode = .read_write });
        defer file.close(io);
        try file.setLength(io, (try file.length(io)) - 1);
    }
    try append(tmp.dir, io, .{ .action = "add", .title = "second" });

    const entries = try read(tmp.dir, io, arena_state.allocator());
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("first", entries[0].title);
    try testing.expectEqualStrings("second", entries[1].title);
}

test "read: a complete record that is not JSON is reported, not skipped" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try append(tmp.dir, io, .{ .action = "add", .title = "first" });
    try writeRawTail(tmp.dir, io, "not json at all\n");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(Error.CorruptRecord, read(tmp.dir, io, arena_state.allocator()));
}
