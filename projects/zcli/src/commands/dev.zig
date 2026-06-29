const std = @import("std");
const zcli = @import("zcli");
const nightwatch = @import("nightwatch");

const ztheme = zcli.ztheme;
const Theme = ztheme.Theme;

pub const meta = .{
    .description = "Watch src/ and rebuild on change (optionally run a command)",
    .examples = &.{
        "dev",
        "dev -- users create alice@example.com",
    },
    .args = .{
        .command = "Command to run after each successful build (everything after --)",
    },
};

pub const Args = struct {
    /// Everything after `--`: a command to run on each successful build.
    command: [][]const u8 = &.{},
};

pub const Options = struct {};

/// Settle window after the first change event, to coalesce an editor's burst of
/// writes into a single rebuild.
const debounce_ms = 80;

pub fn execute(args: Args, options: Options, context: anytype) !void {
    _ = options;

    const io = context.io.io;
    const gpa = context.allocator;
    const out = context.stdout();
    const theme = &context.theme;

    // Confirm we're in a project before arming the watcher.
    var probe = std.Io.Dir.cwd().openDir(io, "src", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const errw = context.stderr();
            try errw.writeAll("No 'src' directory found. Run this from a zcli project root.\n");
            try errw.flush();
            context.exit(1);
            return;
        },
        else => return err,
    };
    probe.close(io);

    // nightwatch needs an absolute path on Zig 0.16: its relative-path branch
    // calls std.Io.Dir.cwd().realPath, which is broken on 0.16.0. currentPath works.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const src_abs = try std.fmt.allocPrint(gpa, "{s}{c}src", .{ cwd_buf[0..cwd_len], std.fs.path.sep });
    defer gpa.free(src_abs);

    var state = WatchState{ .io = io };
    var watcher = try nightwatch.Default.init(io, gpa, &state.handler);
    defer watcher.deinit();
    try watcher.watch(src_abs);

    try paint(out, theme, "zcli dev", .header);
    try out.writeAll(" — watching src/ (Ctrl-C to stop)\n");
    try out.flush();

    var cycle_arena = std.heap.ArenaAllocator.init(gpa);
    defer cycle_arena.deinit();

    // Build once up front, then rebuild on every change.
    runCycle(io, &cycle_arena, out, theme, args.command);
    while (true) {
        state.waitDirty();
        nap(io, debounce_ms); // let the burst settle
        state.clear(); // coalesce events that arrived during the settle window
        try paint(out, theme, "\n• change detected", .dim);
        try out.writeByte('\n');
        runCycle(io, &cycle_arena, out, theme, args.command);
    }
}

// ============================================================================
// Change signal — bridges nightwatch's background thread to the main loop
// ============================================================================

const vtable = nightwatch.Default.Handler.VTable{ .change = onChange, .rename = onRename };

/// nightwatch delivers events on its own thread; the callbacks just flip a
/// flag that the main loop waits on. A mutex+condvar keeps it race-free and
/// lets the loop block instead of spin.
const WatchState = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    dirty: bool = false,
    handler: nightwatch.Default.Handler = .{ .vtable = &vtable },

    fn mark(self: *WatchState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dirty = true;
        self.cond.signal(self.io);
    }

    /// Block until a change has been signalled, then consume it.
    fn waitDirty(self: *WatchState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.dirty) self.cond.waitUncancelable(self.io, &self.mutex);
        self.dirty = false;
    }

    fn clear(self: *WatchState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dirty = false;
    }

    /// Non-blocking consume — used by tests.
    fn takeIfDirty(self: *WatchState) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.dirty) {
            self.dirty = false;
            return true;
        }
        return false;
    }
};

fn onChange(h: *nightwatch.Default.Handler, path: []const u8, event: nightwatch.EventType, obj: nightwatch.ObjectType) error{HandlerFailed}!void {
    _ = path;
    _ = event;
    _ = obj;
    const self: *WatchState = @fieldParentPtr("handler", h);
    self.mark();
}

fn onRename(h: *nightwatch.Default.Handler, src: []const u8, dst: []const u8, obj: nightwatch.ObjectType) error{HandlerFailed}!void {
    _ = src;
    _ = dst;
    _ = obj;
    const self: *WatchState = @fieldParentPtr("handler", h);
    self.mark();
}

// ============================================================================
// Build / run cycle
// ============================================================================

fn runCycle(
    io: std.Io,
    cycle_arena: *std.heap.ArenaAllocator,
    out: *std.Io.Writer,
    theme: *const Theme,
    command: []const []const u8,
) void {
    _ = cycle_arena.reset(.retain_capacity);
    doCycle(io, cycle_arena.allocator(), out, theme, command) catch |err| {
        // Never let a transient failure tear down the watcher.
        out.print("dev: {s}\n", .{@errorName(err)}) catch {};
        out.flush() catch {};
    };
}

fn doCycle(
    io: std.Io,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    theme: *const Theme,
    command: []const []const u8,
) !void {
    try paint(out, theme, "▸ rebuilding…", .info);
    try out.writeByte('\n');
    try out.flush(); // child inherits the real stdout fd — flush ours first so order is right

    const argv = try buildArgv(arena, command);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);

    if (term == .exited and term.exited == 0) {
        try paint(out, theme, "✓ build succeeded", .ok);
    } else {
        try paint(out, theme, "✗ build failed", .err);
    }
    try out.writeByte('\n');
    try out.flush();
}

/// `zig build` (no command) or `zig build run -- <command>`.
fn buildArgv(arena: std.mem.Allocator, command: []const []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    try list.appendSlice(arena, &.{ "zig", "build" });
    if (command.len > 0) {
        try list.appendSlice(arena, &.{ "run", "--" });
        try list.appendSlice(arena, command);
    }
    return list.items;
}

fn nap(io: std.Io, ms: u32) void {
    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

// ============================================================================
// Output
// ============================================================================

const Role = enum { header, info, ok, err, dim };

fn paint(out: *std.Io.Writer, theme: *const Theme, text: []const u8, role: Role) !void {
    const t = ztheme.theme(text);
    switch (role) {
        .header => try t.header().bold().render(out, theme),
        .info => try t.info().render(out, theme),
        .ok => try t.success().bold().render(out, theme),
        .err => try t.err().bold().render(out, theme),
        .dim => try t.dim().render(out, theme),
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "buildArgv: no command builds only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const argv = try buildArgv(arena_state.allocator(), &.{});
    try testing.expectEqual(@as(usize, 2), argv.len);
    try testing.expectEqualStrings("zig", argv[0]);
    try testing.expectEqualStrings("build", argv[1]);
}

test "buildArgv: with command builds and runs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cmd = [_][]const u8{ "users", "create", "alice" };
    const argv = try buildArgv(arena_state.allocator(), &cmd);
    try testing.expectEqual(@as(usize, 7), argv.len);
    try testing.expectEqualStrings("build", argv[1]);
    try testing.expectEqualStrings("run", argv[2]);
    try testing.expectEqualStrings("--", argv[3]);
    try testing.expectEqualStrings("users", argv[4]);
    try testing.expectEqualStrings("alice", argv[6]);
}

test "WatchState coalesces and consumes the dirty signal" {
    var s = WatchState{ .io = std.testing.io };
    try testing.expect(!s.takeIfDirty()); // clean to start

    s.mark();
    s.mark(); // multiple events collapse to one
    try testing.expect(s.takeIfDirty());
    try testing.expect(!s.takeIfDirty()); // consumed

    s.mark();
    s.clear();
    try testing.expect(!s.takeIfDirty()); // clear() drops it
}
